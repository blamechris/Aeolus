import AeolusXPC
import FanKit
import SMCCore
import Testing

@testable import AeolusHelper

/// One machine wired the way `docs/SAFETY.md` § 5's watchdog will be wired: one scripted
/// plane behind both the read seam and the writer, one thermal latch shared with § 3, one
/// ledger shared with the snapshot, and a recording restorer on the lease side.
///
/// `ThermalMachine`'s shape, and for its reasons — sharing the plane is what makes a
/// scenario legible, because `advance()` moves the firmware's behaviour and the mechanism's
/// view of it together rather than leaving two doubles to be kept in step by hand.
///
/// ## Divergence is expressed as a disagreement, not as a stage
///
/// `ScriptedControlPlane`'s stages describe the *environment*; each fan's control state is
/// separate and moves only when a write lands. So "the firmware discarded our write" is
/// scripted by giving the fan the speed the firmware kept and telling the watchdog it
/// commanded a different one — `hold(fan:commanding:whileFirmwareHolds:)` below. That is
/// exactly the state a `.reverted` write leaves behind, without needing a write to have
/// happened first, and it means a divergence scenario starts at the interesting instant.
///
/// ## Every held fan is leased, because ADR 0009 D2 judges the lease first
///
/// `hold(fan:commanding:)` and `holdWithoutCommanding(fan:)` take a lease over every fan the
/// machine has when none is live, which is what E3's control plane will have done before it
/// registers anything. Until #180 a fan could be registered with no lease at all and § 5
/// never noticed; now `examine(fanAt:)` asks the lease table before either firmware signal,
/// and an unleased fan is `.leaseLapsed` on its first cycle — so a scenario about anything
/// else has to start leased, and one about D2 ends the lease on purpose: `endLease()`, or
/// `leaseClock` advanced past the deadline.
///
/// ## Generic over the writer's plane, for the write moments
///
/// `Writes` is `ScriptedControlPlane` for every scenario but the ones that interfere inside a
/// write, which put the writer on an `InterferingFanStateSensing` through
/// `init(plane:fans:interfering:)`. The parameter is inferred from the initialiser, so no call
/// site names it.
struct ReclamationMachine<Writes: FanControlPlane> {

    let plane: ScriptedControlPlane
    /// The declared state each fan started in, kept so a permit can be minted the way E3's
    /// control plane will mint one — from a `readEnvelope`, not from figures restated here.
    let fanConditions: [Int: ScriptedControlPlane.FanCondition]
    let latch: ThermalEmergencyLatch
    let ledger: ReclamationLedger
    let restorer: RecordingFanRestorer
    /// The lease core's monotonic clock. Moved only by a test: advancing it past a deadline
    /// lapses the lease with nothing swept and nobody told, which is D2's case exactly.
    let leaseClock = TestClock()
    let leases: LeaseAuthority
    /// The connection every lease this fixture takes is bound to, so `endLease()` can end it
    /// the way a client dying does.
    let holder = ConnectionID()
    let watchdog: ReclamationWatchdog<Writes>

    /// Everything § 5 said about itself, with levels.
    let safetyLog = RecordedLog()

    /// The one wiring every initialiser below shares.
    private init(
        plane: ScriptedControlPlane,
        fans: [Int: ScriptedControlPlane.FanCondition],
        sensing: any FanStateSensing,
        writes: Writes
    ) {
        self.plane = plane
        fanConditions = fans
        latch = ThermalEmergencyLatch()
        ledger = ReclamationLedger()
        restorer = RecordingFanRestorer()
        leases = LeaseFixture.authority(
            restorer: restorer, thermalEmergency: latch, clock: leaseClock)
        watchdog = ReclamationWatchdog(
            sensing: sensing,
            writer: SafetyActorWriter(plane: writes, level: .reclamationWatchdog),
            leases: leases,
            latch: latch,
            ledger: ledger,
            log: SafetyLog(recording: { [safetyLog] in safetyLog.append($0, $1) })
        )
    }
}

extension ReclamationMachine where Writes == ScriptedControlPlane {

