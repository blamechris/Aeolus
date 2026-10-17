import FanKit
import SMCCore
import Testing

@testable import AeolusHelper

/// `ScriptedControlPlane.Stage.unreadableModes` and `firmwareMode(ofFan:)` hold to the two
/// properties the composed suites rest on (#360): the snapshot's read of `F<n>Md` records nothing
/// on the plane, and every read of the key the plane serves fails on such a stage.
///
/// In a file of its own because `ScriptedControlPlaneTests` is at the 400-line limit.
@Suite("The scripted firmware's own answer for F<n>Md")
struct ScriptedControlPlaneModeReadTests {

    private static let unanswered = ScriptedControlPlane.Stage(unreadableModes: [0])

    /// The snapshot's read is not a read the safety mechanisms asked for, so a suite counting
    /// the plane's `attempts` — the hand-back and revocation counts the composed suites check —
    /// is not moved by how often a snapshot was taken.
    ///
    /// **Mutation:** add `attempts.append(.readControlState(fan: index))` to
    /// `ScriptedControlPlane.firmwareMode(ofFan:)`. Run: red.
    @Test("The snapshot's read of F<n>Md records no attempt on the plane")
    func theSnapshotsModeReadRecordsNothing() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 2_400)])

        let mode = try await plane.firmwareMode(ofFan: 0)

        let attempts = await plane.attempts
        #expect(mode == .manual)
        #expect(attempts.isEmpty, "recorded \(attempts)")
    }

    /// An engagement's first step reads the fan's raw `F<n>Md` before it writes, and on a stage
    /// that leaves the key unanswered that read fails as every other read of it does: a mock
    /// whose engagement could read a mode its snapshot could not would be a machine that cannot
    /// exist, the shape #360's fixture correction removed.
    ///
    /// **Mutation:** in `ScriptedControlPlane.readRawMode(ofFan:)`, read
    /// `try condition(ofFan: index).mode` after the stage's `reads` check instead of
    /// `modeReadable(ofFan:context:)`. Run: red — the engagement's first step succeeds.
    @Test("An engagement's raw read of F<n>Md fails on a stage that leaves the key unanswered")
    func theUnlockModelsRawReadHonoursTheStage() async throws {
        let answered = ScriptedControlPlane(fans: [0: .automatic(at: 2_400)])
        let refused = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)], stages: [Self.unanswered])
        let permit = try commandableFan(0, declaring: .nominal)

        #expect(
            try await answered.ticketedStep(of: permit) == .engaged,
            "an engagement on a stage that answers did not engage, so the refusal says nothing")
        do {
            let step = try await refused.ticketedStep(of: permit)
            Issue.record("the engagement read a mode the stage leaves unanswered: \(step)")
        } catch FanControlPlaneError.readFailed(let detail) {
            #expect(detail.contains("F0Md did not answer"), "\(detail)")
        }
    }
}
