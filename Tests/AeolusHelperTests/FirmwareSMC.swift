import Foundation
import IOKit
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// A test-only SMC at the byte level: the key table, the registers, and every answer the firmware
/// gives — behind `SMCWriteChannel`, the seam B1's write turns take
/// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s B1 amendment).
///
/// `ScriptedControlPlane` scripts the plane's verbs; this scripts what is underneath them, so the
/// production plane's write turns can run over the real `SMCReadScheduler` and the real
/// `PlaneWriteLedger` with only IOKit replaced. It also offers the two other views production
/// takes of the one connection — `provider`, a `SensorProvider`, and `recycler`, an
/// `SMCConnectionRecycling` — over the **same** registers, so a scheduler read sees what a write
/// turn wrote.
///
/// ## What it is faithful to, and where that is cited
///
/// Every answer is an `SMCError` case the real connection throws for the same firmware answer, and
/// in the same order, from `Sources/SMCCore/SMCConnection.swift`; there is no fake-only error
/// type:
/// - a call on a closed handle is `.connectionFailed(kernReturn: kIOReturnNotOpen)`, before any
///   round trip (`call(_:)`, the not-open guard at lines 728–730);
/// - a kernel error is `.connectionFailed(kernReturn:)` (754–756), and a short reply
///   `.truncatedReply` (765–767) — a read or a write that is **lost**;
/// - a non-zero result byte is `.firmware(code:)` (784–786), and that is how the firmware's answer
///   for a key it does not have arrives through every member of the channel: nothing in
///   `freshKeyInfo(for:)`, `read(_:)` or `write(_:to:)` produces `.keyNotFound`;
/// - `.keyNotFound` is produced in exactly one place, `read(keys:)` for a key a completed walk did
///   not see, at zero round trips (829), and so it reaches only the `provider` view, as
///   `SMCSensorProvider.read(keys:)` maps it to `.unknownKey` (`SensorProvider.swift` 288–289);
/// - a read refuses a key declaring itself unreadable with `.notReadable` and one over 32 bytes
///   with `.valueTooLargeForSingleRead`, both before any `READ_BYTES` (556–561);
/// - a write refuses an empty payload or one over 32 bytes with `.notPermitted`, before any round
///   trip, and reads nothing (699–709).
///
/// **The firmware's not-found answer is not observed** on any machine this project has, so it is
/// never assumed here: an absent key is scripted with the error it answers, which may be a result
/// byte (`.firmware(code:)`) or a kernel return (`.connectionFailed(kernReturn:)`) — the 27.0.1
/// capture saw `0xE00002C1` from key info, without root. A key the table does not declare at all
/// is a scenario that forgot one, recorded as an issue.
///
/// Readings decode through `SMCValue.scalar()`, with the byte order `resolveByteOrder` gives for
/// the key's declared attributes — the production decoder, not a second one. The key-info cache
/// is modelled, because the round trips a turn takes depend on it: `freshKeyInfo(for:)` always
/// asks and refills it, `read(_:)` asks only on a miss, and a close keeps it.
///
/// ## What it is not
///
/// It never wraps a real connection and never touches IOKit; `kIOReturnNotOpen` is the only IOKit
/// name in it, a constant. It starts open — a scenario that needs a closed handle calls `close()`
/// first — and its `open()` never fails: the real `open()`'s failures, an `IOServiceOpen` kernel
/// return, are not modelled, so a reopen that fails cannot be scripted here. The index walk is not
/// modelled — a discovery walk reads every key the table declares — and nothing here says what a
/// real firmware does with a write whose length differs from the key's declared size, beyond
/// storing it as written: a read returns the declared size, zero-padded or cut, as the real read
/// sizes its payload from the request (777–782).
actor FirmwareSMC: SMCWriteChannel {

    // MARK: - The firmware's vocabulary

    /// What the key table declares about one key.
    enum Key: Sendable, Equatable {
        /// The key exists, and `READ_KEYINFO` answers this.
        case present(SMCKeyInfo)
        /// The key does not exist, and the firmware answers this for it — to key info, to a read
        /// and to a write alike, each a round trip — and a walk leaves it out. The answer is the
        /// scenario's, because no not-found answer has been observed: a result byte or a kernel
        /// return, which is why it is an `SMCError` and not a byte.
        case absent(answering: SMCError)
        /// `READ_KEYINFO` of this key fails with this error. On macOS 27.0.1, 37 keys on `Mac16,5`
        /// failed it with kernel result `0xE00002C1` (`docs/SMC-RESEARCH.md`, "Mode keys and `Ftst`
        /// re-checked on macOS 27.0.1").
        case keyInfoFails(SMCError)
    }

    /// How `READ_BYTES` of a present, readable key answers.
    enum ReadAnswer: Sendable, Equatable {
        /// The register's bytes.
        case answers
        /// A non-zero result byte.
        case failsWithCode(UInt8)
        /// No answer: a kernel error or a short reply — `.connectionFailed` or `.truncatedReply`.
        case lost(SMCError)
    }

    /// How one write is answered.
    enum WriteAnswer: Sendable, Equatable {
        /// `0x00`, and the register takes the bytes.
        case applies
        /// `0x00`, and the register keeps what it had (#291).
        case acceptsWithoutApplying
        /// This non-zero result byte, and the register keeps what it had.
        case refuses(code: UInt8)
        /// No answer — `.connectionFailed` or `.truncatedReply` — with the register changed or not,
        /// which no answer the caller receives can tell (issued, not landed).
        case unanswered(SMCError, applied: Bool)
    }

    /// The byte-level unlock rule: how a non-zero `F<n>Md` write with nothing queued for its key is
    /// answered. **The scripted plane's own type**, so one scenario configures both planes and a
    /// contract suite can run it over each:
    /// - `.naive` — the default write answer;
    /// - `.heldUntilForced(stepsToYield:)` — `0x82` until `Ftst` reads `1`, then `stepsToYield`
    ///   more, then the default write answer; clearing `Ftst` starts the count again;
    /// - `.neverYields` — `0x82`, whatever `Ftst` holds;
    /// - `.answers(code:)` — that code;
    /// - `.readsBack(rawMode:)` — `0x00`, and the register reads `rawMode`.
    typealias Unlock = ScriptedControlPlane.UnlockBehaviour

    /// An operation a hook can be placed on.
    enum Operation: Sendable, Hashable {
        case keyInfo(SMCKey)
        case read(SMCKey)
        case write(SMCKey)
    }

    // MARK: - State
    //
    // Internal rather than private only so this actor's extensions in `FirmwareSMC+Scripting.swift`
    // reach it; a test scripts the firmware through those methods, never by assigning here.

    /// What every view records into, and what `SMCReadScheduler` reports turns into.
    nonisolated let log = FirmwareLog()

    var table: [SMCKey: Key]
    var registers: [SMCKey: [UInt8]]
    var readAnswers: [SMCKey: ReadAnswer] = [:]
    var queuedReads: [SMCKey: [ReadAnswer]] = [:]
    var queuedWrites: [SMCKey: [WriteAnswer]] = [:]
    var defaultWrite: WriteAnswer = .applies
    let unlock: Unlock
    var heldUnderForceKey: [SMCKey: Int] = [:]

    /// The generation `open()` resolves, and the one the handle has now: `nil` while closed.
    var declaredGeneration: SMCInterfaceGeneration?
    var generation: SMCInterfaceGeneration?
    var isOpen = true

    var keyInfoCache: [SMCKey: SMCKeyInfo] = [:]
    var knownKeys: Set<SMCKey>?
    var hooks: [Operation: @Sendable () -> Void] = [:]
    var afterHooks: [Operation: @Sendable () -> Void] = [:]

    var holdsProviderReads = false
    var parkedReads: [CheckedContinuation<Void, Never>] = []
    var holdsWalks = false
    var parkedWalks: [CheckedContinuation<Void, Never>] = []

    init(
        keys: [SMCKey: Key],
        registers: [SMCKey: [UInt8]],
        generation: SMCInterfaceGeneration?,
        unlock: Unlock = .naive
    ) {
        self.table = keys
        self.registers = registers
        self.declaredGeneration = generation
        self.generation = generation
        self.unlock = unlock
        if case .answers(let code) = unlock, code == 0x00 || code == 0x82 {
            Issue.record(
                """
                FirmwareSMC was given .answers(code: \(code)). That case is a code neither 0x00, \
                the default answer (.naive), nor 0x82, the held answer (.neverYields): script one \
                of those instead.
                """)
        }
    }

    // MARK: - SMCWriteChannel

    var interfaceGeneration: SMCInterfaceGeneration? { generation }

    func freshKeyInfo(for key: SMCKey) throws(SMCError) -> SMCKeyInfo {
        fire(.keyInfo(key))
        defer { fireAfter(.keyInfo(key)) }
        let site = FirmwareLog.Site.keyInfo(key)
        guard isOpen else { throw refuse(site, Self.notOpen) }
        do throws(SMCError) {
            let info = try declaredInfo(of: key)
            keyInfoCache[key] = info
            log.record(site.entry(.answered))
            return info
        } catch {
            log.record(site.entry(.threw(error)))
            throw error
        }
    }

    func read(_ key: SMCKey) throws(SMCError) -> SMCValue {
        fire(.read(key))
        defer { fireAfter(.read(key)) }
        let site = FirmwareLog.Site.read(key)
        let info: SMCKeyInfo
        if let cached = keyInfoCache[key] {
            info = cached
        } else {
            info = try freshKeyInfo(for: key)
        }
        guard info.isReadable else { throw refuse(site, .notReadable(key)) }
        guard info.dataSize <= Self.maxPayloadBytes else {
            throw refuse(site, .valueTooLargeForSingleRead(key: key, dataSize: info.dataSize))
        }
        let byteOrder = generation.map {
            resolveByteOrder(generation: $0, attributes: info.attributes, type: info.type)
        }
        guard info.dataSize > 0 else {
            return SMCValue(key: key, type: info.type, bytes: [], byteOrder: byteOrder)
        }
        guard isOpen else { throw refuse(site, Self.notOpen) }

        switch nextReadAnswer(for: key) {
        case .answers:
            log.record(site.entry(.answered))
            let held = registers[key] ?? []
            let bytes = Array(
                (held + [UInt8](repeating: 0, count: info.dataSize)).prefix(info.dataSize))
            return SMCValue(key: key, type: info.type, bytes: bytes, byteOrder: byteOrder)
        case .failsWithCode(let code):
            log.record(site.entry(.threw(.firmware(code: code))))
            throw .firmware(code: code)
        case .lost(let error):
            log.record(site.entry(.threw(error)))
            throw error
        }
    }

    func write(_ bytes: [UInt8], to key: SMCKey) throws(SMCError) {
        fire(.write(key))
        defer { fireAfter(.write(key)) }
        let site = FirmwareLog.Site.write(key, bytes)
        guard !bytes.isEmpty, bytes.count <= Self.maxPayloadBytes else {
            throw refuse(site, .notPermitted)
        }
        guard isOpen else { throw refuse(site, Self.notOpen) }
        if case .absent(let error) = table[key] {
            log.record(site.entry(.threw(error)))
            throw error
        }
        if table[key] == nil { unscripted(key) }

        switch answer(toWriting: bytes, to: key) {
        case .applies:
            store(bytes, in: key)
            log.record(site.entry(.answered))
        case .acceptsWithoutApplying:
            log.record(site.entry(.answered))
        case .refuses(let code):
            log.record(site.entry(.threw(.firmware(code: code))))
            throw .firmware(code: code)
        case .unanswered(let error, let applied):
            if applied { store(bytes, in: key) }
            log.record(site.entry(.threw(error)))
            throw error
        }
    }

    // MARK: - Answering

    /// The longest payload one request carries, either way (`SMCConnection.maxPayloadBytes`).
    static let maxPayloadBytes = 32

    /// `call(_:)`'s answer on a closed handle (`SMCConnection.swift` 728–730).
    static let notOpen = SMCError.connectionFailed(kernReturn: kIOReturnNotOpen)

    func reopen() {
        guard !isOpen else { return }
        isOpen = true
        generation = declaredGeneration
    }

    private func declaredInfo(of key: SMCKey) throws(SMCError) -> SMCKeyInfo {
        switch table[key] {
        case .present(let info): return info
        case .absent(let error): throw error
        case .keyInfoFails(let error): throw error
        case nil:
            unscripted(key)
            throw .keyNotFound(key)
        }
    }

    /// The next queued read answer for `key`, then its standing one, then `.answers`.
    private func nextReadAnswer(for key: SMCKey) -> ReadAnswer {
        if var queue = queuedReads[key], !queue.isEmpty {
            let next = queue.removeFirst()
            queuedReads[key] = queue
            return next
        }
        return readAnswers[key] ?? .answers
    }

    private func answer(toWriting bytes: [UInt8], to key: SMCKey) -> WriteAnswer {
        if var queue = queuedWrites[key], !queue.isEmpty {
            let next = queue.removeFirst()
            queuedWrites[key] = queue
            return next
        }
        guard Self.isFanModeKey(key), bytes.contains(where: { $0 != 0 }) else {
            return defaultWrite
        }
        switch unlock {
        case .naive:
            return defaultWrite
        case .heldUntilForced(let stepsToYield):
            guard registers[SMCKey.forceTest] == [0x01] else { return .refuses(code: 0x82) }
            let held = heldUnderForceKey[key, default: 0]
            guard held >= stepsToYield else {
                heldUnderForceKey[key] = held + 1
                return .refuses(code: 0x82)
            }
            return defaultWrite
        case .neverYields:
            return .refuses(code: 0x82)
        case .answers(let code):
            return .refuses(code: code)
        case .readsBack(let rawMode):
            registers[key] = [rawMode]
            return .acceptsWithoutApplying
        }
    }

    private func store(_ bytes: [UInt8], in key: SMCKey) {
        registers[key] = bytes
        if key == SMCKey.forceTest, bytes != [0x01] { heldUnderForceKey.removeAll() }
    }

    private func fire(_ operation: Operation) {
        guard let hook = hooks.removeValue(forKey: operation) else { return }
        log.record(.hookFired(operation))
        hook()
    }

    private func fireAfter(_ operation: Operation) {
        guard let hook = afterHooks.removeValue(forKey: operation) else { return }
        log.record(.afterHookFired(operation))
        hook()
    }

    /// Records a refusal no round trip was made for, and hands back the error to throw.
    private func refuse(_ site: FirmwareLog.Site, _ error: SMCError) -> SMCError {
        log.record(site.entry(.unsent(error)))
        return error
    }

    private func unscripted(_ key: SMCKey) {
        Issue.record(
            """
            FirmwareSMC was asked about \(key), which its key table does not declare. Script it \
            .present, or .absent(answering:) with the answer the scenario means.
            """)
    }

    private static func isFanModeKey(_ key: SMCKey) -> Bool {
        let raw = Array(key.rawValue)
        return raw.count == 4 && raw[0] == "F" && raw[1].isNumber && raw[2] == "M" && raw[3] == "d"
    }

    /// One key's outcome as `SMCSensorProvider.read(keys:)` maps it (`SensorProvider.swift`
    /// 284–306): a failure's description, a scalar through `SMCValue.scalar()`, or not decodable.
    func sensorResult(for key: SMCKey) -> Result<SensorReading, SensorReadFailure> {
        let value: SMCValue
        do throws(SMCError) {
            value = try read(key)
        } catch .keyNotFound(let missing) {
            return .failure(.unknownKey(missing.rawValue))
        } catch {
            return .failure(.readFailed(reason: String(describing: error)))
        }
        return Self.decoded(value, of: key)
    }

    /// A value through `SMCValue.scalar()`, or the reason it is not a reading.
    static func decoded(
        _ value: SMCValue, of key: SMCKey
    ) -> Result<SensorReading, SensorReadFailure> {
        do {
            guard let scalar = try value.scalar() else {
                return .failure(
                    .notDecodable(reason: "\(value.type.fourCharString) is not numeric"))
            }
            return .success(
                SensorReading(
                    key: key.rawValue, value: scalar, kind: SMCSensorProvider.kind(for: key),
                    providerIdentifier: Provider.identifier))
        } catch {
            return .failure(.notDecodable(reason: String(describing: error)))
        }
    }
}
