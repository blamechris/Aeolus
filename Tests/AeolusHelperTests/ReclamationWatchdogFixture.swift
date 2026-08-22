import AeolusXPC
import FanKit
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
struct ReclamationMachine {

    let plane: ScriptedControlPlane
    /// The declared state each fan started in, kept so a permit can be minted the way E3's
    /// control plane will mint one — from a `readEnvelope`, not from figures restated here.
    let fanConditions: [Int: ScriptedControlPlane.FanCondition]
    let latch: ThermalEmergencyLatch
    let ledger: ReclamationLedger
    let restorer: RecordingFanRestorer
    let leases: LeaseAuthority
    let watchdog: ReclamationWatchdog<ScriptedControlPlane>

    /// Everything § 5 said about itself, with levels.
    let safetyLog = RecordedLog()

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
        self.plane = plane
        fanConditions = fans
        latch = ThermalEmergencyLatch()
        ledger = ReclamationLedger()
        restorer = RecordingFanRestorer()
        leases = LeaseFixture.authority(restorer: restorer, thermalEmergency: latch)
        watchdog = ReclamationWatchdog(
            sensing: sensing ?? plane,
            writer: SafetyActorWriter(plane: plane, level: .reclamationWatchdog),
            leases: leases,
            latch: latch,
            ledger: ledger,
            log: SafetyLog(recording: { [safetyLog] in safetyLog.append($0, $1) })
        )
    }

    /// Puts a fan under this watchdog's care, having commanded `rpm` on it.
    ///
    /// What E3's control plane will do: engage manual control, command a target, and hand
    /// both facts to the mechanisms that need them. The firmware's own state is whatever
    /// the fixture was constructed with, so a caller wanting convergence gives the fan the
    /// same number it commands.
    func hold(fan index: Int, commanding rpm: Double) async throws {
        let condition = try #require(fanConditions[index])
        await watchdog.manualControlEngaged(try commandableFan(index, declaring: condition))
        await watchdog.commandedTarget(CommandedTarget(fanIndex: index, rpm: rpm))
    }

    /// Registers a fan with no target ever commanded on it.
    ///
    /// The state between `engageManualControl` and the first write. The mode check is the
    /// whole of what § 5 can say about such a fan.
    func holdWithoutCommanding(fan index: Int) async throws {
        let condition = try #require(fanConditions[index])
        await watchdog.manualControlEngaged(try commandableFan(index, declaring: condition))
    }

    /// Takes a lease over `fans`, so that a revocation is observable.
    @discardableResult
    func lease(
        fans: [Int] = [0], from connection: ConnectionID = ConnectionID()
    ) async throws -> Lease {
        try await leases.acquireLease(LeaseFixture.request(fans: fans), from: connection)
    }

    /// Engages § 3's latch, which is what makes level 2 the incumbent.
    func engageThermalEmergency(atCelsius celsius: Double = 99) async {
        await latch.engage(by: CriticalTemperature(key: smcKey("Tp01"), celsius: celsius))
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
actor GatedFanStateSensing: FanStateSensing {

    private let plane: ScriptedControlPlane
    private var waiters: [CheckedContinuation<Void, Never>] = []
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

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        controlStateRequests.append(index)
        outstanding += 1
        peakOutstanding = max(peakOutstanding, outstanding)
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
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

/// Runs an arbitrary side effect **inside** one of § 5's reads, so that "the world changed
/// across this `await`" is a scenario rather than an argument.
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
/// The effect fires **once**, on the first read of the chosen kind. A side effect that ran on
/// every read would make a scenario that loops — a budget driven to exhaustion, a dwell
/// counted out — untestable, because the world would move under every cycle instead of once.
actor InterferingFanStateSensing: FanStateSensing {

    /// Which read the effect happens inside.
    enum Moment: Sendable {
        /// Inside `readControlState(ofFan:)` — the suspension `examine(fanAt:)` resumes from.
        case controlStateRead
        /// Inside `readEnvelope(ofFan:)` — the suspension `reassert(_:fanAt:attempt:)`
        /// resumes from, and the one whose missing re-check wrote `F<n>Md` to an unleased fan.
        case envelopeRead
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

    private func fireOnce() async {
        guard !hasFired, let effect else { return }
        hasFired = true
        await effect()
        didFire = true
    }
}