    /// - Parameters:
    ///   - stages: the scenario. The last stage repeats forever.
    ///   - fans: which fans the machine has, and what the firmware currently holds for each.
    ///   - sensing: the read seam, defaulting to the plane itself. Overridden only by tests
    ///     about a read failing in a way stages cannot express — an envelope that refuses
    ///     while control state still answers, or a read held open to observe concurrency.
    init(
        stages: [ScriptedControlPlane.Stage] = [.nominal()],
        fans: [Int: ScriptedControlPlane.FanCondition] = [0: .held(at: 2_400)],
        sensing: (any FanStateSensing)? = nil
    ) {
        self.init(
            plane: ScriptedControlPlane(fans: fans, stages: stages),
            fans: fans,
            sensing: sensing)
    }

    /// Wires a machine around a plane the test already built.
    ///
    /// The scenarios that need this are the ones whose read seam has to *hold a reference to
    /// the same plane* — `InterferingFanStateSensing`, which runs a side effect inside a read
    /// and then delegates to the plane. Constructing the plane inside the initialiser would
    /// leave those tests with a seam wrapping one plane and a fixture asserting against
    /// another, which is two machines pretending to be one and the exact hazard
    /// `ThermalMachine` shares a plane to avoid.
    ///
    /// `fans` is passed separately rather than read back out of the plane because the mock
    /// keeps its `FanCondition`s `private` — deliberately, so a fixture cannot depend on
    /// state the mock does not publish — and minting a permit needs the declared bounds.
    init(
        plane: ScriptedControlPlane,
        fans: [Int: ScriptedControlPlane.FanCondition] = [0: .held(at: 2_400)],
        sensing: (any FanStateSensing)? = nil
    ) {
        self.init(plane: plane, fans: fans, sensing: sensing ?? plane, writes: plane)
    }
}

extension ReclamationMachine where Writes == InterferingFanStateSensing {

    /// Puts **both** seams on `interfering`, so a scenario can act inside one of § 5's writes
    /// as well as inside one of its reads.
    ///
    /// The writer has to be on the double for a write moment to fire at all:
    /// `SafetyActorWriter` talks to its plane directly, and a read seam it never calls cannot
    /// see the write. Every verb delegates to `plane`, so `attempts` is still the record of what
    /// § 5 did.
    init(
        plane: ScriptedControlPlane,
        fans: [Int: ScriptedControlPlane.FanCondition] = [0: .held(at: 2_400)],
        interfering: InterferingFanStateSensing
    ) {
        self.init(plane: plane, fans: fans, sensing: interfering, writes: interfering)
    }
}

extension ReclamationMachine {

    /// Puts a fan under this watchdog's care, having commanded `rpm` on it.
    ///
    /// What E3's control plane will do: engage manual control, command a target, and hand
    /// both facts to the mechanisms that need them. The firmware's own state is whatever
    /// the fixture was constructed with, so a caller wanting convergence gives the fan the
    /// same number it commands.
    func hold(fan index: Int, commanding rpm: Double) async throws {
        try await holdWithoutCommanding(fan: index)
        await watchdog.commandedTarget(CommandedTarget(fanIndex: index, rpm: rpm))
    }

    /// Registers a fan with no target ever commanded on it.
    ///
    /// The state between `engageManualControl` and the first write. The mode check is the
    /// whole of what § 5 can say about such a fan.
    ///
    /// Leased first when no lease is live — see "Every held fan is leased" on this type. A
    /// scenario that took its own lease keeps it: the question is whether *any* lease is live,
    /// so an explicit `lease(fans:)` first is never doubled, and one over a subset leaves the
    /// other fans unleased on purpose.
    func holdWithoutCommanding(fan index: Int) async throws {
        let condition = try #require(fanConditions[index])
        if await leases.activeLease() == nil {
            try await lease(fans: fanConditions.keys.sorted())
        }
        await watchdog.manualControlEngaged(try commandableFan(index, declaring: condition))
    }

    /// Takes a lease over `fans`, bound to `holder`, so that a revocation is observable.
    @discardableResult
    func lease(fans: [Int] = [0]) async throws -> Lease {
        try await leases.acquireLease(LeaseFixture.request(fans: fans), from: holder)
    }

