import AeolusXPC
import FanKit
import Foundation
import SMCCore

@testable import AeolusHelper

/// A `FanAuthority` that records what it was asked and answers from canned values.
///
/// The recording half is the point. "The authority never sees an un-handshaken message"
/// is a claim about calls that did *not* happen, and there is no way to check that from a
/// refusal alone — a gate that refused the client *and* dispatched anyway would look
/// identical from the client's side.
actor RecordingFanAuthority: FanAuthority {

    /// Every method this authority was asked for, in order.
    enum Call: Sendable, Hashable {
        case snapshot
        case acquireLease(ConnectionID)
        case renewLease(UUID, ConnectionID)
        case releaseLease(UUID, ConnectionID)
        case apply(UUID, ConnectionID)
        case restoreAllToAutomatic(ConnectionID)
        case connectionDidInvalidate(ConnectionID)
    }

    private(set) var calls: [Call] = []

    private let cannedSnapshot: SystemSnapshot
    private let snapshotError: Error?

    init(snapshot: SystemSnapshot = .empty, snapshotError: Error? = nil) {
        self.cannedSnapshot = snapshot
        self.snapshotError = snapshotError
    }

    func snapshot() async throws -> SystemSnapshot {
        calls.append(.snapshot)
        if let snapshotError { throw snapshotError }
        return cannedSnapshot
    }

    func acquireLease(
        _ request: LeaseRequest,
        from connection: ConnectionID
    ) async throws -> Lease {
        calls.append(.acquireLease(connection))
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease {
        calls.append(.renewLease(id, connection))
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func releaseLease(id: UUID, from connection: ConnectionID) async throws {
        calls.append(.releaseLease(id, connection))
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func apply(
        _ settings: [FanSetting], leaseID: UUID, from connection: ConnectionID
    ) async throws {
        calls.append(.apply(leaseID, connection))
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func restoreAllToAutomatic(from connection: ConnectionID) async throws {
        calls.append(.restoreAllToAutomatic(connection))
    }

    func connectionDidInvalidate(_ connection: ConnectionID) async {
        calls.append(.connectionDidInvalidate(connection))
    }

    /// The connections this authority was told had died, in order. The assertion
    /// `AnonymousListenerTests` makes about the invalidation handler.
    var invalidatedConnections: [ConnectionID] {
        calls.compactMap {
            guard case .connectionDidInvalidate(let id) = $0 else { return nil }
            return id
        }
    }
}

extension SystemSnapshot {
    /// A snapshot with nothing in it, for tests that only care that one came back.
    static let empty = SystemSnapshot(
        fans: [],
        sensors: [],
        activeLease: nil,
        isThermalEmergencyActive: false,
        capturedAt: Date(timeIntervalSince1970: 1_000_000)
    )
}

/// A canned error with a deterministic description, so a test asserting on this project's
/// own error wrapping exercises the wrapping rather than the wording of a hardware failure
/// it never saw.
struct FakeProviderError: Error, CustomStringConvertible, Equatable {
    let description: String
}

/// A `SensorProvider` double answering from canned data, so the helper's snapshot path is
/// fully exercisable on CI — which has no SMC at all.
///
/// An actor so it can count what it was asked for. "`readAll()` is discovery and runs at
/// most once" is a claim about the number of requests made, not about their results.
actor FakeSensorProvider: SensorProvider {
    nonisolated let identifier = "fake"

    private let availableValue: Bool
    private let keyedResults: [String: Result<SensorReading, SensorReadFailure>]
    private let allReadings: [SensorReading]
    private var readAllErrors: [FakeProviderError?]
    private let keysError: FakeProviderError?

    private(set) var readAllCount = 0
    private(set) var subsetRequests: [[String]] = []

    /// `keyedResults` holds canned outcomes for `read(keys:)`; anything unlisted answers
    /// `.unknownKey`, so an un-stubbed key fails visibly rather than vanishing.
    /// `allReadings` is what a successful `readAll()` enumerates. `readAllErrors` is
    /// consumed one entry per `readAll()` call, so a test can make discovery fail once and
    /// then succeed — which is how "a failed discovery is retried, not cached" is checked.
    init(
        isAvailable: Bool = true,
        keyedResults: [String: Result<SensorReading, SensorReadFailure>] = [:],
        allReadings: [SensorReading] = [],
        readAllErrors: [FakeProviderError?] = [],
        keysError: FakeProviderError? = nil
    ) {
        self.availableValue = isAvailable
        self.keyedResults = keyedResults
        self.allReadings = allReadings
        self.readAllErrors = readAllErrors
        self.keysError = keysError
    }

    var isAvailable: Bool {
        get async { availableValue }
    }

    func readAll() async throws -> [SensorReading] {
        readAllCount += 1
        if !readAllErrors.isEmpty, let error = readAllErrors.removeFirst() {
            throw error
        }
        return allReadings
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        subsetRequests.append(keys)
        if let keysError { throw keysError }
        return keys.map { key in
            SensorReadOutcome(key: key, result: keyedResults[key] ?? .failure(.unknownKey(key)))
        }
    }
}

/// A `SensorProvider` whose `readAll()` **suspends** until the test releases it, and which
/// answers a different key set to each call.
///
/// Separate from `FakeSensorProvider` rather than a flag on it, because the two doubles
/// answer different questions. `FakeSensorProvider` returns immediately, so a test driven
/// through it can only ever observe callers arriving one after another — a double with no
/// suspension in it cannot exhibit the interleaving, and a "discovery runs once" assertion
/// made against one is a claim about caching, never about concurrency.
///
/// The per-call key sets are what makes the *second* half of
/// [#149](https://github.com/blamechris/Aeolus/issues/149) visible. `SMCSensorProvider`
/// skips a key whose value read or scalar decode fails without failing the walk, so two
/// concurrent walks can legitimately return different-sized sets; whichever finishes last
/// wins a `discoveredSensors = discovered` assignment, and a short set cached there is
/// cached for the life of the daemon.
actor GatedDiscoveryProvider: SensorProvider {
    nonisolated let identifier = "gated-discovery"

    private let keyedResults: [String: Result<SensorReading, SensorReadFailure>]
    private let readingsPerCall: [[SensorReading]]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    /// How many times `readAll()` has been entered. The number #149 is about: the cache
    /// makes the *result* of a second walk invisible, so the count is the only thing that
    /// can see one happening.
    private(set) var readAllCount = 0

    /// How many subset reads have been issued. `snapshot()` enumerates fans through two of
    /// these — `FNum`, then the fan keys — before it reaches discovery, so this is how a
    /// test waits for a caller to have arrived rather than guessing with a sleep.
    private(set) var subsetReadCount = 0

    /// `readingsPerCall` is what each successive `readAll()` returns; the last entry answers
    /// every call beyond it.
    init(
        keyedResults: [String: Result<SensorReading, SensorReadFailure>],
        readingsPerCall: [[SensorReading]]
    ) {
        self.keyedResults = keyedResults
        self.readingsPerCall = readingsPerCall
    }

    var isAvailable: Bool {
        get async { true }
    }

    func readAll() async throws -> [SensorReading] {
        readAllCount += 1
        let call = readAllCount
        if !isReleased {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        return readingsPerCall[min(call, readingsPerCall.count) - 1]
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        subsetReadCount += 1
        return keys.map { key in
            SensorReadOutcome(key: key, result: keyedResults[key] ?? .failure(.unknownKey(key)))
        }
    }

    /// Lets every suspended walk — and every later one — finish.
    func release() {
        isReleased = true
        let resumed = waiters
        waiters = []
        for waiter in resumed { waiter.resume() }
    }
}

extension SensorReading {
    static func fake(key: String, value: Double, kind: Kind = .rpm) -> SensorReading {
        SensorReading(key: key, value: value, kind: kind, providerIdentifier: "fake")
    }
}

extension Result where Success == SensorReading, Failure == SensorReadFailure {
    static func reading(_ key: String, _ value: Double, kind: SensorReading.Kind = .rpm) -> Self {
        .success(.fake(key: key, value: value, kind: kind))
    }
}

/// The canned outcomes for a machine with `fanCount` fans, each with all three enumeration
/// keys readable.
///
/// Split out of `fanProvider(fanCount:…)` so a second double — `GatedDiscoveryProvider` —
/// enumerates the same machine rather than carrying its own copy of the key naming.
func fanKeyResults(
    fanCount: Int,
    extraKeys: [String: Result<SensorReading, SensorReadFailure>] = [:]
) -> [String: Result<SensorReading, SensorReadFailure>] {
    var results: [String: Result<SensorReading, SensorReadFailure>] = [
        SMCFanEnumeration.fanCountKey: .reading(SMCFanEnumeration.fanCountKey, Double(fanCount))
    ]
    for index in 0..<fanCount {
        results[SMCFanEnumeration.actualKey(forFan: index)] = .reading(
            SMCFanEnumeration.actualKey(forFan: index), 1_800 + Double(index))
        results[SMCFanEnumeration.minimumKey(forFan: index)] = .reading(
            SMCFanEnumeration.minimumKey(forFan: index), 1_200)
        results[SMCFanEnumeration.maximumKey(forFan: index)] = .reading(
            SMCFanEnumeration.maximumKey(forFan: index), 5_400)
    }
    results.merge(extraKeys) { _, new in new }
    return results
}

/// A provider stubbed to enumerate `count` fans, each with all three keys readable.
func fanProvider(
    fanCount: Int,
    extraKeys: [String: Result<SensorReading, SensorReadFailure>] = [:],
    allReadings: [SensorReading] = [],
    readAllErrors: [FakeProviderError?] = []
) -> FakeSensorProvider {
    FakeSensorProvider(
        keyedResults: fanKeyResults(fanCount: fanCount, extraKeys: extraKeys),
        allReadings: allReadings,
        readAllErrors: readAllErrors
    )
}

/// The JSON a client would send for a well-formed `hello`.
func helloPayload(
    version: Int = AeolusXPCVersion.current,
    description: String = "test client"
) throws -> Data {
    try AeolusXPCCoding.encoder().encode(
        HelloRequest(clientProtocolVersion: version, clientDescription: description))
}

/// The JSON a client would send for a well-formed lease request.
func leasePayload(
    holder: String = "test client",
    fanIndices: [Int] = [0],
    timeToLive: TimeInterval = Lease.defaultTimeToLive
) throws -> Data {
    try AeolusXPCCoding.encoder().encode(
        LeaseRequest(holderDescription: holder, fanIndices: fanIndices, timeToLive: timeToLive))
}

extension PayloadReply {
    /// The fault this reply carries, or `nil` when it carried a payload.
    var fault: AeolusXPCFault? {
        guard case .refusal(let fault) = self else { return nil }
        return fault
    }

    var payloadData: Data? {
        guard case .payload(let data) = self else { return nil }
        return data
    }
}

extension AcknowledgementReply {
    var fault: AeolusXPCFault? {
        guard case .refusal(let fault) = self else { return nil }
        return fault
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// The production control plane over `provider`, wired through the scheduler it takes its
/// turns from.
///
/// `SMCFanControlPlane` has no initialiser that skips the scheduler, so this is not a
/// convenience over a simpler shape — it *is* the shape, and every caller of this helper
/// (`SMCFanControlPlaneTests`, in another file) therefore exercises the real admission path
/// rather than a provider the plane reached directly.
func supervisorPlane(over provider: some SensorProvider) -> SMCFanControlPlane {
    SMCFanControlPlane(scheduler: SMCReadScheduler(provider: provider))
}
