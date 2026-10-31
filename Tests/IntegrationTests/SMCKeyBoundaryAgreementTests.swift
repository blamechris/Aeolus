import Foundation
import SMCCore
import Testing

@testable import AeolusXPC

/// `SMCKey` and the helper's sensor-key boundary say yes to the same strings (#620).
///
/// Two definitions of one alphabet exist, because neither module can reach the other:
/// `AeolusXPCValidation.validateSensorKey` (#619) lives in `AeolusXPC`, which depends on
/// `FanKit` alone, and `SMCKey` lives in `SMCCore`, which depends on nothing. Sharing one would
/// mean a new edge in `Package.swift` through the privilege boundary's contract module or the
/// SMC layer, which an implementer does not choose. So the two are written separately, and this
/// suite is what keeps them from drifting: a key the boundary accepts that `SMCKey` cannot
/// build would be a curve the helper takes and then cannot read, and the reverse would be a
/// sensor `fanctl` can name that no curve can.
///
/// Both are asked about the same strings and nothing here restates either alphabet, so the
/// suite holds whichever of them moves.
@Suite("SMCKey and validateSensorKey agree on what a sensor key is")
struct SMCKeyBoundaryAgreementTests {

    private enum Verdict: Equatable {
        case accepted
        case refused
        /// Not a fault. It equals neither answer, so it cannot be read as agreement.
        case threwSomethingElse
    }

    private static func boundary(_ key: String) -> Verdict {
        do {
            try AeolusXPCValidation.validateSensorKey(key)
            return .accepted
        } catch is AeolusXPCFault {
            return .refused
        } catch {
            return .threwSomethingElse
        }
    }

    private static func smcKey(_ key: String) -> Verdict {
        SMCKey(key) == nil ? .refused : .accepted
    }

    /// `scalar`, padded with `A` to four bytes where it is shorter, so a scalar of at most four
    /// bytes is judged on the alphabet and not on the length.
    private static func fourBytes(around scalar: Unicode.Scalar) -> String {
        var key = String.UnicodeScalarView()
        key.append(scalar)
        key.append(contentsOf: repeatElement("A", count: max(0, 4 - scalar.utf8.count)))
        return String(key)
    }

    private static func named(_ keys: [String]) -> [String] {
        keys.prefix(20).map { String(reflecting: $0) }
    }

    /// Every Unicode scalar, as a key of four bytes: the two agree, so they agree on the
    /// whole of U+0000 to U+00FF and on every scalar past it, which is more than the sample
    /// the acceptance asked for and costs the same as `XPCSensorKeyValidationTests`' sweep.
    ///
    /// Asserted on a count, with the first twenty named, for the reason that suite gives: an
    /// `#expect` on an array prints all of it.
    ///
    /// **Mutation:** in `AeolusXPCValidation.isSensorKeyScalar`, return `scalar.isASCII` alone.
    /// Run: red on `disagreeing`, naming the C0 controls and DEL. **Mutation:** in `SMCKey`,
    /// widen `permittedBytes` to `0x20...0x7F`. Run: red on `disagreeing`, naming DEL.
    @Test("Every scalar, in a key of four bytes, is judged the same")
    func everyScalarIsJudgedTheSame() async {
        var disagreeing: [String] = []
        var accepted = 0
        await CodeSpace.forEachRun { run in
            for scalar in run {
                let key = Self.fourBytes(around: scalar)
                let verdict = Self.boundary(key)
                if verdict == .accepted { accepted += 1 }
                if verdict != Self.smcKey(key) { disagreeing.append(key) }
            }
        }
        let disagreeingCount = disagreeing.count
        #expect(disagreeingCount == 0, "judged differently: \(Self.named(disagreeing))")
        // Printable ASCII, U+0020 to U+007E, and nothing else, so the sweep is not agreeing
        // on a list that is empty.
        #expect(accepted == 95)
    }

    /// U+0000 to U+00FF in each of the four places of an otherwise legal key. A scalar of two
    /// bytes makes a five-byte key out of three more, so this is the length guard and the
    /// alphabet guard met together.
    ///
    /// **Mutation:** in `AeolusXPCValidation.isSensorKeyScalar`, return `scalar.isASCII` alone.
    /// Run: red on `disagreeing`, naming the C0 controls and DEL in each of the four places.
    @Test("U+0000 to U+00FF in every position of a key is judged the same")
    func theLatinOneRangeInEveryPositionIsJudgedTheSame() {
        var disagreeing: [String] = []
        for value in UInt32(0)...0xFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            for position in 0..<4 {
                var scalars = Array("Tp09".unicodeScalars)
                scalars[position] = scalar
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars)
                let key = String(view)
                if Self.boundary(key) != Self.smcKey(key) { disagreeing.append(key) }
            }
        }
        let disagreeingCount = disagreeing.count
        #expect(disagreeingCount == 0, "judged differently: \(Self.named(disagreeing))")
    }

    /// Every string of up to five characters over a handful that matter: the ends of the
    /// alphabet, the space, the controls, a two-byte and a four-byte scalar, a combining
    /// mark that a `Character` count folds into its neighbour, a line separator, and the
    /// `\r` and `\n` that fold into each other. This is where a count of characters and a
    /// count of bytes part, and it holds each accepted key to what `SMCKey` promises of one.
    ///
    /// **Mutation:** put `SMCKey.init(_:)` back to `rawValue.count == 4,
    /// rawValue.allSatisfy(\.isASCII)`. Run: red on `disagreeing` and on `brokenKeys`, naming
    /// strings such as `"A\r\nAA"`, four characters and five bytes. **Mutation:** delete the
    /// `utf8.count` guard in `SMCKey.init(_:)`. Run: red on `disagreeing` and on `brokenKeys`,
    /// naming `"AAAAA"`, which the other two tests in this suite cannot reach.
    @Test("Every short string over the characters that matter is judged the same")
    func shortStringsOverTheCharactersThatMatterAreJudgedTheSame() {
        let alphabet: [Character] = [
            "A", " ", "~", "\u{7F}", "\u{0}", "\r", "\n", "\u{E9}", "\u{1F321}", "\u{301}",
            "\u{2028}",
        ]
        var strings: [[Character]] = [[]]
        var frontier: [[Character]] = [[]]
        for _ in 1...5 {
            frontier = frontier.flatMap { prefix in alphabet.map { prefix + [$0] } }
            strings.append(contentsOf: frontier)
        }

        var disagreeing: [String] = []
        var brokenKeys: [String] = []
        var accepted = 0
        for characters in strings {
            let text = String(characters)
            if Self.boundary(text) != Self.smcKey(text) { disagreeing.append(text) }
            guard let key = SMCKey(text) else { continue }
            accepted += 1
            let spelled = key.rawValue == text && text.utf8.count == 4 && text.count == 4
            if !spelled || SMCKey(fourCharCode: key.fourCharCode) != key {
                brokenKeys.append(text)
            }
        }
        let disagreeingCount = disagreeing.count
        let brokenKeysCount = brokenKeys.count
        #expect(strings.count == 177_156)
        #expect(disagreeingCount == 0, "judged differently: \(Self.named(disagreeing))")
        #expect(
            brokenKeysCount == 0,
            "not four bytes, or not their own code: \(Self.named(brokenKeys))")
        // Four characters of the three single-byte ones: 3^4. Fewer, and the walk missed some.
        #expect(accepted == 81)
    }
}
