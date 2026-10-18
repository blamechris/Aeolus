import Testing

@testable import AeolusHelper

/// `LeaseApplierAnswerTests`' case about the fixed details themselves, in a file of its own so the
/// suite's body stays under `type_body_length`. The other tests compare answers against the
/// constants, so a change to a constant's text would pass them all.
extension LeaseApplierAnswerTests {

    /// **Every fixed detail, by its literal text.** Each crosses the boundary as a client's answer
    /// and quotes nothing a client sent.
    ///
    /// **Mutation:** change any `LeaseApplyRules.Detail` text. Run: red on that line.
    @Test("Every fixed detail level 6 answers with is pinned by its text")
    func everyFixedDetailIsPinnedByItsText() {
        typealias Detail = LeaseApplyRules.Detail
        #expect(Detail.noSettings == "no fan settings were given")
        #expect(
            Detail.automatic == "an automatic setting is not applied: release the lease instead")
        #expect(Detail.curve == "a curve setting is not honoured until the curve evaluator exists")
        #expect(Detail.uncovered == "a setting names a fan the lease does not cover")
        #expect(Detail.duplicate == "a setting names the same fan twice")
        #expect(
            Detail.yieldDidNotArrive
                == "the firmware did not yield the fan to manual control in time")
        #expect(Detail.firmwareRefused == "the firmware refused a write to the fan")
        #expect(Detail.notConfirmed == "the firmware did not confirm manual control of the fan")
        #expect(Detail.unexpected == "the fan's write did not complete")
        #expect(Detail.applyInProgress == "another apply under this lease has not finished")
    }
}
