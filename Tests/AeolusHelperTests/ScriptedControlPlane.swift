import FanKit
import SMCCore

@testable import AeolusHelper

/// The mock SMC `docs/SAFETY.md` promises every safety mechanism will be tested against.
///
/// Every failure path E5 has to survive is a **state this can be scripted into**, so that
/// "the watchdog notices reclamation" is a test rather than an argument: firmware that
/// refuses writes, firmware that accepts a write and discards it, temperatures that drift
/// past a ceiling and back below it, an SMC that stops answering reads for one cycle or
/// forever, and a fan whose declared envelope is nonsense.
///
/// ## A scenario is a sequence of stages, not a pile of flags
///
/// A `Stage` is everything the firmware is doing at one moment. A scenario is an array of
/// them, and the test moves between them with `advance()`:
///
/// ```swift
/// let plane = ScriptedControlPlane(
///     fans: [0: .nominal],
///     stages: [
///         .nominal(temperatures: ["TC0P": 55]),
///         .nominal(temperatures: ["TC0P": 97]),   // above the ceiling
///         .nominal(temperatures: ["TC0P": 70]),   // inside the hysteresis band
///         .nominal(temperatures: ["TC0P": 55]),   // released
///     ])
/// ```
///
/// The alternative — `shouldFailReads`, `shouldRevert`, `failOnCall: 3` — cannot express
/// "fails, then recovers, then fails again" without a second flag for the sequence, and the
/// resulting scenario is legible only to whoever wrote it. Two booleans also admit states
/// no firmware can be in; the three-case `WriteBehaviour` below admits exactly three.
///
/// **Advancing is explicit.** `ScriptedSensorProvider` in `Tests/fanctlTests` has to infer
/// tick boundaries from which method a caller happens to reach first, and its own
/// documentation records the bug that produced: a shared cursor advanced by whichever call
/// ran first shifted every value one tick early. Nothing on this seam is a reliable
/// once-per-cycle anchor — the supervisor reads temperatures every cycle but a fan's mode
/// only sometimes — so there is no cursor to get wrong here. The test says when time moves.
///
/// ## What it holds versus what the stage says
///
/// The stage describes the **environment**: what the firmware does to a write, whether the
/// SMC answers at all, and what the thermistors read. The mock separately holds each fan's
/// **control state**, because that is the thing writes mutate and later reads observe.
/// Advancing a stage therefore does not undo a write — a scenario that commands a target
/// and then drives the temperature up still sees the target it commanded.
///
/// ## Unscripted input is refused, never answered
///
/// Asking about a fan this machine does not have throws `.fanNotAddressable`. It does not
/// return a default. A double that answers an unstubbed input with an empty success is the
/// single most common way this repository has produced a test that passes while being
/// structurally unable to reach the failure it names — `ScriptedSensorProvider` carries the
/// same warning about a `try?` that turned a failing tick into an empty success.
actor ScriptedControlPlane: FanControlPlane {

    // MARK: - Scripting vocabulary

    /// Everything the firmware is doing at one moment.
    struct Stage: Sendable, Hashable {
        /// What each critical temperature key reads, in °C. A key absent from this
        /// dictionary is one the firmware does not answer this stage — which is how "one
        /// thermistor dropped out" is distinguished from "the SMC stopped answering", the
        /// second being `reads`.
        var temperatures: [String: Double]
        /// Whether the SMC answers reads at all this stage. A stale `io_connect_t` after
        /// wake (#68) looks like this, and so does a dead connection.
        var reads: ReadBehaviour
        /// What the firmware does with a mode or target write this stage.
        var writes: WriteBehaviour
        /// Whether rebuilding the SMC connection succeeds this stage.
        ///
        /// Independent of `reads`, because the interesting scenario is precisely the one
        /// where they disagree: a reconnect that returns cleanly while reads keep failing is
        /// what `SAFETY.md` § 5 means by *"attempt a reconnect, **then** restore automatic
        /// and report"* — the restore is not conditional on the reconnect having worked.
        /// A mock that tied the two together could not express that, and would agree with an
        /// implementation that skipped the restore whenever the reconnect succeeded.
        var reconnects: ReconnectBehaviour
        /// What the firmware does with a **target** write specifically, when that differs
        /// from what it does with a mode write. `nil` means "whatever `writes` says".
        ///
        /// One axis could not express the state § 5's re-assert has to survive. Firmware
        /// that accepts `F<n>Md` and then refuses `F<n>Tg` leaves a fan **off** Apple's
        /// thermal management holding a speed nobody chose — the worst reachable state in
        /// this project — where firmware that refuses both leaves it safely on automatic.
        /// A single `WriteBehaviour` made those two indistinguishable, so the watchdog's
        /// half-landed branch had nothing that could reach it.
        var targetWrites: WriteBehaviour?
        /// What the firmware does with a **force-key** write, when that differs from `writes`.
        /// `nil` means "whatever `writes` says". The case it exists for is a restore whose mode
        /// write is refused and whose key clear is not (ADR 0014 D5): every write is attempted.
        var forceKeyWrites: WriteBehaviour?
        /// Fans whose `F<n>Md` does not answer this stage, on an SMC that otherwise does: every
        /// read of the key throws `.readFailed`, while temperatures, the envelope and every write
        /// behave as the rest of the stage says
        /// ([#360](https://github.com/blamechris/Aeolus/issues/360)).
        ///
        /// `reads` cannot say it, because a failed stage blinds the critical temperatures too,
        /// and the grant then refuses for telemetry before it reaches its read of the fan. And it
        /// is a property of the firmware rather than of a wrapper round it, so the snapshot's own
        /// read of the key — `PlaneBackedProvider`, through `firmwareMode(ofFan:)` — fails on
        /// exactly the fans the plane's reads do.
        var unreadableModes: Set<Int>
        /// What `F<n>Mx` reads this stage for a fan whose read is not its declared
        /// `FanCondition.maximumRPM` ([#270](https://github.com/blamechris/Aeolus/issues/270)):
        /// a byte-swapped value, or a key that does not answer.
        ///
        /// A property of the firmware's reads rather than of the fan's control state, for
        /// `unreadableModes`' reason: the snapshot's own read of the key — `PlaneBackedProvider`,
        /// through `firmwareBound(_:ofFan:)` — and the grant's `readEnvelope(ofFan:)` then read
        /// the **one** value, so an agreement test asserts that two reads agree rather than that
        /// two scripts do. And a stage, so a fan can be leased under plausible bounds and read
        /// implausible ones afterwards, which is how a fan in a handback register is scripted.
        var maximumReads: [Int: BoundRead]
        /// `maximumReads`' counterpart for `F<n>Mn`, so the grant's judgement of the minimum is
        /// scripted too: without it, a gate that judged a constant minimum stayed green.
        ///
        /// Defaulted rather than an `init` parameter, and set on a built stage
        /// (`AvailabilityFixture.fanZeroMinimum(_:)`), so the actor's own body stays inside
        /// `type_body_length`'s warning.
        var minimumReads: [Int: BoundRead] = [:]
        /// Fans whose `F<n>Tg` holds no accepted target even at the command's in-turn read-back
        /// this stage, so the command throws `.targetNotConfirmed` (#9); `.reverted` is a target
        /// held at the read-back and discarded after it. Set on a built stage
        /// (`holdingNoTarget(ofFan:)`), for `minimumReads`' reason.
        var targetsNotHeldAtReadBack: Set<Int> = []

        init(
            temperatures: [String: Double] = [:],
            reads: ReadBehaviour = .answered,
            writes: WriteBehaviour = .honoured,
            reconnects: ReconnectBehaviour = .refused(
                reason: "the SMC did not come back; see SMCFanControlPlane.reconnect()"),
            targetWrites: WriteBehaviour? = nil,
            forceKeyWrites: WriteBehaviour? = nil,
            unreadableModes: Set<Int> = [],
            maximumReads: [Int: BoundRead] = [:]
        ) {
            self.temperatures = temperatures
            self.reads = reads
            self.writes = writes
            self.reconnects = reconnects
            self.targetWrites = targetWrites
            self.forceKeyWrites = forceKeyWrites
            self.unreadableModes = unreadableModes
            self.maximumReads = maximumReads
        }

        /// A stage where the SMC answers and the machine reads as given.
        ///
        /// `writes` is a parameter rather than always `.honoured` because § 5's scenarios
        /// are about a machine that reads perfectly and does not keep what it is told —
        /// which is `.reverted`, on an otherwise nominal stage.
        static func nominal(
            temperatures: [String: Double] = [:],
            writes: WriteBehaviour = .honoured,
            targetWrites: WriteBehaviour? = nil,
            forceKeyWrites: WriteBehaviour? = nil
        ) -> Stage {
            Stage(
                temperatures: temperatures, writes: writes, targetWrites: targetWrites,
                forceKeyWrites: forceKeyWrites)
        }

        /// A stage where the SMC answers nothing. One of these is a transient failure; a
        /// run of them to the end of the script is a persistent one, because the last stage
        /// repeats forever.
        ///
        /// `reconnects` defaults to refused, so a blind scenario that says nothing about
        /// reconnecting gets the harder branch: the read is dark and the rebuild did not
        /// help either. A scenario that wants the reconnect to return cleanly while reads
        /// keep failing asks for it, because that disagreement is the interesting case: § 5
        /// restores either way.
        static func blind(
            reason: String = "the SMC did not answer",
            reconnects: ReconnectBehaviour = .refused(
                reason: "the SMC did not come back; see SMCFanControlPlane.reconnect()")
        ) -> Stage {
            Stage(reads: .failed(reason: reason), reconnects: reconnects)
        }
    }

    /// Whether the SMC answers reads this stage.
    enum ReadBehaviour: Sendable, Hashable {
        case answered
        case failed(reason: String)
    }

    /// Whether rebuilding the connection works this stage.
    ///
    /// The default is `.refused`, and until #168 the reason was that this matched
    /// `SMCFanControlPlane.reconnect()`, which had no body. It has one now, so the default
    /// is a *scenario* choice rather than a mirror of the build: every stage that defaults
    /// here is a § 5 blindness scenario, and the point of those is that the restore happens
    /// whether or not the reconnect worked. A default of `.succeeded` would quietly make
    /// every one of them test the easy branch.
    enum ReconnectBehaviour: Sendable, Hashable {
        /// The call returns. It says nothing about whether reads now work — that is
        /// `ReadBehaviour`'s, on this stage or the next.
        case succeeded
        case refused(reason: String)
    }

    /// What the firmware does with a control write this stage.
    ///
    /// Three states on one axis, which is what makes a scenario readable. `.reverted` is
    /// the reclamation signal `SAFETY.md` §5 exists for, and it applies to restore writes
    /// too: firmware that accepts a restore and leaves the fan manual is the one case
    /// [ADR 0007](../../docs/ADR/0007-safety-composition.md) names as defeating everything
    /// in E5, so it must be scriptable rather than assumed away.
    enum WriteBehaviour: Sendable, Hashable {
        /// The write lands and reads back.
        case honoured
        /// The firmware refuses it. Nothing changes and the call throws.
        case refused(reason: String)
        /// The firmware accepts the write and then discards it: the call succeeds and the
        /// fan keeps the state it had. Nothing but a read-back can tell the difference,
        /// which is exactly why the watchdog compares against what it last commanded.
        ///
        /// **A target write is held at the command's in-turn read-back and discarded after it**
        /// (#9; ADR 0014's B1 amendment). B1's command turn reads `F<n>Tg` back before it
        /// returns, so a target dropped before that read is a command that throws
        /// (`Stage.targetsNotHeldAtReadBack`); this is the firmware that drops it later, so the
        /// command returns the requested value and only a later read sees the old one. A mode
        /// write is discarded before an engagement's own read-back, which reads the mode it had.
        case reverted
    }

    /// How the firmware answers an engagement's mode writes on an honoured stage: the unlock
    /// model ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D3), every case a
    /// hypothesis the hardware runs will confirm or refute.
    enum UnlockBehaviour: Sendable, Hashable {
        /// A naive `F<n>Md = 1` is accepted and applied: the system is not asserting control.
        case naive
        /// Refuse-then-yield: every mode write is answered `0x82` until the force key is set,
        /// and `stepsToYield` more after that; then it is accepted and applied.
        case heldUntilForced(stepsToYield: Int)
        /// Every mode write is answered `0x82`, force key or not: the yield never arrives.
        case neverYields
        /// The mode write is answered with this code — neither `0x00` nor `0x82`.
        case answers(code: UInt8)
        /// The mode write is accepted and raw `F<n>Md` reads back this value: `0` is
        /// accepted-not-applied (#291), anything but `1` is outside the hypothesis.
        case readsBack(rawMode: UInt8)
    }

    /// One key write this plane received, whatever the firmware answered, in order.
    enum KeyWrite: Sendable, Hashable {
        /// `F<n>Md = value`.
        case mode(fan: Int, value: UInt8)
        /// `Ftst = value`.
        case forceKey(UInt8)
        /// `F<n>Tg = rpm`: a target command the plane admitted, so the write itself is observed
        /// rather than only the attempt (ADR 0014's #410 ticket-and-seal amendment).
        case target(fan: Int, rpm: Double)
    }

    /// One fan as the firmware currently has it. Mutated by writes the firmware honours.
    struct FanCondition: Sendable, Hashable {
        var mode: FirmwareFanMode
        var targetRPM: Double
        var minimumRPM: Double
        var maximumRPM: Double

        /// What `F<n>Ac` reads — the speed the fan is actually turning at.
        ///
        /// **Set independently of `targetRPM`, and a honoured write does not move it.**
        /// That separation is the whole point: a real fan slews toward its target rather
        /// than stepping, so a mock that snapped the actual speed to every commanded target
        /// could not express the one state § 5's primary signal exists to survive — a ramp
        /// in flight, where the target reads back correctly and the actual speed does not
        /// match it yet. A test that wants the fan to have arrived says so, with
        /// `arrived(at:)` or by advancing to a stage that sets it.
        var actualRPM: Double

        init(
            mode: FirmwareFanMode = .automatic,
            targetRPM: Double = 1_800,
            actualRPM: Double = 1_800,
            minimumRPM: Double = 1_350,
            maximumRPM: Double = 5_777
        ) {
            self.mode = mode
            self.targetRPM = targetRPM
            self.actualRPM = actualRPM
            self.minimumRPM = minimumRPM
            self.maximumRPM = maximumRPM
        }

        /// A fan already under manual control, holding and turning at `rpm`.
        ///
        /// The state a client's fan is in between its first write and anything going wrong,
        /// and therefore the starting point of every § 5 scenario that is about something
        /// other than engaging.
        static func held(at rpm: Double) -> FanCondition {
            FanCondition(mode: .manual, targetRPM: rpm, actualRPM: rpm)
        }

        /// On Apple's thermal management, at `rpm`.
        ///
        /// `held(at:)`'s counterpart, and worth having by name since #164: a fan's *mode*
        /// now decides whether startup reconciliation restores it and whether the lease core
        /// calls it foreign control, so a fixture that only wanted "spinning at 2400" must be
        /// able to say so without also saying "somebody is holding it".
        static func automatic(at rpm: Double) -> FanCondition {
            FanCondition(mode: .automatic, targetRPM: rpm, actualRPM: rpm)
        }

        /// A fan under manual control that has been *told* `target` and is still turning at
        /// `actual` — a ramp in flight.
        ///
        /// § 5's primary signal must read this as convergence and its secondary signal must
        /// not fire on it before the dwell. Both are acceptance criteria on
        /// [#126](https://github.com/blamechris/Aeolus/issues/126).
        static func ramping(target: Double, actual: Double) -> FanCondition {
            FanCondition(mode: .manual, targetRPM: target, actualRPM: actual)
        }

        /// A fan on automatic control with the development machine's measured envelope.
        static let nominal = FanCondition()

        /// A fan whose firmware declares a minimum of zero — real on some Macs, and the
        /// case that makes a bare `[F0Mn, F0Mx]` clamp vacuous against `CLAUDE.md` rule 3.
        /// It is **accepted, not refused**: what makes zero uncommandable is the floor in
        /// `FanControlEnvelope`, not a gate that would deny manual control on every Mac
        /// whose fans idle at rest. Contrast `invertedBounds` below, which really is
        /// refused.
        static let zeroMinimum = FanCondition(minimumRPM: 0)

        /// A fan whose declared envelope is inverted. #37's plausibility gate, which has to
        /// refuse rather than clamp into a range that does not exist.
        static let invertedBounds = FanCondition(minimumRPM: 5_777, maximumRPM: 1_350)

        /// A fan whose declared bounds did not decode. The seam refuses to hand these on at
        /// all — see `FanControlPlaneValue.finite(_:describing:)` — so this surfaces as a
        /// read failure rather than as an implausible number.
        static let undecodableBounds = FanCondition(minimumRPM: .nan, maximumRPM: .infinity)
    }

    /// One call this plane received, in order, whether or not it succeeded.
    ///
    /// Recorded before any refusal, because "the supervisor reached its terminal action" is
    /// a claim about a call that was *made*, and a refused restore is still a restore that
    /// was attempted. A test that could only see successful calls could not tell a
    /// supervisor that never tried from one that tried and was refused.
    enum Attempt: Sendable, Hashable {
        case readCriticalTemperatures([SMCKey])
        case readEnvelope(fan: Int)
        case readControlState(fan: Int)
        case restoreToAutomatic(FanRestoreScope)
        case engageManualControl(fan: Int)
        case commandTarget(fan: Int, rpm: Double)
        case reconnect
    }

    // MARK: - State

    private let stages: [Stage]
    private var stageIndex = 0
    private var fans: [Int: FanCondition]
    private(set) var attempts: [Attempt] = []

    /// Every key write, in order, recorded before the firmware answers — the order a restore
    /// issues its writes in is ADR 0014 D5's, and only a per-key record can show it.
    private(set) var keyWrites: [KeyWrite] = []

    /// The plane's own state — epoch, engaged and touched sets, force-key flag, and what the
    /// preparation step recorded — through the same type the production plane will hold.
    let ledger: PlaneWriteLedger

    /// What the firmware declares about `Ftst`: present, absent, or present behind a key-info
    /// read that fails. Fixed for the plane's life, like the firmware it models.
    let forceKeyDeclaration: ForceKeyPresence

    private let unlock: UnlockBehaviour

    /// Mode writes answered `0x82` per fan since the firmware's force key was set, toward
    /// `UnlockBehaviour.heldUntilForced`'s yield. Cleared when the key is.
    private var heldUnderForceKey: [Int: Int] = [:]

    /// How many times the preparation step ran.
    private(set) var preparations = 0

    /// Run once, synchronously, inside the next step that wrote its mode and is about to write
    /// the force key — the instant a production restore's epoch bump can arrive from another
    /// thread mid-turn (ADR 0014 D3 step 3's re-check). See `duringNextModeWrite(_:)`.
    private var duringModeWrite: (@Sendable () -> Void)?

    /// The machine-wide Apple Silicon force key, `Ftst`, as the **firmware** holds it: set, or
    /// clear.
    ///
    /// A5 added it as one flag; A4's unlock model moves it the ways the firmware would. An
    /// engagement's accepted `Ftst = 1` sets it, and any restore whose `Ftst = 0` the stage
    /// honours clears it — `.everyFan` always issues that write, `.fan(n)` when the plane's
    /// engaged set empties (D5). `setForceKey(_:)` sets it as a helper that died holding the key
    /// left it, or as another tool would, recording nothing. It is deliberately separate from
    /// `ledger.isForceKeySet`, the plane's *belief*: a refused clear leaves this set while the
    /// ledger records the clear as issued, which is the lingering key the preparation step finds.
    private(set) var isForceKeySet = false

    /// Raw `F<n>Md` values the unlock model's reads answer in place of the fold of a fan's mode:
    /// one `FirmwareFanMode` cannot hold, or a read-back that disagrees with a write that landed
    /// (#406). Set by `setRawMode(_:ofFan:)`.
    private var rawModes: [Int: UInt8] = [:]

    /// Fans whose next read-back, after a mode write, does not answer while every other read does.
    /// Set by `failNextReadBack(ofFan:)`.
    private var failingReadBacks: Set<Int> = []

    /// - Parameters:
    ///   - fans: The machine's fans and their state before anything is written. A fan
    ///     absent from this dictionary does not exist, and every operation naming it is
    ///     refused.
    ///   - stages: The scenario, consumed by `advance()`. The last stage repeats forever,
    ///     so a scenario needs exactly as many entries as it has distinct moments.
    ///   - forceKey: what the firmware declares about `Ftst`. `.unknown` models a key-info
    ///     read that fails while the key itself takes writes.
    ///   - unlock: how an honoured stage answers an engagement's mode writes.
    ///   - prepared: whether the plane starts as the preparation step leaves it on a healthy
    ///     machine — every scripted fan enumerated and the key's presence recorded — which is
    ///     what every scenario not about bring-up wants. `false` starts it unprepared: no fan
    ///     set and an unknown key, until `prepareWritePath(enumerating:)` runs.
    init(
        fans: [Int: FanCondition], stages: [Stage] = [.nominal()],
        forceKey: ForceKeyPresence = .present, unlock: UnlockBehaviour = .naive,
        prepared: Bool = true
    ) {
        precondition(!stages.isEmpty, "a ScriptedControlPlane needs at least one stage")
        self.fans = fans
        self.stages = stages
        forceKeyDeclaration = forceKey
        self.unlock = unlock
        ledger =
            prepared
            ? PlaneWriteLedger(enumerated: Set(fans.keys), forceKey: forceKey)
            : PlaneWriteLedger()
    }

    /// Moves to the next stage. The last one repeats.
    func advance() {
        stageIndex += 1
    }

    /// Moves a fan's mode without recording an attempt, as a writer outside Aeolus would.
    ///
    /// `engageManualControl(of:)` is the *helper's* write verb: it appends to `attempts` and
    /// goes through the stage's `WriteBehaviour`, which is exactly right when the test is
    /// about Aeolus writing. A test about a **third party** taking a fan needs the firmware
    /// to change underneath the helper with nothing in Aeolus having asked, and a recorded
    /// attempt would put the change on Aeolus's own ledger — which is the very
    /// misattribution ADR 0011 exists to prevent.
    func setMode(_ mode: FirmwareFanMode, ofFan index: Int) {
        fans[index]?.mode = mode
    }

    /// Sets or clears the force key without recording an attempt, for `setMode`'s reason: the
    /// state under test is one the firmware was left in, not one this process wrote.
    /// Runs `effect` inside the next step, between its mode write and its force-key write.
    func duringNextModeWrite(_ effect: @escaping @Sendable () -> Void) {
        duringModeWrite = effect
    }

    func setForceKey(_ isSet: Bool) {
        isForceKeySet = isSet
        if !isSet { heldUnderForceKey.removeAll() }
    }

    private var stage: Stage { stages[min(stageIndex, stages.count - 1)] }

    /// `.built`, always: this firmware really does take writes, and `WriteBehaviour` is how
    /// a scenario says one was refused.
    ///
    /// `nonisolated`, so the answer costs no actor hop and no read — see
    /// `FanWriteCapabilityReporting`, which is the whole reason a mechanism can ask it before
    /// touching hardware. It is deliberately **not** scriptable per stage: the capability is
    /// a property of the build behind the seam, not of the machine at a moment, and a mock
    /// that could toggle it would let a test drive a state no executable can be in.
    nonisolated var writeCapability: FanWriteCapability { .built }

    // MARK: - Reads

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        attempts.append(.readCriticalTemperatures(keys))
        try requireReadable(context: "critical temperatures")

        var readings: [CriticalTemperature] = []
        var unreadable: [SMCKey] = []
        for key in keys {
            guard let celsius = stage.temperatures[key.rawValue],
                case .success(let finite) = FanControlPlaneValue.finite(
                    celsius, describing: key.rawValue)
            else {
                unreadable.append(key)
                continue
            }
            readings.append(CriticalTemperature(key: key, celsius: finite))
        }

        return try CriticalTemperatureReport(readings: readings, unreadableKeys: unreadable)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        attempts.append(.readEnvelope(fan: index))
        let minimum = try FanControlPlaneValue.finite(
            try boundReadable(.minimum, ofFan: index),
            describing: SMCFanEnumeration.minimumKey(forFan: index)
        ).get()
        let maximum = try FanControlPlaneValue.finite(
            try boundReadable(.maximum, ofFan: index),
            describing: SMCFanEnumeration.maximumKey(forFan: index)
        ).get()

        return FanEnvelope(index: index, minimumRPM: minimum, maximumRPM: maximum)
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        attempts.append(.readControlState(fan: index))
        let fan = try modeReadable(ofFan: index, context: "fan \(index) control")

        return FanControlState(
            index: index,
            mode: fan.mode,
            target: Self.readback(fan.targetRPM, describing: "F\(index)Tg"),
            actualRPM: Self.readback(fan.actualRPM, describing: "F\(index)Ac"))
    }

    // MARK: - Recovery

    /// Answers according to this stage's `ReconnectBehaviour`, and **changes nothing else**.
    ///
    /// In particular it does not make reads start working: a scenario that wants a reconnect
    /// to have fixed the machine advances to a stage whose `reads` is `.answered`. Tying the
    /// two together here would agree with an implementation that treated a successful
    /// reconnect as a reason to skip the restore, which is exactly what § 5 says not to do.
    func reconnect() async throws {
        attempts.append(.reconnect)
        if case .refused(let reason) = stage.reconnects {
            throw FanControlPlaneError.readFailed(detail: "reconnect: \(reason)")
        }
    }

    // MARK: - Writes

    /// Restores without consulting `ReadBehaviour` at all.
    ///
    /// That omission is the whole point of the keystone: the restore verb has to be
    /// available in exactly the cycle where every read has failed. A mock that refused this
    /// while blind would make the blindness scenario untestable and would quietly agree
    /// with an implementation that read before restoring.
    ///
    /// The writes are the ledger's plan — every `F<n>Md = 0` in scope, then `Ftst = 0` when the
    /// plan clears it — each attempted whatever the others answered (ADR 0014 D5). A refused or
    /// discarded write leaves its key exactly as it found it, like every other field.
    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        attempts.append(.restoreToAutomatic(scope))
        if case .fan(let index) = scope { _ = try condition(ofFan: index) }
        // Requested, then issued: one actor turn here, two moments on a plane whose restore
        // waits for a scheduler turn between them — `PlaneWriteLedger` keeps them apart, and
        // decides the plan and the exit's seal by scope, so this plane and B1's cannot differ.
        ledger.restoreRequested(scope)
        try ledger.plan(for: scope).attemptEvery { write in try applyRestoreWrite(write) }
    }

    /// A target command, admitted first in its turn: once the exit's restore has been requested the
    /// ledger refuses it with `.superseded` before anything is written (ADR 0014's #410
    /// ticket-and-seal amendment). The attempt is still recorded, because it was made. The write
    /// and its in-turn read-back are `writeTarget(_:)`'s.
    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        let index = target.fanIndex
        attempts.append(.commandTarget(fan: index, rpm: target.rpm))
        try ledger.admitCommand()
        _ = try condition(ofFan: index)
        keyWrites.append(.target(fan: index, rpm: target.rpm))
        try writeTarget(target)
        // Returned once the in-turn read-back held it, even when the firmware discards it after
        // (`.reverted`). The number the watchdog compares a later read-back against is what was
        // commanded, not what the fan ended up holding — otherwise reversion would be invisible.
        return CommandedTarget(fanIndex: index, rpm: target.rpm)
    }

    // MARK: - Shared rules

    /// Applies a mutation according to this stage's `WriteBehaviour`.
    private func applyWrite(
        behaviour: WriteBehaviour? = nil, _ mutate: (inout [Int: FanCondition]) -> Void
    ) throws {
        switch behaviour ?? stage.writes {
        case .honoured:
            mutate(&fans)
        case .refused(let reason):
            throw FanControlPlaneError.firmwareRefusedControl(detail: reason)
        case .reverted:
            // Accepted and discarded: no throw, no change.
            break
        }
    }

    private func requireReadable(context: String) throws {
        guard case .failed(let reason) = stage.reads else { return }
        throw FanControlPlaneError.readFailed(detail: "\(context): \(reason)")
    }

    private func condition(ofFan index: Int) throws -> FanCondition {
        guard let fan = fans[index] else {
            throw FanControlPlaneError.fanNotAddressable(index: index)
        }
        return fan
    }
}

