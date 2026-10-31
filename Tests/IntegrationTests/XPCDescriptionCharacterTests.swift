import FanKit
import Foundation
import Testing

@testable import AeolusXPC

/// Which characters a client-chosen description may carry: none in Unicode Cc, Cf, Zl or Zp,
/// `FaultText.isRemovedFromDisplay`, the one rule `fanctl`'s `DisplayText` and the app's
/// `HelperAuthoredText` remove on the way out (#483).
///
/// Its own suite rather than more of `XPCValidationTests`, which holds every other envelope and
/// was at this repository's type-body limit; the per-character tests there stay where they are.
@Suite("XPC description characters: the shared rule")
struct XPCDescriptionCharacterTests {

    /// What the character guard says. Asserted in full where *which* guard refused is the point.
    static let characterRefusal = "must not contain control, formatting or line-break characters"

    /// U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR are Unicode Zl and Zp, not Cc or Cf,
    /// so `CharacterSet.controlCharacters` let both through until #483, and Core Text and most
    /// terminals break a line on both. Mid-string, where the blank check's trim cannot reach
    /// them, and asserted by the detail, so the character guard is the one that refused.
    ///
    /// **Mutation (#483):** in `validateDescription`, make the guard's predicate
    /// `{ CharacterSet.controlCharacters.contains($0) }` again. Run: red on both rows.
    @Test(
        "A line or paragraph separator in a holder description is refused",
        arguments: ["\u{2028}", "\u{2029}"])
    func aSeparatorInAHolderDescriptionIsRefused(_ separator: String) throws {
        let refused = fault(from: {
            try AeolusXPCValidation.validateHolderDescription("fanctl\(separator)root: granted")
        })
        #expect(
            refused == .invalidParameter(name: "holderDescription", detail: Self.characterRefusal))

        let payload = try AeolusXPCCoding.encoder().encode(
            LeaseRequest(holderDescription: "fanctl\(separator)", fanIndices: [0], timeToLive: 30))
        let decoded = fault(from: {
            _ = try AeolusXPCValidation.leaseRequest(from: payload, enumeratedFanIndices: [0])
        })
        #expect(
            decoded == .invalidParameter(name: "holderDescription", detail: Self.characterRefusal))
    }

    /// The oracle: Unicode general category Cc, Cf, Zl or Zp, written out here rather than asked
    /// of `FaultText`, so a change to the shared predicate is red in this sweep as well as at the
    /// two scalars above.
    private static func inTheFourCategories(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// The class, not the two scalars above: every scalar in the four categories is refused, one
    /// at a time so a failure names it, and every other scalar is accepted, a run of the code
    /// space to a description with the caps lifted, so the sweep gives the pool back between runs
    /// (`CodeSpace`, #570). A guard that refused too much would pass the first half alone.
    ///
    /// **One source of Unicode data, the standard library's.** `CharacterSet.controlCharacters`,
    /// this guard's predicate until #483, reads Foundation's tables, and those are not the same
    /// on every macOS. On macOS 27.2 they hold Cc and Cf exactly. On CI's macOS 26 runner they
    /// also hold 24,735 scalars from U+E0101 to U+EFF7F that are neither: the Cf members of the
    /// U+E00xx page (U+E0001, U+E0020 to U+E007F) repeated on every later page of plane 14, which
    /// puts variation selectors (Mn) and unassigned code points among "control characters" (CI
    /// run 40846340204, when this sweep also walked that set). So the old guard refused a set
    /// that depended on the OS the helper ran on, while the display layers, which read the
    /// general category, did not follow it. Those extra refusals are deliberately not kept:
    /// validation and display read one table, and agree on every machine.
    ///
    /// **Mutation (#483):** as above. Run: red on `admitted.isEmpty`, naming U+2028 and U+2029.
    /// **Mutation:** in `FaultText.isRemovedFromDisplay`, delete `.lineSeparator,
    /// .paragraphSeparator`. Run: red on `admitted.isEmpty`, naming the same two.
    /// **Mutation:** the guard's predicate also refuses `.privateUse`. Run: red on the second
    /// half's `fault(…) == nil`; the first half stays green.
    @Test("Every scalar in Cc, Cf, Zl or Zp is refused in a description, and no other is")
    func descriptionRefusesExactlyTheSharedRule() async {
        var refused: [Unicode.Scalar] = []
        var admitted: [Unicode.Scalar] = []
        var refusalOfOthers: AeolusXPCFault?
        await CodeSpace.forEachRun { run in
            let inTheRun = run.filter(Self.inTheFourCategories)
            refused += inTheRun
            admitted += inTheRun.filter { scalar in
                let description = "a" + String(Character(scalar)) + "b"
                return refusedDetail({
                    try AeolusXPCValidation.validateHolderDescription(description)
                }) != Self.characterRefusal
            }

            var rest = String.UnicodeScalarView()
            rest.append("a")
            rest.append(contentsOf: run.filter { !Self.inTheFourCategories($0) })
            rest.append("b")
            let text = String(rest)
            refusalOfOthers =
                refusalOfOthers
                ?? fault(from: {
                    try AeolusXPCValidation.validateDescription(
                        text, name: "sweep", maxLength: .max, maxUTF8Bytes: .max)
                })
        }
        #expect(refused.count > 200)
        #expect(refused.contains("\u{2028}") && refused.contains("\u{2029}"))
        #expect(
            admitted.isEmpty, "admitted: \(admitted.map { String(format: "U+%04X", $0.value) })")
        #expect(refusalOfOthers == nil)
    }
}
