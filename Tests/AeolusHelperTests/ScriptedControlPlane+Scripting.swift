import SMCCore

@testable import AeolusHelper

// The parts of `ScriptedControlPlane`'s scripting that read none of the actor's private state, in
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
