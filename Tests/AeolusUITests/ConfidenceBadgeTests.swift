import FanKit
import Testing

@testable import AeolusUI

@Suite("ConfidenceBadge — a guess is labelled and tinted distinctly from a verified match")
struct ConfidenceBadgeTests {

    @Test(
        "Every confidence level has a distinct, non-empty label",
        arguments: [
            CatalogConfidence.verified, .community, .guess, .unknown("future-level"),
        ]
    )
    func everyConfidenceLevelHasALabel(_ confidence: CatalogConfidence) {
        #expect(!ConfidenceBadge.label(for: confidence).isEmpty)
    }

    @Test("A guess is labelled explicitly as a guess, never worded to sound like a fact")
    func guessIsLabelledAsAGuess() {
        #expect(ConfidenceBadge.label(for: .guess) == "Guess")
    }

    @Test("Verified and guess never share the same label or the same tint")
    func verifiedAndGuessAreVisuallyDistinct() {
        #expect(ConfidenceBadge.label(for: .verified) != ConfidenceBadge.label(for: .guess))
        #expect(ConfidenceBadge.tint(for: .verified) != ConfidenceBadge.tint(for: .guess))
    }

    @Test("An unrecognised confidence level from a future schema still carries its raw value")
    func unknownConfidenceCarriesRawValue() {
        #expect(ConfidenceBadge.label(for: .unknown("mystery")).contains("mystery"))
    }
}
