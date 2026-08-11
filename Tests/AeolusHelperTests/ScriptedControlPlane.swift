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

        init(
            temperatures: [String: Double] = [:],
            reads: ReadBehaviour = .answered,
            writes: WriteBehaviour = .honoured
        ) {
            self.temperatures = temperatures
            self.reads = reads
            self.writes = writes
        }

        /// A stage where everything works and the machine reads as given.
        static func nominal(temperatures: [String: Double] = [:]) -> Stage {
            Stage(temperatures: temperatures)
        }

        /// A stage where the SMC answers nothing. One of these is a transient failure; a
        /// run of them to the end of the script is a persistent one, because the last stage
        /// repeats forever.
        static func blind(reason: String = "the SMC did not answer") -> Stage {
            Stage(reads: .failed(reason: reason))
        }
    }

    /// Whether the SMC answers reads this stage.
    enum ReadBehaviour: Sendable, Hashable {
        case answered
        case failed(reason: String)
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

        init(
            mode: FirmwareFanMode = .automatic,
            targetRPM: Double = 1_800,
            minimumRPM: Double = 1_350,
            maximumRPM: Double = 5_777
        ) {
            self.mode = mode
            self.targetRPM = targetRPM
            self.minimumRPM = minimumRPM
            self.maximumRPM = maximumRPM
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

    private var stage: Stage { stages[min(stageIndex, stages.count - 1)] }

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

        let target: FanTargetReadback
        switch FanControlPlaneValue.finite(fan.targetRPM, describing: "F\(index)Tg") {
        case .success(let rpm): target = .rpm(rpm)
        case .failure(let error): target = .unreadable(reason: String(describing: error))
        }

        return FanControlState(index: index, mode: fan.mode, target: target)
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

    func engageManualControl(ofFan index: Int) async throws {
        attempts.append(.engageManualControl(fan: index))
        _ = try condition(ofFan: index)
        try applyWrite { fans in
            fans[index]?.mode = .manual
        }
    }

    @discardableResult
    func commandTarget(_ target: FanTargetRPM, ofFan index: Int) async throws -> CommandedTarget {
        attempts.append(.commandTarget(fan: index, rpm: target.rpm))
        _ = try condition(ofFan: index)
        try applyWrite { fans in
            fans[index]?.targetRPM = target.rpm
        }
        // Returned even when the firmware discarded it. The command was issued, and the
        // number the watchdog compares a later read-back against is what was commanded,
        // not what the fan ended up holding — otherwise reversion would be invisible.
        return CommandedTarget(fanIndex: index, rpm: target.rpm)
    }

    // MARK: - Shared rules

    /// Applies a mutation according to this stage's `WriteBehaviour`.
    private func applyWrite(_ mutate: (inout [Int: FanCondition]) -> Void) throws {
        switch stage.writes {
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

/// The envelopes a test commands targets against.
///
/// There is deliberately **no helper here that turns a `Double` into a `FanTargetRPM`
/// directly.** That helper is the obvious convenience to reach for, and writing it would
/// undo the entire point of #108: `FanTargetRPM`'s guarantee is that the only way to obtain
/// one is `FanControlEnvelope.target(for:)`, and a test-target back door would hand every
/// future suite an unclamped write path while the production signature looked safe. Tests
/// clamp through a real envelope for the same reason production does.
extension FanControlEnvelope {

    /// `Mac16,5`'s measured envelope, 1350–5777 — the same figures
    /// `ScriptedControlPlane.FanCondition.nominal` declares, so a target clamped through
    /// this one is a target the mock's default fan could really hold.
    ///
    /// Traps rather than returning an optional, like `smcKey(_:)` below: the only way it can
    /// fail is an authoring mistake in this file, and threading an optional through every
    /// fixture would obscure what each test asserts.
    static let nominal: FanControlEnvelope = validated(minimum: 1_350, maximum: 5_777)

    /// A fan whose firmware declares a minimum of zero. `lowestCommandableRPM` is then
    /// `FanSafetyLimits.minimumManualRPM`, not zero, which is the case `CLAUDE.md` rule 3
    /// exists for.
    static let zeroMinimum: FanControlEnvelope = validated(minimum: 0, maximum: 5_777)

    private static func validated(minimum: Double, maximum: Double) -> FanControlEnvelope {
        let judged = FanControlEnvelope.validating(
            declaredMinimumRPM: minimum, declaredMaximumRPM: maximum)
        switch judged {
        case .success(let envelope):
            return envelope
        case .failure(let reason):
            preconditionFailure("\(minimum)–\(maximum) is not a usable test envelope: \(reason)")
        }
    }
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