    /// Ends every lease this fixture took, the way a client dying does: the lease core drops
    /// the entry and hands the fans to its restorer — `RecordingFanRestorer` here, which tells
    /// § 5 nothing and writes nothing to `plane`. That silence is the point: `held` is a hint,
    /// and ADR 0009 D2 must not need it.
    func endLease() async {
        await leases.connectionDidInvalidate(holder)
    }

    /// Lapses every lease this fixture took by moving the lease core's clock past the deadline,
    /// and sweeps nothing: the entry stays in the table, as it does until
    /// `LeaseExpirySupervisor` next wakes.
    func lapseLease() {
        leaseClock.advance(by: .seconds(Lease.defaultTimeToLive + 1))
    }

    /// Engages § 3's latch, which is what makes level 2 the incumbent.
    func engageThermalEmergency(atCelsius celsius: Double = 99) async {
        await latch.engage(
            by: CriticalTemperature(key: smcKey("Tp01"), celsius: celsius),
            answering: [smcKey("Tp01")])
    }

    /// Every call the firmware saw, in order.
    var attempts: [ScriptedControlPlane.Attempt] {
        get async { await plane.attempts }
    }

    /// Every target this mechanism put on the wire.
    var commandedRPMs: [Double] {
        get async { await plane.attempts.compactMap(\.commandedRPM) }
    }

    /// Whether the watchdog restored this fan to automatic control.
    func didRestore(fan index: Int) async -> Bool {
        await plane.attempts.contains(.restoreToAutomatic(.fan(index)))
    }
}

// MARK: - Read seams stages cannot express

/// Answers control state from the plane and refuses **every** envelope.
///
/// `ScriptedControlPlane` reads a fan's declared bounds from its own `FanCondition`, and a
/// scenario cannot change one mid-run — stages describe the environment, not the fans. So
/// "the control state still reads while the envelope does not" has no stage that expresses
/// it, and it is precisely the state § 5's re-assert has to survive: a fan that is visibly
/// diverged and whose bounds cannot be established, where the only lawful action is the
/// bounds-free restore verb.
///
/// A fan whose declared bounds are *implausible* cannot be scripted the obvious way either,
/// because minting the permit that registers it with the watchdog runs the same gate and
/// fails first. This double reaches the branch from the other side.
struct EnvelopeRefusingSensing: FanStateSensing {

    let plane: ScriptedControlPlane
    let reason: String

    init(_ plane: ScriptedControlPlane, reason: String = "the envelope did not decode") {
        self.plane = plane
        self.reason = reason
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        throw FanControlPlaneError.readFailed(detail: "fan \(index) envelope: \(reason)")
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        try await plane.readControlState(ofFan: index)
    }

    func reconnect() async throws {
        try await plane.reconnect()
    }
}

/// Answers control state from a scripted sequence of readings — one per read — and delegates
/// everything else to the plane.
///
/// ## Why a double and not a stage, again
///
/// `ScriptedControlPlane` keeps each fan's `FanCondition` private and moves it only when a
/// write lands; stages describe the *environment*, not the fans. So no scenario built on the
/// mock alone can make one fan read divergent, then converged, then divergent again with no
/// write in between. That alternation is exactly what `HeldFan.uncommandedDivergentCycles`
/// being *spent, never reset* is a rule about, and a flaky `F<n>Tg` — readable one second and
/// not the next — is the hardware story behind it.
///
/// Readings are whole `FanControlState` values rather than `FanCondition`s so a scenario can
/// say `.unreadable` outright instead of routing a `NaN` through the mock's finiteness rule,
/// which is the mock's own contract to apply and not this type's to restate. The last reading
/// repeats forever, `ScriptedControlPlane.Stage`'s convention, so a scenario scripts only the
/// part that changes.
///
/// **One fan's worth of scenario.** Every read is served from the same sequence whatever fan
/// is asked about, so a multi-fan scenario needs a different double.
actor ScriptedReadingsSensing: FanStateSensing {

    private let plane: ScriptedControlPlane
    private let readings: [FanControlState]

    /// How many control-state reads were served.
    ///
    /// Asserted on by every test using this type, for `InterferingFanStateSensing.didFire`'s
    /// reason: a scenario that stopped being examined part-way through would go on passing
    /// its later assertions by never looking at the fan again.
    private(set) var readCount = 0

    init(_ plane: ScriptedControlPlane, reading readings: [FanControlState]) {
        precondition(!readings.isEmpty, "a scripted read seam with no readings answers nothing")
        self.plane = plane
        self.readings = readings
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        let reading = readings[min(readCount, readings.count - 1)]
        readCount += 1
        return reading
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await plane.readEnvelope(ofFan: index)
    }

    func reconnect() async throws {
        try await plane.reconnect()
    }
}

