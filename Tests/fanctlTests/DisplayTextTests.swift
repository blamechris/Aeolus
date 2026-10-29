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
    /// a time so a failure names it, and no other scalar is, in runs of at most 150 so the
    /// 200-character cap never cuts one. "a" and "b" shield each end from the whitespace trim,
    /// which is a separate rule. Scalars, not `String`s, are compared, because `==` on `String` is
    /// canonical equivalence and could call a changed string equal. The code space is walked a
    /// run at a time, and each run is cut into those runs of 150, so the sweep gives the pool
    /// back between them (`CodeSpace`, #570).
    ///
    /// **Mutation (#483):** as above. Run: red on `survivors.isEmpty`, naming U+2028 and U+2029;
    /// `changed.isEmpty` stays green.
    /// **Mutation:** the filter also removes `.privateUse`. Run: red on `changed.isEmpty`;
    /// `survivors.isEmpty` stays green.
    @Test("Every scalar in Cc, Cf, Zl or Zp is removed, and no other scalar is")
    func removesExactlyTheSharedRule() async {
        var removed: [Unicode.Scalar] = []
        var survivors: [Unicode.Scalar] = []
        var changedStarts: [Unicode.Scalar] = []
        await CodeSpace.forEachRun { run in
            let removedInTheRun = run.filter(FaultText.isRemovedFromDisplay)
            removed += removedInTheRun
            survivors += removedInTheRun.filter {
                DisplayText.sanitised("a" + String(Character($0)) + "b") != "ab"
            }

            let kept = run.filter { !FaultText.isRemovedFromDisplay($0) }
            for start in stride(from: 0, to: kept.count, by: 150) {
                var input = String.UnicodeScalarView()
                input.append("a")
                input.append(contentsOf: kept[start..<min(start + 150, kept.count)])
                input.append("b")
                let output = DisplayText.sanitised(String(input))
                if Array(output.unicodeScalars) != Array(input) {
                    changedStarts.append(kept[start])
                }
            }
        }
        #expect(removed.count > 200)
        #expect(removed.contains("\u{2028}") && removed.contains("\u{2029}"))
        #expect(
            survivors.isEmpty, "survived: \(survivors.map { String(format: "U+%04X", $0.value) })")

        let starts = changedStarts.prefix(10).map { String(format: "U+%04X", $0.value) }
        #expect(
            changedStarts.isEmpty,
            "changed: \(changedStarts.count) runs, the first starting at \(starts)")
    }
}