// MARK: - The firmware's own answer for F<n>Md (#360)

// An extension in this file for the unlock model's reason below: it reads the actor's private
// state directly, and the actor's own body stays the read and restore model it was.
extension ScriptedControlPlane {

    /// What `F<n>Md` reads for fan `index` this stage, **recording no attempt**: the snapshot's own
    /// read of the key, which `PlaneBackedProvider` serves from here.
    ///
    /// Not recorded because it is not a read this plane was asked for. The snapshot reads through
    /// its provider, never through the plane (`SnapshotFanModeReads`), and a test counting the
    /// plane's `attempts` is counting what the safety mechanisms asked the firmware.
    func firmwareMode(ofFan index: Int) throws -> FirmwareFanMode {
        try modeReadable(ofFan: index, context: "fan \(index) mode").mode
    }

    /// The one rule every read of `F<n>Md` answers by — `readControlState(ofFan:)`, the unlock
    /// model's raw read, and `firmwareMode(ofFan:)`: the SMC answers this stage, the fan exists,
    /// and its mode key is not one the stage leaves unanswered.
    fileprivate func modeReadable(ofFan index: Int, context: String) throws -> FanCondition {
        try requireReadable(context: context)
        let fan = try condition(ofFan: index)
        guard !stage.unreadableModes.contains(index) else {
            throw FanControlPlaneError.readFailed(detail: "\(context): F\(index)Md did not answer")
        }
        return fan
    }
}

