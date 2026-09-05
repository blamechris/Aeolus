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

        init(
            temperatures: [String: Double] = [:],
            reads: ReadBehaviour = .answered,
            writes: WriteBehaviour = .honoured,
            reconnects: ReconnectBehaviour = .refused(
                reason: "this build has no reconnect; see SMCFanControlPlane.reconnect()"),
            targetWrites: WriteBehaviour? = nil
        ) {
            self.temperatures = temperatures
            self.reads = reads
            self.writes = writes
            self.reconnects = reconnects
            self.targetWrites = targetWrites
        }

        /// A stage where the SMC answers and the machine reads as given.
        ///
        /// `writes` is a parameter rather than always `.honoured` because § 5's scenarios
        /// are about a machine that reads perfectly and does not keep what it is told —
        /// which is `.reverted`, on an otherwise nominal stage.
        static func nominal(
            temperatures: [String: Double] = [:],
            writes: WriteBehaviour = .honoured,
            targetWrites: WriteBehaviour? = nil
        ) -> Stage {
            Stage(temperatures: temperatures, writes: writes, targetWrites: targetWrites)
        }

        /// A stage where the SMC answers nothing. One of these is a transient failure; a
        /// run of them to the end of the script is a persistent one, because the last stage
        /// repeats forever.
        ///
        /// `reconnects` defaults to the shipping helper's behaviour — refused — so a blind
        /// scenario that says nothing about reconnecting gets the branch the build really
        /// has. A scenario that wants the reconnect to return cleanly while reads keep
        /// failing asks for it, because that disagreement is the interesting case: § 5
        /// restores either way.
        static func blind(
            reason: String = "the SMC did not answer",
            reconnects: ReconnectBehaviour = .refused(
                reason: "this build has no reconnect; see SMCFanControlPlane.reconnect()")
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
    /// The default is `.refused`, matching `SMCFanControlPlane.reconnect()`, so a scenario
    /// that says nothing about reconnecting gets the behaviour the shipping helper actually
    /// has rather than an optimistic one no build provides.
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
        case reverted
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

    /// - Parameters:
    ///   - fans: The machine's fans and their state before anything is written. A fan
    ///     absent from this dictionary does not exist, and every operation naming it is
    ///     refused.
    ///   - stages: The scenario, consumed by `advance()`. The last stage repeats forever,
    ///     so a scenario needs exactly as many entries as it has distinct moments.
    init(fans: [Int: FanCondition], stages: [Stage] = [.nominal()]) {
        precondition(!stages.isEmpty, "a ScriptedControlPlane needs at least one stage")
        self.fans = fans
        self.stages = stages
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
        try requireReadable(context: "fan \(index) envelope")
        let fan = try condition(ofFan: index)

        let minimum = try FanControlPlaneValue.finite(
            fan.minimumRPM, describing: SMCFanEnumeration.minimumKey(forFan: index)
        ).get()
        let maximum = try FanControlPlaneValue.finite(
            fan.maximumRPM, describing: SMCFanEnumeration.maximumKey(forFan: index)
        ).get()

        return FanEnvelope(index: index, minimumRPM: minimum, maximumRPM: maximum)
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        attempts.append(.readControlState(fan: index))
        try requireReadable(context: "fan \(index) control")
        let fan = try condition(ofFan: index)

        return FanControlState(
            index: index,
            mode: fan.mode,
            target: Self.readback(fan.targetRPM, describing: "F\(index)Tg"),
            actualRPM: Self.readback(fan.actualRPM, describing: "F\(index)Ac"))
    }

    /// One RPM value as a readback, with the seam's finiteness rule applied.
    ///
    /// The same rule `SMCFanControlPlane` applies, restated here rather than shared because
    /// `FanControlPlaneValue.finite(_:describing:)` is the shared part — a double that
    /// answered a NaN where the real thing reports a fault would hide the bug it was written
    /// to catch, which is this mock's own stated contract.
    private static func readback(_ value: Double, describing what: String) -> FanRPMReadback {
        switch FanControlPlaneValue.finite(value, describing: what) {
        case .success(let rpm): return .rpm(rpm)
        case .failure(let error): return .unreadable(reason: String(describing: error))
        }
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
    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        attempts.append(.restoreToAutomatic(scope))
        let indices: [Int]
        switch scope {
        case .fan(let index):
            _ = try condition(ofFan: index)
            indices = [index]
        case .everyFan:
            indices = Array(fans.keys)
        }
        try applyWrite { fans in
            for index in indices {
                fans[index]?.mode = .automatic
            }
        }
    }

    func engageManualControl(of fan: CommandableFan) async throws {
        attempts.append(.engageManualControl(fan: fan.index))
        _ = try condition(ofFan: fan.index)
        try applyWrite { fans in
            fans[fan.index]?.mode = .manual
        }
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        let index = target.fanIndex
        attempts.append(.commandTarget(fan: index, rpm: target.rpm))
        _ = try condition(ofFan: index)
        try applyWrite(behaviour: stage.targetWrites ?? stage.writes) { fans in
            fans[index]?.targetRPM = target.rpm
        }
        // Returned even when the firmware discarded it. The command was issued, and the
        // number the watchdog compares a later read-back against is what was commanded,
        // not what the fan ended up holding — otherwise reversion would be invisible.
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
