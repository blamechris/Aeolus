import AeolusXPC
import FanKit
import Foundation

@testable import AeolusHelper

// MARK: - Synchronisation

/// A one-shot latch: `wait()` returns once `signal()` has happened, in either order.
///
/// The order-insensitivity is what makes the interleaving tests deterministic rather than
/// merely likely. A test that had to signal *after* the waiter arrived would be racing the
/// scheduler to set up a race, which is how a concurrency test ends up green for reasons
/// nobody chose.
///
/// `wait()` is cancellation-aware: a suspended waiter is parked on a
/// `CheckedContinuation`, which nothing but this type will ever resume, so the assertion
/// a test makes after awaiting `wait()` is what is load-bearing — `signal()` calling on
/// time is what a correct implementation does, and a missing call is exactly the bug a
/// test here exists to catch. `.timeLimit` on the enclosing `@Suite` is the *backstop*
/// for when that assertion never gets the chance to run at all: it cancels the test's
/// task, and `withTaskCancellationHandler` is what turns that cancellation into a resumed
/// continuation instead of a continuation nothing will ever touch again. Without it, a
/// suite's `.timeLimit` fires and records its issue while the awaiting task — and the
/// `swift test` process hosting it — sits parked on the continuation forever, which is a
/// killed test in the report and a hung process on the machine, not the "named, red
/// failure" `.timeLimit` is supposed to deliver.
actor AsyncSignal {

    private typealias Waiter = CheckedContinuation<Void, any Error>

    private var isSignalled = false
    private var waiters: [Waiter] = []

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    /// Resumes every still-parked waiter with `CancellationError`, without marking the
    /// signal itself as fired. This is the cancellation handler `wait()` installs — it is
    /// what lets a `.timeLimit`'s `cancelAll()` actually unblock a suspended `wait()`
    /// instead of leaving it on a continuation the time limit has no other way to reach.
    private func cancelWaiters() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }

    func wait() async throws {
        guard !isSignalled else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Waiter) in
                if isSignalled {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiters() }
        }
    }
}

// MARK: - Clocks

/// A `MonotonicClock` whose hands the test moves.
///
/// It deals in real `ContinuousClock.Instant` values, so the arithmetic under test — the
/// `advanced(by:)` and the `>=` that decide expiry — is the arithmetic that ships. What the
/// double controls is *what time it is*, never *what kind of time it is*: there is no way
/// to make production code compare a `Date` here, which is the point of `MonotonicClock`
/// pinning the instant type.
///
/// `sleep(until:)` is virtual — it jumps the clock to the deadline and returns without any
/// real time passing — so `LeaseExpirySupervisor.run` can be driven through many passes
/// instantly. After `sleepBudget` sleeps it throws `CancellationError`, which is the loop's
/// only exit, so a test can await the real loop to completion instead of cancelling a task
/// and hoping.
final class TestClock: MonotonicClock, @unchecked Sendable {

    private let lock = NSLock()
    private var instant: ContinuousClock.Instant
    private var remainingSleeps: Int
    private var recordedSleeps: [ContinuousClock.Instant] = []

    init(start: ContinuousClock.Instant = ContinuousClock.now, sleepBudget: Int = .max) {
        instant = start
        remainingSleeps = sleepBudget
    }

    var now: ContinuousClock.Instant {
        lock.withLock { instant }
    }

    /// Every deadline `sleep(until:)` was asked for, in order.
    var sleeps: [ContinuousClock.Instant] {
        lock.withLock { recordedSleeps }
    }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let exhausted: Bool = lock.withLock {
            recordedSleeps.append(deadline)
            if deadline > instant { instant = deadline }
            guard remainingSleeps > 0 else { return true }
            remainingSleeps -= 1
            return false
        }
        // Yield unconditionally, so a loop driven by this clock still gives other tasks a
        // chance to run — a virtual clock that never suspends would serialise a test that
        // is about concurrency.
        await Task.yield()
        if exhausted { throw CancellationError() }
    }
}

