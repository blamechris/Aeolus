import Foundation

@testable import AeolusHelper
@testable import SMCCore

// How a test scripts a `FirmwareSMC`, holds it, and reads through its other two views — in a file
// of its own so the actor stays inside `type_body_length`.
extension FirmwareSMC {

    // MARK: - Scripting

    /// The key table declares `key` this way from now on, and its cached key info is dropped, so
    /// the next read asks again. For setting a scenario up — a key `mac16x5()` lacks, or one of its
    /// keys varied — before the key is used: a real firmware's table does not change under a
    /// running connection.
    func declare(_ key: SMCKey, _ entry: Key) {
        table[key] = entry
        keyInfoCache[key] = nil
    }

    /// `key`'s register holds `bytes` from now on, as if the firmware had set it itself: no write
    /// is answered and nothing is logged.
    func setRegister(_ key: SMCKey, _ bytes: [UInt8]) {
        registers[key] = bytes
    }

    /// `key`'s `READ_BYTES` answers this from now on.
    func setRead(of key: SMCKey, _ answer: ReadAnswer) {
        readAnswers[key] = answer
    }

    /// The next reads of `key` that reach `READ_BYTES` are answered these ways, in order, ahead of
    /// its standing answer (`setRead(of:_:)`) — so a scenario can let a pre-state read answer and
    /// lose the read-back after it, in one turn (b2).
    func queueReads(of key: SMCKey, _ answers: [ReadAnswer]) {
        queuedReads[key, default: []].append(contentsOf: answers)
    }

    /// The next writes to `key` are answered these ways, in order, ahead of the unlock rule and the
    /// default.
    func queueWrites(to key: SMCKey, _ answers: [WriteAnswer]) {
        queuedWrites[key, default: []].append(contentsOf: answers)
    }

    /// Every write with nothing queued for its key, and outside the unlock rule, is answered this
    /// way. `.applies` until set.
    func setDefaultWrite(_ answer: WriteAnswer) {
        defaultWrite = answer
    }

    /// The generation `open()` resolves from now on, and the one the open handle has now. `nil` is
    /// a firmware whose interface could not be told, so `flt` and plain-integer reads decode to
    /// nothing (ADR 0003, ADR 0004).
    func setInterfaceGeneration(_ value: SMCInterfaceGeneration?) {
        declaredGeneration = value
        if isOpen { generation = value }
    }

    /// Runs `hook` once, synchronously and inside this actor, immediately before the next
    /// `operation` is performed — the instant a request made from another thread mid-turn would
    /// land, without parking a pool thread to make it.
    func onNext(_ operation: Operation, run hook: @escaping @Sendable () -> Void) {
        hooks[operation] = hook
    }

    /// Runs `hook` once, synchronously and inside this actor, immediately after the next
    /// `operation` is answered — returned or thrown, and logged — and before its caller resumes,
    /// so a scenario can act between an answer and whatever comes next without depending on which
    /// operation that is.
    func onAfter(_ operation: Operation, run hook: @escaping @Sendable () -> Void) {
        afterHooks[operation] = hook
    }

    /// What `key`'s register holds now, as bytes.
    func register(_ key: SMCKey) -> [UInt8]? {
        registers[key]
    }

    // MARK: - Holding

    /// Every `provider` read from now on parks — suspends, holding its scheduler turn and nothing
    /// else — until `releaseReads()`.
    func holdReads() { holdsProviderReads = true }

    func releaseReads() {
        holdsProviderReads = false
        let parked = parkedReads
        parkedReads.removeAll()
        for waiter in parked { waiter.resume() }
    }

    /// Every discovery walk from now on parks inside itself until `releaseWalks()`. A walk takes no
    /// scheduler turn, so this holds nothing but the walk.
    func holdWalks() { holdsWalks = true }

    func releaseWalks() {
        holdsWalks = false
        let parked = parkedWalks
        parkedWalks.removeAll()
        for waiter in parked { waiter.resume() }
    }

    var readsParked: Int { parkedReads.count }
    var walksParked: Int { parkedWalks.count }

    // MARK: - The other two views' halves

    /// One `SensorProvider.read(keys:)`, as `SMCSensorProvider.read(keys:)` does it: open, then one
    /// outcome per key, with `.keyNotFound` only for a key a completed walk did not see.
    func providerRead(_ requested: [String]) async -> [SensorReadOutcome] {
        log.record(.providerReadBegan(requested))
        if holdsProviderReads {
            await withCheckedContinuation { parkedReads.append($0) }
        }
        defer { log.record(.providerReadEnded) }
        if requested.contains(where: { SMCKey($0) != nil }) { reopen() }
        return requested.map { raw in
            guard let key = SMCKey(raw) else {
                return SensorReadOutcome(key: raw, result: .failure(.unknownKey(raw)))
            }
            if let knownKeys, !knownKeys.contains(key) {
                return SensorReadOutcome(key: raw, result: .failure(.unknownKey(raw)))
            }
            return SensorReadOutcome(key: raw, result: sensorResult(for: key))
        }
    }

    /// One discovery walk: every key the table declares, read through `read(_:)`, the failures
    /// skipped, as `SMCSensorProvider.readAll()` skips them. The keys the table declares — present,
    /// or with failing key info, but never absent — become the known set, as a completed walk's do.
    func walk() async -> [SensorReading] {
        log.record(.walkBegan)
        if holdsWalks {
            await withCheckedContinuation { parkedWalks.append($0) }
        }
        defer { log.record(.walkEnded) }
        reopen()
        var readings: [SensorReading] = []
        var seen: Set<SMCKey> = []
        for key in table.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if case .absent = table[key] { continue }
            seen.insert(key)
            if case .success(let reading) = sensorResult(for: key) { readings.append(reading) }
        }
        knownKeys = seen
        return readings
    }

    /// `SMCConnection.close()`: the handle and its generation go, the key-info cache stays.
    func close() {
        isOpen = false
        generation = nil
        log.record(.closed)
    }

    /// `SMCConnection.open()`: idempotent, and it resolves the generation.
    func open() {
        log.record(.opened)
        reopen()
    }
}