// MARK: - The firmware's own answer for F<n>Mn and F<n>Mx (#270)

// An extension in this file for the mode extension's reason above.
extension ScriptedControlPlane {

    /// Which of a fan's two declared bounds a read asks for.
    enum Bound: Sendable, Hashable {
        case minimum
        case maximum
    }

    /// What one bound key reads on a stage, when it is not the fan's declaration — see
    /// `Stage.maximumReads` and `Stage.minimumReads`. Declared here rather than beside `Stage`, so
    /// the actor's own body stays inside `type_body_length`.
    enum BoundRead: Sendable, Hashable {
        /// The key answers this value — `1e14` is the shape of a byte-swapped `flt`.
        case reads(Double)
        /// The key does not answer.
        case fails
    }

    /// What `F<n>Mn` or `F<n>Mx` reads for fan `index` this stage, **recording no attempt**: the
    /// snapshot's own read of the key, which `PlaneBackedProvider` serves from here, for
    /// `firmwareMode(ofFan:)`'s reason.
    ///
    /// Raw, as the provider hands it on. Each side checks finiteness on its own path: the seam's
    /// in `readEnvelope(ofFan:)`, and the snapshot's in `SMCFanEnumeration`, which turns a
    /// non-finite read into `.notDecodable` and so a `.notMeasured` bound. Two checks, one
    /// outcome: § 2's gate answers `.boundsImplausible` on both sides.
    func firmwareBound(_ bound: Bound, ofFan index: Int) throws -> Double {
        try boundReadable(bound, ofFan: index)
    }