/// Holds every control-state read open until the test lets it go, and records how many were
/// in flight at once.
///
/// The only way to observe § 5's sequential-read decision. `ScriptedControlPlane`'s methods
/// have no suspension point inside them, so two concurrent callers could never be seen to
/// overlap there however the watchdog issued them — a test built on the mock alone would
/// pass against a `withTaskGroup` implementation and prove nothing. Suspending inside the
/// read is what makes "one at a time" observable.
///
/// `open()` rather than a release-one-at-a-time protocol, because a test that has to keep
/// feeding a gate wedges the moment the implementation issues one fewer read than it
/// expected — which is the failure `yieldUntil` exists to convert into a red assertion, and
/// which is worth not writing in the first place.
///
/// The gate's continuation is cancellation-aware. `itExaminesFansSequentially` never awaits
/// `cycle()`'s task directly — it uses `finished(_:_:)`, whose bounded poll-and-cancel is
/// what is load-bearing when `open()` never comes — but that cancellation only *finishes*
/// the abandoned task, rather than leaving it parked here forever, because
/// `withTaskCancellationHandler` turns `cycle()`'s task being cancelled into this
/// continuation resuming with `CancellationError`. Without it, `finished(_:_:)` still
/// returns and the test still fails on time, but the cancelled task itself — and the actor
/// it is suspended inside — would stay parked for the rest of the process's life.
actor GatedFanStateSensing: FanStateSensing {

    private typealias Waiter = CheckedContinuation<Void, any Error>

    private let plane: ScriptedControlPlane
    private var waiters: [Waiter] = []
    private var isOpen = false

    /// Which fans have been asked about, in order.
    private(set) var controlStateRequests: [Int] = []
    private var outstanding = 0
    /// The most control-state reads in flight simultaneously. **The assertion this type
    /// exists for**: sequential examination can never exceed one.
    private(set) var peakOutstanding = 0

    init(_ plane: ScriptedControlPlane) {
        self.plane = plane
    }

    /// Lets every waiting read through, and stops gating the ones that follow.
    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Resumes every still-parked read with `CancellationError`, without opening the gate.
    /// This is the cancellation handler `readControlState(ofFan:)` installs, so that
    /// cancelling the task it runs in — whatever cancels it, `finished(_:_:)`'s explicit
    /// `task.cancel()` included — reaches a read parked here waiting on `open()` instead of
    /// leaving it suspended for good.
    private func cancelWaiters() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        controlStateRequests.append(index)
        outstanding += 1
        peakOutstanding = max(peakOutstanding, outstanding)
        if !isOpen {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: Waiter) in
                    if isOpen {
                        continuation.resume()
                    } else {
                        waiters.append(continuation)
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiters() }
            }
        }
        outstanding -= 1
        return try await plane.readControlState(ofFan: index)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await plane.readEnvelope(ofFan: index)
    }

    func reconnect() async throws {
        try await plane.reconnect()
    }
}

