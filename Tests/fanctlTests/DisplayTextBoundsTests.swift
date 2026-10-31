import Foundation
import Testing

@testable import fanctl

/// `DisplayText` bounds helper-authored text by UTF-8 bytes as well as by characters, as
/// `FaultText.displayable` and the app's `HelperAuthoredText` do (#567).
///
/// A character cap alone does not bound what reaches a terminal: a combining mark or an emoji
/// modifier extends the grapheme cluster before it and adds no character, so 200 characters can
/// be hundreds of kilobytes. The caps are 200 characters and 800 UTF-8 bytes, and the ellipsis,
/// one character of three bytes, is counted inside both.
///
/// **The caps are literals here, on purpose.** `DisplayText` has none of its own: they are
/// `FaultDetailBounds`'s. A test that read them from there would be an oracle that moves with the
/// behaviour, and stay green when the shared cap changed. These are #567's 200 and 800, so a
/// change to the shared caps is red here until someone decides this suite should follow it.
///
/// **What these inputs avoid.** Nothing in them is in Unicode Cc, Cf, Zl or Zp, which
/// `DisplayText` removes before it cuts: an emoji ZWJ sequence, for one, is not one long cluster
/// here, because U+200D is Cf and goes first. Combining marks (Mn, Me) and emoji modifiers (Sk)
/// all stay, and all extend the cluster before them.
@Suite("fanctl's DisplayText bounds bytes as well as characters")
struct DisplayTextBoundsTests {

    private static let ellipsis = "…"
    private static let maxLength = 200
    private static let maxUTF8Bytes = 800

    /// One shape of cluster, repeated until it overflows both caps.
    struct Shape: Sendable, CustomTestStringConvertible {
        let name: String
        let cluster: String
        var testDescription: String { name }

        var scalarCount: Int { cluster.unicodeScalars.count }
        var byteCount: Int { cluster.utf8.count }

        static let all = [
            // The two the issue names: a run of combining marks, and an emoji with modifiers.
            Shape(name: "a + 200 combining acutes (401 bytes)", cluster: "a" + marks(200)),
            Shape(
                name: "thumbs up + 100 skin-tone modifiers (404 bytes)",
                cluster: "\u{1F44D}" + String(repeating: "\u{1F3FD}", count: 100)),
            // A flag is two regional indicators: one character, eight bytes, and a realistic one.
            Shape(name: "flag (8 bytes)", cluster: "\u{1F1EF}\u{1F1F5}"),
            // The byte budget for text is 797 once the ellipsis has its room, a prime, so none of
            // these divides it and a cut by bytes alone lands inside a cluster. For every shape
            // here but the nine-byte one it lands inside a scalar as well, which is what turns
            // into U+FFFD when the cut text is decoded.
            Shape(name: "a + 2 combining marks (5 bytes)", cluster: "a" + marks(2)),
            Shape(name: "a + 3 combining marks (7 bytes)", cluster: "a" + marks(3)),
            Shape(name: "a + 4 combining marks (9 bytes)", cluster: "a" + marks(4)),
        ]

        private static func marks(_ count: Int) -> String {
            String(repeating: "\u{0301}", count: count)
        }
    }

    /// Dense text, over both caps, is cut inside both, whole clusters at a time, and the cut is
    /// the longest one that fits.
    ///
    /// Asserted as the property the issue names, not as a call into `FaultDetailBounds`: the
    /// bound on bytes and on characters, the ellipsis, the cut on a cluster boundary (a whole
    /// number of clusters, each of them the input's own, from its start), the exact count of
    /// clusters kept, and no U+FFFD. That one is the check for invalid UTF-8: a Swift `String` is
    /// always valid, so a cut that split a scalar shows as the replacement character where the
    /// cut bytes were decoded, and the input has none.
    ///
    /// **Mutation (#567):** in `DisplayText.sanitised`, replace everything after the empty check
    /// with the body it had before: `guard trimmed.count > maxLength else { return trimmed }` and
    /// `return String(trimmed.prefix(maxLength - 1)) + "…"`. Run: red on the byte bound and on
    /// the exact count, in all six rows. The cluster boundary stays green, because a cut by
    /// characters never splits one.
    /// **Mutation:** in its place, cut by bytes at a scalar boundary: the character cap, then
    /// scalars while 797 bytes hold. Run: red on the cluster boundary in all six rows. The byte
    /// bound and the exact count stay green, the count being floored over a part-cluster.
    /// **Mutation:** in its place, cut the raw bytes at 797 and decode them
    /// (`String(decoding: Array(trimmed.utf8.prefix(797)), as: UTF8.self)`). Run: red on the
    /// U+FFFD check and on the comparison with the input's start in the five rows whose 797th
    /// byte falls inside a scalar. The nine-byte row's falls between two scalars, and it is red on
    /// the cluster boundary alone.
    @Test(
        "Dense text is cut inside both caps, whole clusters at a time",
        arguments: Shape.all)
    func denseTextIsCutOnAClusterBoundary(_ shape: Shape) {
        let input = String(repeating: shape.cluster, count: 300)
        let output = DisplayText.sanitised(input)

        #expect(
            output.utf8.count <= Self.maxUTF8Bytes,
            "\(output.utf8.count) bytes against a cap of \(Self.maxUTF8Bytes)")
        #expect(output.count <= Self.maxLength)
        #expect(output.last == Character(Self.ellipsis), "the cut is not marked")
        #expect(!output.unicodeScalars.contains("\u{FFFD}"), "a scalar was cut in half")