    /// The one rule every read of a bound key answers by — `readEnvelope(ofFan:)` and
    /// `firmwareBound(_:ofFan:)`: the SMC answers this stage, the fan exists, and the stage's
    /// `minimumReads` and `maximumReads` override the declared bounds.
    fileprivate func boundReadable(_ bound: Bound, ofFan index: Int) throws -> Double {
        try requireReadable(context: "fan \(index) envelope")
        let fan = try condition(ofFan: index)
        let isMinimum = bound == .minimum
        guard let read = (isMinimum ? stage.minimumReads : stage.maximumReads)[index] else {
            return isMinimum ? fan.minimumRPM : fan.maximumRPM
        }
        switch read {
        case .reads(let value):
            return value
        case .fails:
            let key =
                isMinimum
                ? SMCFanEnumeration.minimumKey(forFan: index)
                : SMCFanEnumeration.maximumKey(forFan: index)
            throw FanControlPlaneError.readFailed(
                detail: "fan \(index) envelope: \(key) did not answer")
        }
    }
}

// MARK: - The unlock model and the preparation step (ADR 0014)

// An extension in this file, so it reads the actor's private state directly and the actor's
// own body stays the read and restore model it was.
extension ScriptedControlPlane {

    /// The write path's preparation step (D5), against this firmware: enumerate through `fans`,
    /// record the key's presence, read it if present, and issue `.everyFan` once when
    /// `WritePathPreparation.needsMachineWideRestore` says so.
    func prepareWritePath(enumerating fans: any FanEnumerating) async -> WritePathPreparation? {
        preparations += 1
        let enumerated: Set<Int>?
        do {
            enumerated = try await fans.enumeratedFanIndices()
        } catch {
            enumerated = nil
        }

        let forceKey: WritePathPreparation.ForceKey
        switch forceKeyDeclaration {
        case .absent:
            forceKey = .absent
        case .unknown:
            forceKey = .unknown(detail: "the scripted firmware's key info for Ftst did not answer")
        case .present:
            if case .failed(let reason) = stage.reads {
                forceKey = .unreadable(detail: reason)
            } else {
                forceKey = .reads(isForceKeySet ? 1 : 0)
            }
        }
        ledger.recordPreparation(enumerated: enumerated, forceKey: forceKey.presence)

        guard WritePathPreparation.needsMachineWideRestore(forceKey) else {
            return WritePathPreparation(
                enumeratedFans: enumerated, forceKey: forceKey, machineWideRestore: nil)
        }
        let restore: WritePathPreparation.MachineWideRestore
        do {
            try await restoreToAutomatic(.everyFan)
            restore = .landed
        } catch {
            restore = .refused(detail: String(describing: error))
        }
        return WritePathPreparation(
            enumeratedFans: enumerated, forceKey: forceKey, machineWideRestore: restore)
    }

