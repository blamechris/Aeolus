import SMCCore

@testable import AeolusHelper

// The parts of `ScriptedFirmware`'s scripting that read none of the actor's private state, in
// a file of their own so `ScriptedControlPlane.swift` stays inside `file_length`'s error. The
// vocabulary is P0's of B1 (#9): what the scripted firmware declares for the restore keys, the
// writes it can leave unanswered, and the built stages that script them.

extension ScriptedFirmware {

    /// An engagement write the firmware does not answer: the call fails in the kernel, or its
    /// reply is cut short (`FirmwareWriteAnswer.unanswered`). Whether the register changed anyway
    /// is what no answer the plane receives can say — issued, not landed (ADR 0014's #410
    /// refused-hand-back amendment) — so the scenario says it.
    enum UnansweredWrite: Sendable, Hashable {
        /// The register changed: only the answer was lost.
        case landed
        /// The register did not change either.
        case lost
    }

    /// One RPM value as a readback, with the seam's finiteness rule applied.
    ///
    /// The same rule `SMCFanControlPlane` applies, restated here rather than shared because
    /// `FanControlPlaneValue.finite(_:describing:)` is the shared part — a double that
    /// answered a NaN where the real thing reports a fault would hide the bug it was written
    /// to catch, which is this mock's own stated contract.
    static func readback(_ value: Double, describing what: String) -> FanRPMReadback {
        switch FanControlPlaneValue.finite(value, describing: what) {
        case .success(let rpm): return .rpm(rpm)
        case .failure(let error): return .unreadable(reason: String(describing: error))
        }
    }

    /// What this firmware's key-info reads answer for the restore keys, as the preparation step
    /// records them (D5 step 2): one byte for every enumerated fan's `F<n>Md`, and for `Ftst` when
    /// it is present — `ui8`, as `Mac16,5` declares both. An unknown key, an absent one and a fan
    /// the enumeration did not find have no size, so a restore writes them one zero byte.
    static func declaredSizes(enumerated: Set<Int>?, forceKey: ForceKeyPresence) -> [SMCKey: Int] {
        var sizes: [SMCKey: Int] = [:]
        for key in (enumerated ?? []).compactMap(SMCKey.fanMode) { sizes[key] = 1 }
        if forceKey == .present { sizes[SMCKey.forceTest] = 1 }
        return sizes
    }

    /// The ledger `init(…, prepared: true)` starts with: what this plane's own preparation step
    /// records on a healthy machine, every scripted fan enumerated.
    static func preparedLedger(
        enumerating fans: Set<Int>, forceKey: ForceKeyPresence
    ) -> PlaneWriteLedger {
        PlaneWriteLedger(
            enumerated: fans, forceKey: forceKey,
            declaredSizes: declaredSizes(enumerated: fans, forceKey: forceKey))
    }
}

// The scripting vocabulary a stage and a scenario are written in, moved out of the actor body
// with every case and doc comment unchanged, so `ScriptedControlPlane.swift` stays inside
// `file_length`'s error and the actor inside `type_body_length`'s.
extension ScriptedFirmware {

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
}

/// Built stages for the B1 vocabulary, so a scenario reads as the firmware it scripts.
extension ScriptedControlPlane.Stage {

    /// This stage, with fan `index`'s accepted targets not held at the command's read-back.
    func holdingNoTarget(ofFan index: Int) -> Self {
        var stage = self
        stage.targetsNotHeldAtReadBack.insert(index)
        return stage
    }

    /// This stage, with fan `index`'s engagement mode writes unanswered, landing as `write` says.
    func leavingModeWriteUnanswered(
        ofFan index: Int, _ write: ScriptedControlPlane.UnansweredWrite
    ) -> Self {
        var stage = self
        stage.unansweredModeWrites[index] = write
        return stage
    }

    /// This stage, with an engagement's `Ftst = 1` unanswered, landing as `write` says.
    func leavingForceKeyWriteUnanswered(_ write: ScriptedControlPlane.UnansweredWrite) -> Self {
        var stage = self
        stage.unansweredForceKeyWrite = write
        return stage
    }
}
