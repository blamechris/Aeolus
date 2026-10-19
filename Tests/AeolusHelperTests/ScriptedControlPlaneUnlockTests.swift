import Testing

@testable import AeolusHelper

/// The scripted unlock model's own preconditions, held where a scenario is built.
@Suite("ScriptedControlPlane's unlock answers")
struct ScriptedControlPlaneUnlockTests {

    /// `UnlockBehaviour.answers(code:)` is for a code that is neither `0x00` nor `0x82`: B1's
    /// plane reads `0x82` as held and `0x00` as accepted, so a contract scenario naming either
    /// would behave differently on the two planes. Building the firmware with one records an
    /// issue; any other code builds quietly.
    ///
    /// **Mutation:** in `ScriptedFirmware.requireAnUnlockAnswerOfItsOwn(_:)`, delete the
    /// `Issue.record`. Run: red — the known issue is not recorded, for both arguments.
    @Test(
        "An unlock answer of 0x00 or 0x82 is refused as a scenario", arguments: [UInt8(0x00), 0x82])
    func anUnlockAnswerWithACaseOfItsOwnIsRefused(_ code: UInt8) {
        withKnownIssue("a scenario naming a code with a case of its own") {
            _ = ScriptedControlPlane(fans: [0: .nominal], unlock: .answers(code: code))
        }
    }

    /// The positive control: a code with no case of its own records nothing.
    @Test(
        "An unlock answer of any other code builds quietly", arguments: [UInt8(0x01), 0x89, 0x85])
    func anUnlockAnswerOfAnyOtherCodeBuilds(_ code: UInt8) {
        _ = ScriptedControlPlane(fans: [0: .nominal], unlock: .answers(code: code))
    }
}