    /// The engagement's ticket, taken on `ledger` as B1's plane takes it (ADR 0014's #410
    /// ticket-and-seal amendment): `nonisolated`, because the verb is synchronous and the ledger is
    /// a lock rather than this actor's state. Records no attempt, because it reaches no firmware.
    nonisolated func beginEngagement(fanAt index: Int) {
        ledger.beginEngagement(fanAt: index)
    }

    /// A first step as the driver takes one, for a test that steps this plane directly: the
    /// ticket, then the step. A first step with no ticket is refused `.superseded`.
    func ticketedStep(of fan: CommandableFan) async throws -> EngagementStep {
        beginEngagement(fanAt: fan.index)
        return try await engageManualControl(of: fan)
    }

    /// One step of the unlock model: D3, decided by `EngagementRules` and recorded in `ledger`.
    func engageManualControl(of fan: CommandableFan) async throws -> EngagementStep {
        attempts.append(.engageManualControl(fan: fan.index))
        _ = try condition(ofFan: fan.index)
        do {
            let step = try unlockStep(fanAt: fan.index)
            if step == .engaged { ledger.recordEngaged(fanAt: fan.index) }
            return step
        } catch {
            ledger.recordStepRefused(fanAt: fan.index)
            throw error
        }
    }

    /// Whether a write of `behaviour` lands: it throws when refused, and is `false` when the
    /// firmware accepted and discarded it.
    private func lands(_ behaviour: WriteBehaviour) throws -> Bool {
        switch behaviour {
        case .honoured: return true
        case .refused(let reason): throw FanControlPlaneError.firmwareRefusedControl(detail: reason)
        case .reverted: return false
        }
    }

