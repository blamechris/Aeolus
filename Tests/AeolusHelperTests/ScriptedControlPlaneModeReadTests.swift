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
    /// exist, the shape #360's fixture correction removed. **And it says where it failed** (ADR
    /// 0014's #410 refused-hand-back amendment): the pre-state read's failure, before any write, is
    /// `.failedBeforeFirstWrite` with no key write; a read-back's failure, after the mode write was
    /// issued, is `.readFailed`, with `F0Md = 1` among the key writes.
    ///
    /// **Mutation:** in `ScriptedControlPlane.readRawMode(ofFan:)`, read
    /// `try condition(ofFan: index).mode` after the stage's `reads` check instead of
    /// `modeReadable(ofFan:context:)`. Run: red — the engagement's first step succeeds.
    /// **Mutation:** in `unlockStep`, rethrow the pre-state read's error as it is. Run: red on the
    /// pre-state's case. **Mutation:** throw `.failedBeforeFirstWrite` for the read-back's failure
    /// too. Run: red on the read-back's case.
    @Test("The scripted plane says whether its first step failed before or after its first write")
    func theScriptedPlaneSaysWhereItsFirstStepFailed() async throws {
        let answered = ScriptedControlPlane(fans: [0: .automatic(at: 2_400)])
        let refused = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)], stages: [Self.unanswered])
        let lostReadBack = ScriptedControlPlane(fans: [0: .automatic(at: 2_400)])
        await lostReadBack.failNextReadBack(ofFan: 0)
        let permit = try commandableFan(0, declaring: .nominal)

        #expect(
            try await answered.ticketedStep(of: permit) == .engaged,
            "an engagement on a stage that answers did not engage, so the refusal says nothing")
        let preState = await LeaseApplierAnswerTests.answer {
            _ = try await refused.ticketedStep(of: permit)
        }
        if case .failedBeforeFirstWrite(0, let detail)? = preState as? FanControlPlaneError {
            #expect(detail.contains("F0Md did not answer"), "\(detail)")
        } else {
            Issue.record("an unreadable pre-state was answered \(preState as Any)")
        }
        #expect(await refused.keyWrites.isEmpty, "the pre-state's failure followed a write")

        let readBack = await LeaseApplierAnswerTests.answer {
            _ = try await lostReadBack.ticketedStep(of: permit)
        }
        if case .readFailed(let detail)? = readBack as? FanControlPlaneError {
            #expect(detail.contains("the read-back did not answer"), "\(detail)")
        } else {
            Issue.record("a read-back lost after the mode write was answered \(readBack as Any)")
        }
        #expect(await lostReadBack.keyWrites == [.mode(fan: 0, value: 1)])
    }
}
