import SMCCore

@testable import AeolusHelper

// The parts of `ScriptedControlPlane`'s scripting that read none of the actor's private state, in
// a file of their own so `ScriptedControlPlane.swift` stays inside `file_length`'s error. The
// vocabulary is P0's of B1 (#9): the built stages that script it.

extension ScriptedControlPlane {

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
}

/// Built stages for the B1 vocabulary, so a scenario reads as the firmware it scripts.
extension ScriptedControlPlane.Stage {

    /// This stage, with fan `index`'s accepted targets not held at the command's read-back.
    func holdingNoTarget(ofFan index: Int) -> Self {
        var stage = self
        stage.targetsNotHeldAtReadBack.insert(index)
        return stage
    }
}
