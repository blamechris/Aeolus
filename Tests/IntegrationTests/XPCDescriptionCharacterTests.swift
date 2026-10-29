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

    /// The class, not the two scalars above: every scalar of the shared rule is refused, one at
    /// a time so a failure names it, and every other scalar is accepted, in one pass with the
    /// caps lifted. A guard that refused too much would pass the first half alone.
    ///
    /// The walk also takes every scalar `CharacterSet.controlCharacters` contains, which was
    /// this guard's predicate until #483. Foundation and the standard library each carry their
    /// own Unicode tables, so a scalar one calls Cf and the other does not would leave the
    /// refused set *smaller* than before, silently. On the macOS 27.2 this was written on, the
    /// two differ by exactly U+2028 and U+2029; every machine this suite runs on checks again.
    ///
    /// **Mutation (#483):** as above. Run: red on `admitted.isEmpty`, naming U+2028 and U+2029.
    /// **Mutation:** the guard's predicate also refuses `.privateUse`. Run: red on the second
    /// half's `fault(…) == nil`; the first half stays green.
    @Test("Every scalar in Cc, Cf, Zl or Zp is refused in a description, and no other is")
    func descriptionRefusesExactlyTheSharedRule() {
        let scalars = (0...0x10FFFF).compactMap(Unicode.Scalar.init)
        let refused = scalars.filter {
            FaultText.isRemovedFromDisplay($0) || CharacterSet.controlCharacters.contains($0)
        }
        #expect(refused.count > 200)
        #expect(refused.contains("\u{2028}") && refused.contains("\u{2029}"))
        let admitted = refused.filter { scalar in
            let description = "a" + String(Character(scalar)) + "b"
            return refusedDetail({ try AeolusXPCValidation.validateHolderDescription(description) })
                != Self.characterRefusal
        }
        #expect(
            admitted.isEmpty, "admitted: \(admitted.map { String(format: "U+%04X", $0.value) })")

        var rest = String.UnicodeScalarView()
        rest.append("a")
        rest.append(contentsOf: scalars.filter { !FaultText.isRemovedFromDisplay($0) })
        rest.append("b")
        let text = String(rest)
        #expect(
            fault(from: {
                try AeolusXPCValidation.validateDescription(
                    text, name: "sweep", maxLength: .max, maxUTF8Bytes: .max)
            }) == nil)
    }
}