    /// D3 for one step, in one actor turn: admit under the epoch, read the pre-state on the
    /// first step, write the mode, then read back, set the key, or wait. A first step whose
    /// pre-state read fails says it failed before its first write, as B1's plane must (ADR 0014's
    /// #410 refused-hand-back amendment); the read-back's failure, after the write, is thrown as
    /// it is.
    private func unlockStep(fanAt index: Int) throws -> EngagementStep {
        let first = try ledger.admitStep(fanAt: index) == .first
        if first {
            let raw: UInt8
            do {
                raw = try readRawMode(ofFan: index)
            } catch {
                throw FanControlPlaneError.failedBeforeFirstWrite(
                    index: index, detail: String(describing: error))
            }
            try EngagementRules.requireAutomatic(rawMode: raw, fanAt: index)
        }
        let next = try EngagementRules.afterModeWrite(
            try answerModeWrite(fanAt: index), firstStep: first,
            forceKey: ledger.forceKey, forceKeySet: ledger.isForceKeySet)
        switch next {
        case .readBack:
            if failingReadBacks.remove(index) != nil {
                throw FanControlPlaneError.readFailed(
                    detail: "fan \(index) mode: the read-back did not answer")
            }
            var raw = try readRawMode(ofFan: index)
            if case .readsBack(let scripted) = unlock { raw = scripted }
            return try EngagementRules.afterReadBack(rawMode: raw, fanAt: index)
        case .setForceKey:
            duringModeWrite?()
            duringModeWrite = nil
            guard ledger.isCurrent(fanAt: index) else {
                throw FanControlPlaneError.supersededAfterWrite
            }
            let step = try EngagementRules.afterForceKeyWrite(answerForceKeyWrite())
            ledger.recordForceKeyAccepted()
            return step
        case .awaitYield:
            return .awaitingYield
        }
    }