/// A wall clock the test can jump forwards or backwards, to prove that doing so changes
/// nothing about when a lease expires.
final class TestWallClock: @unchecked Sendable {

    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.date = date
    }

    var provider: @Sendable () -> Date {
        { [self] in lock.withLock { date } }
    }

    var current: Date { lock.withLock { date } }

    /// An NTP step, or a user setting the clock. Negative jumps backwards.
    func jump(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

// MARK: - Seams

/// The fan enumeration, with optional gates so a test can hold `acquireLease` at its
/// suspension point.
///
/// `gates` is consumed one entry per call: `nil` passes straight through, a `Gate` signals
/// that the call has arrived and then waits to be released. That is what makes
/// [#95](https://github.com/blamechris/Aeolus/issues/95)'s interleaving reproducible — the
/// authority is genuinely suspended inside `acquireLease` while the invalidation runs, which
/// is the one thing `ReadOnlyFanAuthority` could never do.
actor ScriptedFanEnumeration: FanEnumerating {

    struct Gate: Sendable {
        let entered = AsyncSignal()
        let release = AsyncSignal()
    }

    private let indices: Set<Int>
    private let failure: (any Error)?
    private var gates: [Gate?]
    private(set) var callCount = 0

    init(indices: Set<Int> = [0, 1], gates: [Gate?] = [], failure: (any Error)? = nil) {
        self.indices = indices
        self.gates = gates
        self.failure = failure
    }

    func enumeratedFanIndices() async throws -> Set<Int> {
        callCount += 1
        let gate = gates.isEmpty ? nil : gates.removeFirst()
        if let gate {
            await gate.entered.signal()
            try await gate.release.wait()
        }
        if let failure { throw failure }
        return indices
    }
}

/// Records every restore, and can be made to suspend inside one.
///
/// The recorded `cause` is what makes "the two teardown paths are independent" checkable
/// rather than assertable: a test can pin *which* mechanism put the fans back, not merely
/// that something did.
actor RecordingFanRestorer: FanRestoring {

    struct Restore: Sendable, Hashable {
        let fans: Set<Int>
        let cause: FanRestoreCause
    }

    private(set) var restores: [Restore] = []

    private let entered: AsyncSignal?
    private let release: AsyncSignal?

    init(entered: AsyncSignal? = nil, release: AsyncSignal? = nil) {
        self.entered = entered
        self.release = release
    }

    /// Restores everything it is asked for: it is the double for the paths that are about
    /// *which* mechanism restored, not about a firmware that will not take the write. The
    /// abandoning case has its own doubles, in `HandbackBoundTests`.
    func restoreToAutomatic(fans: Set<Int>, because cause: FanRestoreCause) async -> Set<Int> {
        restores.append(Restore(fans: fans, cause: cause))
        if let entered { await entered.signal() }
        // `restoreToAutomatic` is not `throws` — `FanRestoring` is production-frozen — so
        // a cancelled `release.wait()` is swallowed here rather than propagated. That is
        // still correct: the point of making `wait()` cancellation-aware is to let a
        // `.timeLimit` unblock the *awaiting test*, not to make this double report the
        // cancellation itself.
        if let release { try? await release.wait() }
        return []
    }

    var causes: [FanRestoreCause] { restores.map(\.cause) }
    var restoredFans: [Set<Int>] { restores.map(\.fans) }
}

// MARK: - The seam

/// `LeaseAuthority` composed into the frozen `FanAuthority` protocol.
///
/// It lives in the test target rather than in `Sources/` on purpose. E5.1 ships the lease
/// core; the production `FanAuthority` that owns `snapshot`, the write path and this
/// composition is the helper's control plane, which arrives with the write path. Wiring one
/// here would be claiming manual control the build cannot honour — a lease a client can
/// acquire that controls nothing is a lie about control, which is `CLAUDE.md` rule 6 and
/// exactly what `ReadOnlyFanAuthority` refuses to do.
///
/// What it *is* for: driving the lease core through the **shipped**
/// `HelperConnectionSession`, so #95's interleaving is exercised against the real listener
/// half rather than a paraphrase of it. Every method is a one-line forward, which is also
/// the cheapest available evidence that the seam E2 froze is sufficient for E5 without
/// changing it.
struct LeaseFanAuthority: FanAuthority {

    let lease: LeaseAuthority

    func snapshot() async throws -> SystemSnapshot {
        SystemSnapshot(
            fans: [],
            sensors: [],
            activeLease: await lease.activeLease(),
            isThermalEmergencyActive: false,
            capturedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    func acquireLease(
        _ request: LeaseRequest, from connection: ConnectionID
    ) async throws -> Lease {
        try await lease.acquireLease(request, from: connection)
    }

    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease {
        try await lease.renewLease(id: id, from: connection)
    }

    func releaseLease(id: UUID, from connection: ConnectionID) async throws {
        try await lease.releaseLease(id: id, from: connection)
    }

    /// Authorises, and then refuses: there is no write path in this build, and a stubbed
    /// success would be the lie the refusal exists to prevent.
    func apply(
        _ settings: [FanSetting], leaseID: UUID, from connection: ConnectionID
    ) async throws {
        _ = try await lease.heldLease(id: leaseID, from: connection)
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func restoreAllToAutomatic(from connection: ConnectionID) async throws {
        await lease.releaseEveryLease()
    }

    func connectionDidInvalidate(_ connection: ConnectionID) async {
        await lease.connectionDidInvalidate(connection)
    }
}

// MARK: - Fixtures

enum LeaseFixture {

    static let log = LeaseLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Lease")

    static func request(
        fans: [Int] = [0],
        timeToLive: TimeInterval = Lease.defaultTimeToLive,
        isSelfRenewing: Bool = false,
        holder: String = "test client"
    ) -> LeaseRequest {
        LeaseRequest(
            holderDescription: holder,
            fanIndices: fans,
            timeToLive: timeToLive,
            isSelfRenewing: isSelfRenewing
        )
    }

    /// An authority wired to doubles, with the clock and wall clock the caller controls.
    ///
    /// `telemetry` defaults to a machine that can see, because that is what an ordinary
    /// lease test is about. Blindness is opted into — `blindTelemetry()` — so that a test
    /// asserting the grant-time gate says so at its call site rather than relying on a
    /// fixture default nobody reads.
    ///
    /// It is a `SightednessProving` since #134, and every default below hands over a real
    /// `CriticalTemperatureCache`: the shipped cache is on the path of every lease test, so
    /// a coalescing bug shows up in the suite that grants leases rather than only in the one
    /// that tests the cache. Cold at construction, so the first grant in any test still
    /// performs a real read.
    ///
    /// `foreignControl` defaults to a reconciled machine on which every fan is automatic —
    /// the ordinary case, and the state a completed startup reconciliation leaves behind.
    /// A test about the gate itself supplies its own; `StartupReconciliationTests` drives
    /// the real one over scripted firmware.
    static func authority(
        enumeration: ScriptedFanEnumeration = ScriptedFanEnumeration(),
        restorer: any FanRestoring = RecordingFanRestorer(),
        writeCapability: any FanWriteCapabilityReporting = writePathBuilt(),
        telemetry: any SightednessProving = sightedTelemetry(),
        foreignControl: any ForeignManualControlSensing = automaticFans(),
        thermalEmergency: ThermalEmergencyLatch = ThermalEmergencyLatch(),
        clock: TestClock = TestClock(),
        wallClock: TestWallClock = TestWallClock(),
        tombstoneCapacity: Int = ConnectionTombstones.defaultCapacity
    ) -> LeaseAuthority {
        LeaseAuthority(
            enumeration: enumeration,
            restorer: restorer,
            writeCapability: writeCapability,
            telemetry: telemetry,
            foreignControl: foreignControl,
            thermalEmergency: thermalEmergency,
            clock: clock,
            wallClock: wallClock.provider,
            tombstoneCapacity: tombstoneCapacity,
            log: log
        )
    }

    /// A post-reconciliation baseline over a machine whose fans are all on automatic
    /// control — the **real** `StartupReconciliation` over the **real** scripted firmware,
    /// for `sightedTelemetry()`'s reason: a hand-rolled double would answer "nothing foreign
    /// here" without the grant-time read ever running, and that read is the mechanism.
    ///
    /// Eight fans rather than the two `ScriptedFanEnumeration` enumerates, so a test that
    /// names an unusual index gets an answer about *that fan's mode* rather than a
    /// `.fanNotAddressable` throw the gate would have to report as blindness.
    static func automaticFans() -> any ForeignManualControlSensing {
        reconciliation(
            over: ScriptedControlPlane(
                fans: Dictionary(
                    uniqueKeysWithValues: (0..<8).map { ($0, ScriptedControlPlane.FanCondition()) }
                ),
                stages: [.nominal(temperatures: nominalDieTemperatures)]))
    }

    /// The real `StartupReconciliation` over `plane`, wired exactly as the composition root
    /// wires it: the same restorer type, the same `.panicRestore` writer for the
    /// machine-wide verb.
    static func reconciliation(
        over plane: ScriptedControlPlane,
        enumeration: some FanEnumerating = ScriptedFanEnumeration(),
        clock: some MonotonicClock = SystemMonotonicClock(),
        budget: Duration = ReconciliationLimits.budget,
        log: SafetyLog = SafetyLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Safety")
    ) -> StartupReconciliation<ScriptedControlPlane> {
        StartupReconciliation(
            plane: plane,
            enumeration: enumeration,
            restorer: HelperFanRestorer(
                writer: SafetyActorWriter(plane: plane, level: .leaseExpiry), log: Self.log),
            panic: SafetyActorWriter(plane: plane, level: .panicRestore),
            clock: clock,
            budget: budget,
            log: log)
    }

    /// Every curated key reading a plausible idle die temperature.
    ///
    /// 44.0 °C is inside the 41.48–44.80 °C band `docs/SMC-RESEARCH.md` recorded for this
    /// cluster on an idle machine, so a test that accidentally starts comparing these
    /// against § 3's ceiling gets a realistic answer rather than a suspiciously round one.
    static var nominalDieTemperatures: [String: Double] {
        Dictionary(
            uniqueKeysWithValues: CriticalSensorSet.mac16x5.keys.map { ($0.rawValue, 44.0) })
    }

    /// Telemetry that can see — through the **real** curated conformer, not a stand-in.
    ///
    /// Wiring `CuratedCriticalTemperatures` over the scripted plane rather than writing a
    /// bespoke `CriticalTemperatureSensing` double means the curated key list and the
    /// plausibility gate are on the path every lease test exercises. A hand-rolled double
    /// would answer "sighted" without either of them ever running.
    static func sightedTelemetry() -> any SightednessProving {
        cache(
            over: ScriptedControlPlane(
                fans: [:],
                stages: [.nominal(temperatures: nominalDieTemperatures)]
            ))
    }

    /// The shipped cache over the real curated conformer over `plane`.
    ///
    /// One helper rather than the three-line expression at each call site, because the
    /// nesting is the thing a reader has to get right: the cache's `source` must be a
    /// `CriticalTemperatureSensing`, and the lease core must be handed the cache. A call site
    /// that got it backwards would not compile — which is the design — but it would also be
    /// a call site somebody had to think about.
    ///
    /// `clock` is exposed because staleness is now a property a lease test can need: a
    /// machine that goes blind *while a sighting is unexpired* is refused only after the
    /// sighting ages out, and demonstrating that needs time to pass without wall time
    /// passing.
    static func cache(
        over plane: ScriptedControlPlane,
        clock: any MonotonicClock = SystemMonotonicClock()
    ) -> CriticalTemperatureCache {
        CriticalTemperatureCache(
            source: CuratedCriticalTemperatures(plane: plane, set: .mac16x5), clock: clock)
    }

    /// A build that can write — the **real** scripted firmware, not a stand-in.
    ///
    /// The default for every lease test, because an ordinary lease test is about what
    /// happens *after* the capability gate. Answering it with `ScriptedControlPlane` rather
    /// than a bespoke one-property double is the same argument `sightedTelemetry()` makes:
    /// the conformer under the seam is the shipped one, so a change to what `.built` means
    /// reaches every test that depends on it.
    ///
    /// The empty stage is deliberate. Nothing here reads a temperature or names a fan — the
    /// capability is answered without touching the plane's state at all, which is exactly the
    /// property `FanWriteCapabilityReporting` exists to guarantee.
    static func writePathBuilt() -> any FanWriteCapabilityReporting {
        ScriptedControlPlane(fans: [:], stages: [.nominal()])
    }

    /// Telemetry that cannot see: the SMC answers nothing, for every stage, forever.
    static func blindTelemetry() -> any SightednessProving {
        cache(over: ScriptedControlPlane(fans: [:], stages: [.blind()]))
    }
}