/// Runs an arbitrary side effect **inside** one of § 5's reads or writes, so that "the world
/// changed across this `await`" is a scenario rather than an argument.
///
/// ## Why a double and not a stage
///
/// `ScriptedControlPlane`'s methods contain no suspension point a test can act inside, so a
/// scenario built on stages alone can only change the machine *between* cycles. Every defect
/// this type exists to cover happens *within* one — a lease expiring while a control-state
/// read is in flight, § 3 latching while a re-assert is part-way through — and those are
/// exactly the interleavings a reentrant actor is exposed to and a sequential test cannot
/// reach.
///
/// An adversarial review found four separate defects of that shape in `ReclamationWatchdog`,
/// every one of them invisible to the twenty tests that existed at the time. A concurrency
/// test that starts all its work at once cannot see a bug that needs work to *arrive*; this
/// makes the arrival scriptable.
///
/// The effect fires **once**, on the first read or write of the chosen kind. A side effect that
/// ran on every one would make a scenario that loops — a budget driven to exhaustion, a dwell
/// counted out — untestable, because the world would move under every cycle instead of once.
///
/// ## The write seam too, since #180
///
/// It is a `FanControlPlane` as well as a read seam, because the write-side defect #180 names
/// could not be reached from a read: `reassert(_:fanAt:attempt:)` assigned what its command
/// write returned through `held[index]?.commanded`, and a lease released *during that write*
/// made the assignment vanish while § 5 logged a successful re-assert. With only the two read
/// moments, nothing could release a lease there — which is why it survived #136's review. A
/// write moment fires **after** the firmware has taken the write and while § 5 is still
/// awaiting it, so the scenario is the worst one: the write landed, then the lease went. It
/// fires only when the writer is on this double — `ReclamationMachine(plane:fans:interfering:)`.
actor InterferingFanStateSensing: FanControlPlane {

    /// Which read or write the effect happens inside.
    enum Moment: Sendable {
        /// Inside `readControlState(ofFan:)` — the suspension `examine(fanAt:)` resumes from.
        case controlStateRead
        /// Inside `readEnvelope(ofFan:)` — the suspension `reassert(_:fanAt:attempt:)`
        /// resumes from, and the one whose missing re-check wrote `F<n>Md` to an unleased fan.
        case envelopeRead
        /// Inside `engageManualControl(of:)`, once `F<n>Md` has landed: between the re-assert's
        /// mode write and its command write.
        case engageWrite
        /// Inside `commandTarget(_:)`, once `F<n>Tg` has landed: between the re-assert's command
        /// write and its post-write ruling.
        case commandWrite
        /// Inside `restoreToAutomatic(_:)`, once the restore has landed — the instant a
        /// scenario can ask what § 5 had recorded about a fan as it handed it back.
        case restoreWrite
    }

    private let plane: ScriptedControlPlane
    private let moment: Moment
    private var effect: (@Sendable () async -> Void)?
    private var hasFired = false

    /// Whether the effect actually ran.
    ///
    /// Asserted by every test using this type. A double whose interference silently never
    /// fired would leave the test passing for the wrong reason — the exact "test that cannot
    /// fail" shape this repository keeps producing — so the scenario is required to prove
    /// its own setup happened.
    private(set) var didFire = false

    init(_ plane: ScriptedControlPlane, during moment: Moment) {
        self.plane = plane
        self.moment = moment
    }

    /// Sets what happens inside the read. Assigned after construction because the effect
    /// usually needs the watchdog, which needs this.
    func interfere(with effect: @escaping @Sendable () async -> Void) {
        self.effect = effect
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        if moment == .controlStateRead { await fireOnce() }
        return try await plane.readControlState(ofFan: index)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        if moment == .envelopeRead { await fireOnce() }
        return try await plane.readEnvelope(ofFan: index)
    }

    func reconnect() async throws {
        try await plane.reconnect()
    }

    // MARK: - The write seam

    /// `.built`, for `ScriptedControlPlane.writeCapability`'s reason: this is a double over
    /// firmware that takes writes, and whether one lands is the plane's stage to say.
    nonisolated var writeCapability: FanWriteCapability { .built }

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await plane.readCriticalTemperatures(keys)
    }

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        try await plane.restoreToAutomatic(scope)
        if moment == .restoreWrite { await fireOnce() }
    }

    func engageManualControl(of fan: CommandableFan) async throws {
        try await plane.engageManualControl(of: fan)
        if moment == .engageWrite { await fireOnce() }
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        let commanded = try await plane.commandTarget(target)
        if moment == .commandWrite { await fireOnce() }
        return commanded
    }

    private func fireOnce() async {
        guard !hasFired, let effect else { return }
        hasFired = true
        await effect()
        didFire = true
    }
}