    /// Makes the unlock model's raw reads of fan `index`'s `F<n>Md` — a first step's pre-state and
    /// a step's read-back — answer `raw`, or the fold of its mode again for `nil`, recording no
    /// attempt, for `setMode`'s reason. The snapshot's read, `firmwareMode(ofFan:)`, still folds.
    /// In this extension, so the actor's own body stays inside `type_body_length`'s warning.
    func setRawMode(_ raw: UInt8?, ofFan index: Int) {
        rawModes[index] = raw
    }

    /// Makes fan `index`'s next read-back, the read after a mode write, fail with `.readFailed`
    /// while the write itself lands and every other read answers: a write whose confirmation was
    /// lost (#406). One read-back only, recording no attempt. In this extension, for
    /// `setRawMode(_:ofFan:)`'s reason.
    func failNextReadBack(ofFan index: Int) {
        failingReadBacks.insert(index)
    }

    /// Raw `F<n>Md`, through the stage's read behaviour: `0` on automatic, `1` on manual, unless
    /// `setRawMode(_:ofFan:)` set another.
    private func readRawMode(ofFan index: Int) throws -> UInt8 {
        let fan = try modeReadable(ofFan: index, context: "fan \(index) mode")
        return rawModes[index] ?? (fan.mode == .automatic ? 0 : 1)
    }