        let kept = output.unicodeScalars.dropLast()
        let keptScalars = Array(kept)
        #expect(
            keptScalars.count.isMultiple(of: shape.scalarCount),
            "the cut left part of a cluster: \(keptScalars.count) scalars of \(shape.scalarCount)")
        // A Bool, not the arrays: a failed comparison of two 80 KB arrays prints both.
        let isTheInputsOwnStart =
            keptScalars == Array(input.unicodeScalars.prefix(keptScalars.count))
        #expect(isTheInputsOwnStart, "what was kept is not the input's own start")

        // The ellipsis takes its room out of both caps: 199 characters and 797 bytes for the rest.
        let ellipsisBytes = Self.ellipsis.utf8.count
        let room = (Self.maxUTF8Bytes - ellipsisBytes) / shape.byteCount
        let expectedClusters = min(Self.maxLength - Self.ellipsis.count, room)
        let keptClusters = keptScalars.count / shape.scalarCount
        #expect(
            keptClusters == expectedClusters,
            "kept \(keptClusters) clusters, the longest fit is \(expectedClusters)")
    }

    /// Under the character cap and far over the byte cap: the case the character cap alone
    /// returns whole. A hundred clusters is a hundred characters, and forty kilobytes.
    ///
    /// **Mutation (#567):** the first one above, the body before the byte bound. Run: red on the
    /// byte bound and on the comparison, the output being the 40 KB input unchanged.
    /// **Mutation:** the second, a cut by bytes at a scalar boundary. Run: red on the comparison
    /// alone, the output being one whole cluster and the start of a second.
    @Test("A hundred dense clusters are under the character cap and still cut")
    func underTheCharacterCapIsStillCutByBytes() {
        let cluster = "a" + String(repeating: "\u{0301}", count: 200)
        let input = String(repeating: cluster, count: 100)
        #expect(input.count == 100 && input.utf8.count > 40_000, "the input is not what it claims")

        let output = DisplayText.sanitised(input)

        #expect(output.utf8.count <= Self.maxUTF8Bytes)
        // A Bool, not the strings: a failed comparison would print the 40 KB output.
        let isOneClusterAndTheEllipsis = output == cluster + Self.ellipsis
        #expect(isOneClusterAndTheEllipsis)
    }

    /// The byte cap is exactly 800: text of 800 bytes passes whole and 801 is cut, with 199
    /// characters either way, so the character cap cannot be what decides it.
    ///
    /// 198 four-byte emoji, then one character of eight or nine bytes: a letter with combining
    /// marks.
    ///
    /// **Mutation (#567):** the first one above. Run: red on the 801-byte row, which comes back
    /// whole; the 800-byte row stays green. **Mutation:** the second. Run: red on the same row,
    /// the cut landing inside the tail cluster.
    @Test(
        "800 bytes pass unchanged and 801 are cut, at 199 characters",
        arguments: [(tailBytes: 8, isCut: false), (tailBytes: 9, isCut: true)])
    func theByteCapIsExact(tailBytes: Int, isCut: Bool) {
        let emoji = "\u{1F600}"
        // 8 = 1 + 2 + 2 + 3 (a, two acutes, an enclosing keycap); 9 = 1 + 4 * 2 (a, four acutes).
        let tail =
            tailBytes == 8
            ? "a\u{0301}\u{0301}\u{20E3}" : "a" + String(repeating: "\u{0301}", count: 4)
        let input = String(repeating: emoji, count: 198) + tail
        #expect(input.count == 199 && input.utf8.count == 792 + tailBytes, "bad fixture")

        let output = DisplayText.sanitised(input)

        if isCut {
            #expect(output == String(repeating: emoji, count: 198) + Self.ellipsis)
        } else {
            #expect(output == input)
        }
    }

    /// One cluster too dense to fit at all reads as unprintable, not as a bare ellipsis, which
    /// would say that something was cut and show nothing of it. A real ellipsis is still text.
    ///
    /// **Mutation (#567):** delete the `if bounded == FaultDetailBounds.truncationMarker, …`
    /// clause from `DisplayText.sanitised`. Run: red on the first expectation, which comes back
    /// as a bare `…`; the second stays green. **Mutation:** drop `, trimmed != bounded` from it.
    /// Run: red on the second expectation, a real `…` coming back as unprintable; the first stays
    /// green.
    @Test("A cluster too dense to fit is unprintable, and a real ellipsis is not")
    func aClusterTooDenseToFitIsUnprintable() {
        let one = "a" + String(repeating: "\u{0301}", count: 1_000)
        #expect(DisplayText.sanitised(one) == DisplayText.unprintable)
        #expect(DisplayText.sanitised(Self.ellipsis) == Self.ellipsis)
    }
}
