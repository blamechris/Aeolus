import FanKit
import Foundation
import Testing

@testable import AeolusXPC

/// What `FaultText` removes from the free text a fault carries (#553).
///
/// `XPCFaultTests.renderingStripsControlCharacters` holds the per-fault rendering to the
/// characters it names. This suite holds the *class*: every scalar in the four Unicode
/// categories, found by walking the code space, rather than the handful someone thought of.
@Suite("FaultText removes Cc, Cf, Zl and Zp from rendered fault text")
struct FaultTextDisplayTests {

    /// The oracle is the Unicode general category, not `FaultText`'s own predicate, which is
    /// what is being held to it.
    private static func inTheFourCategories(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    private static let allScalars: [Unicode.Scalar] = (0...0x10FFFF).compactMap {
        Unicode.Scalar($0)
    }

    private static func hex(_ scalars: some Sequence<Unicode.Scalar>) -> [String] {
        scalars.map { String(format: "U+%04X", $0.value) }
    }

    /// One call over the whole code space, so every scalar is judged in the same string and
    /// the run costs one pass rather than 1.1 million. "a" and "b" shield the ends from the
    /// whitespace trim, which is a separate rule, and both caps are lifted so truncation is
    /// not what removes anything.
    ///
    /// Both halves: nothing in the four categories survives, and nothing outside them is lost.
    /// A predicate that stripped too much would pass the first half alone.
    ///
    /// **Mutation (#553):** in `FaultText.isRemovedFromDisplay`, delete `.lineSeparator,
    /// .paragraphSeparator` from the `case`. Run: red, naming U+2028 and U+2029 as survivors.
    /// **Mutation:** in `displayable`, replace the filter's predicate with `{ _ in false }`.
    /// Run: red, naming every scalar of the four categories.
    @Test("No scalar in Cc, Cf, Zl or Zp survives, and no other scalar is lost")
    func displayableRemovesEveryScalarOfTheFourCategories() {
        let removed = Self.allScalars.filter(Self.inTheFourCategories)
        #expect(removed.count > 200)
        #expect(removed.contains("\u{2028}"))
        #expect(removed.contains("\u{2029}"))

        var input = String.UnicodeScalarView()
        input.append("a")
        input.append(contentsOf: Self.allScalars)
        input.append("b")
        let output = Set(
            FaultText.displayable(String(input), limit: .max, byteLimit: .max).unicodeScalars)

        let survivors = removed.filter { output.contains($0) }
        let lost = Self.allScalars.filter { !Self.inTheFourCategories($0) && !output.contains($0) }
        #expect(survivors.isEmpty, "survived: \(Self.hex(survivors))")
        #expect(lost.isEmpty, "lost: \(Self.hex(lost.prefix(20)))")
    }

    /// The two scalars #553 is about, named, in the middle of a string where the whitespace
    /// trim cannot reach them: `trimmingCharacters(in: .whitespacesAndNewlines)` removes them
    /// at an edge already, which is why only the middle was ever exposed.
    ///
    /// **Mutation (#553):** as above. Run: red on both expectations.
    @Test(
        "A line or paragraph separator inside a detail does not survive",
        arguments: ["\u{2028}", "\u{2029}"]
    )
    func aSeparatorInsideADetailIsRemoved(_ separator: String) {
        let rendered = FaultText.displayable("type\(separator)a is not numeric")

        #expect(rendered == "typea is not numeric")
        #expect(!rendered.unicodeScalars.contains(where: { $0 == "\u{2028}" || $0 == "\u{2029}" }))
    }
}