    /// `F<n>Md = 1`, answered as this stage and `UnlockBehaviour` say. A refused stage refuses
    /// it outright; a discarding stage accepts it and leaves the fan as it was.
    private func answerModeWrite(fanAt index: Int) throws -> FirmwareWriteAnswer {
        keyWrites.append(.mode(fan: index, value: 1))
        ledger.recordModeWriteIssued(fanAt: index)
        guard try lands(stage.writes) else { return .accepted }
        switch unlock {
        case .naive:
            fans[index]?.mode = .manual
            return .accepted
        case .heldUntilForced(let stepsToYield):
            guard isForceKeySet else { return .heldBySystem }
            let held = heldUnderForceKey[index, default: 0]
            guard held >= stepsToYield else {
                heldUnderForceKey[index] = held + 1
                return .heldBySystem
            }
            fans[index]?.mode = .manual
            return .accepted
        case .neverYields:
            return .heldBySystem
        case .answers(let code):
            return .refused(code: code)
        case .readsBack(let raw):
            if raw == 1 { fans[index]?.mode = .manual }
            return .accepted
        }
    }

    /// `Ftst = 1`, answered as this stage's force-key behaviour says.
    private func answerForceKeyWrite() -> FirmwareWriteAnswer {
        keyWrites.append(.forceKey(1))
        switch stage.forceKeyWrites ?? stage.writes {
        case .honoured:
            isForceKeySet = true
            return .accepted
        case .refused:
            return .refused(code: 0x85)
        case .reverted:
            return .accepted
        }
    }

    /// One write of a restore's plan. Never consults `ReadBehaviour`: the keystone issues no
    /// read and must work on a machine that cannot be read.
    fileprivate func applyRestoreWrite(_ write: RestorePlan.Write) throws {
        switch write {
        case .mode(let index):
            keyWrites.append(.mode(fan: index, value: 0))
            _ = try condition(ofFan: index)
            if try lands(stage.writes) { fans[index]?.mode = .automatic }
        case .forceKey:
            keyWrites.append(.forceKey(0))
            if try lands(stage.forceKeyWrites ?? stage.writes) { setForceKey(false) }
        }
    }
}

// MARK: - What the firmware holds at a command's read-back (B1)

// In this file for the unlock model's reason; the rest of B1's scripting is in
// `ScriptedControlPlane+Scripting.swift`, which reads no private state.
extension ScriptedControlPlane {

    /// `F<n>Tg = rpm`, and the command's in-turn read-back, as this stage says (#9). A refusal
    /// throws first. Otherwise `.honoured` holds the target; `.reverted` holds it at the read-back
    /// and discards it after, so the command returns and only a later read sees the old target;
    /// and a fan in `Stage.targetsNotHeldAtReadBack` holds nothing even then: the register keeps
    /// what it had, and the command throws `.targetNotConfirmed` with that as its read-back,
    /// however near the commanded value it is. The tolerance is B1's command turn's (U4).
    fileprivate func writeTarget(_ target: AuthorisedFanTarget) throws {
        let index = target.fanIndex
        let behaviour = stage.targetWrites ?? stage.writes
        guard stage.targetsNotHeldAtReadBack.contains(index) else {
            return try applyWrite(behaviour: behaviour) { $0[index]?.targetRPM = target.rpm }
        }
        _ = try lands(behaviour)
        throw FanControlPlaneError.targetNotConfirmed(
            index: index, commandedRPM: target.rpm,
            readBackRPM: try condition(ofFan: index).targetRPM)
    }
}

/// The write permit for one of a scripted machine's own fans.
///
/// **Derived from the mock's `FanCondition`, never from figures restated in a test.** An
/// earlier draft declared `FanControlEnvelope.nominal = validated(1_350, 5_777)` beside
/// `FanCondition.nominal`'s own `1_350`/`5_777`, which put the development machine's
/// envelope in two hand-maintained places with nothing enforcing that they agree — the
/// precise hazard `FanSafetyLimits` documents itself as avoiding. Changing the mock fan's
/// declared minimum now changes the permit clamped against it, because there is one number.
///
/// It also lives in a free function rather than in an `extension FanControlEnvelope`. A
/// test-target extension on a `FanKit` type silently shadows a same-named member added
/// later on the `FanKit` side — no ambiguity error and no warning — so every helper test
/// would go on using the stale figures while the library's own moved.
///
/// Building a `FanEnvelope` by hand is the honest shape and is the *only* route: both permit
/// types have `fileprivate` initialisers, and `@testable` does not widen `fileprivate`. A
/// test that wants to command a fan has to fake a firmware reading, and it looks like it.
///
/// - Throws: `FanBoundsImplausibility` when the condition's declared bounds fail #37's gate
///   — which is exactly what a test asserting "this fan cannot be commanded" wants to catch.
func commandableFan(
    _ index: Int, declaring condition: ScriptedControlPlane.FanCondition
) throws -> CommandableFan {
    try FanEnvelope(
        index: index,
        minimumRPM: condition.minimumRPM,
        maximumRPM: condition.maximumRPM
    ).commandable.get()
}

/// A four-character SMC key written out in a test, where a typo can only be a typo.
///
/// Traps rather than returning an optional, for the same reason `SMCKey.known(_:)` does:
/// the failure it can have is an authoring mistake in this repository, caught by the suite
/// rather than by a user, and threading an optional through every fixture would obscure
/// what each test is actually asserting.
func smcKey(_ raw: String) -> SMCKey {
    guard let key = SMCKey(raw) else {
        preconditionFailure("'\(raw)' is not a valid four-character SMC key")
    }
    return key
}
