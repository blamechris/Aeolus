import AeolusXPC
import Foundation
import Testing

@testable import fanctl

/// `DisplayText` removes exactly what `AeolusXPC` says to remove: `FaultText.isRemovedFromDisplay`,
/// Unicode Cc, Cf, Zl and Zp, the one rule the helper's validation refuses and the app's
/// `HelperAuthoredText` removes too (#483).
@Suite("fanctl's DisplayText removes what AeolusXPC removes")
struct DisplayTextTests {

    /// The two scalars #483 is about, mid-string, where the whitespace trim cannot reach them:
    /// `trimmingCharacters(in: .whitespacesAndNewlines)` already removes them at an edge.
    ///
    /// **Mutation (#483):** in `DisplayText.sanitised`, make the filter
    /// `{ !CharacterSet.controlCharacters.contains($0) }` again. Run: red on both rows.
    @Test(
        "A line or paragraph separator does not reach the terminal",
        arguments: [
            "\u{2028}", "\u{2029}",
        ])
    func aSeparatorIsRemoved(_ separator: String) {
        #expect(DisplayText.sanitised("Aeolus.app\(separator)DENIED") == "Aeolus.appDENIED")
    }

    /// Both halves over the whole code space: every scalar of the shared rule is removed, one at
    /// a time so a failure names it, and no other scalar is, in runs of 150 so the 200-character
    /// cap never cuts one. "a" and "b" shield each end from the whitespace trim, which is a
    /// separate rule. Scalars, not `String`s, are compared, because `==` on `String` is
    /// canonical equivalence and could call a changed string equal.
    ///
    /// **Mutation (#483):** as above. Run: red on `survivors.isEmpty`, naming U+2028 and U+2029;
    /// `changed.isEmpty` stays green.
    /// **Mutation:** the filter also removes `.privateUse`. Run: red on `changed.isEmpty`;
    /// `survivors.isEmpty` stays green.
    @Test("Every scalar in Cc, Cf, Zl or Zp is removed, and no other scalar is")
    func removesExactlyTheSharedRule() {
        let scalars = (0...0x10FFFF).compactMap(Unicode.Scalar.init)
        let removed = scalars.filter(FaultText.isRemovedFromDisplay)
        #expect(removed.count > 200)
        #expect(removed.contains("\u{2028}") && removed.contains("\u{2029}"))
        let survivors = removed.filter {
            DisplayText.sanitised("a" + String(Character($0)) + "b") != "ab"
        }
        #expect(
            survivors.isEmpty, "survived: \(survivors.map { String(format: "U+%04X", $0.value) })")

        let kept = scalars.filter { !FaultText.isRemovedFromDisplay($0) }
        let changed = stride(from: 0, to: kept.count, by: 150).filter { start in
            var input = String.UnicodeScalarView()
            input.append("a")
            input.append(contentsOf: kept[start..<min(start + 150, kept.count)])
            input.append("b")
            let output = DisplayText.sanitised(String(input))
            return Array(output.unicodeScalars) != Array(input)
        }
        let starts = changed.prefix(10).map { String(format: "U+%04X", kept[$0].value) }
        #expect(changed.isEmpty, "changed: \(changed.count) runs, the first starting at \(starts)")
    }
}
