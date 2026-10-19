import Foundation
import Testing

/// The first line of an interpolation's code is not the start of a line (#460's review, B1).
///
/// Swift reads `\( // c` as a comment trailing code. The walker was handed the code of an
/// interpolation as a string of its own, so the `//` in `\( // c` looked like the whole of its
/// line, and was dropped with its newline. The code after it stayed visible, but
/// `strippingComments` removed a comment it leaves everywhere else, and every line number after it
/// was one short in a scan that reads line numbers: `RoleCensus` says a failure "names the line
/// the source has", and with this shape it named the line before.
///
/// `SeamScannerInterpolationCommentTests` holds what the walker does with a comment in an
/// interpolation; this holds where its lines start. The fixtures are lexical text, never
/// compiled or run.
@Suite("The first line of an interpolation's code is not the start of a line")
struct SeamScannerInterpolationLineStartTests {

    private static func lines(_ text: String) -> Int {
        text.filter { $0 == "\n" }.count
    }

    /// Every shape puts a `//` comment right after the `\(` that opens an interpolation, with the
    /// rest of the interpolation on the next line.
    private static let trailing: [(name: String, source: String)] = [
        (
            "after the opening of a multi-line literal's interpolation",
            #"""
            let s = """
                \( // c
                f(1))
                """
            """#
        ),
        (
            "after a block comment, which the walker has turned into a space",
            #"""
            let s = """
                \( /* b */ // c
                f(1))
                """
            """#
        ),
        (
            "in a raw literal",
            ##"""
            let s = #"""
                \#( // c
                f(1))
                """#
            """##
        ),
        (
            "in the interpolation of a literal nested in an interpolation",
            #"""
            let s = """
                \(wrap("""
                \( // c
                f(1))
                """))
                """
            """#
        ),
    ]

    /// `strippingComments` leaves a trailing comment and its newline, and `strippingAllComments`
    /// removes the comment and keeps the newline, so neither moves a line.
    ///
    /// **Mutation:** make `strippingBlockAndLineComments` treat the start of an interpolation's
    /// code as the start of a line (`startsLine: true` at its call in `copyDelimited`'s closure).
    /// Run: red here, at every shape.
    @Test("A comment right after the opening of an interpolation trails code and keeps its newline")
    func aCommentAfterTheOpeningTrailsCode() {
        for (name, source) in Self.trailing {
            // The one change `strippingComments` makes is a block comment into one space.
            let stripped = source.replacingOccurrences(of: "/* b */", with: " ")
            let kept = SeamScanner.strippingComments(source)
            #expect(kept == stripped, "\(name), strippingComments: \(kept)")
            let removed = SeamScanner.strippingAllComments(source)
            #expect(!removed.contains("// c"), "\(name), strippingAllComments: \(removed)")
            #expect(
                Self.lines(removed) == Self.lines(source),
                "\(name), strippingAllComments: \(removed)"
            )
            #expect(removed.contains("f(1))"), "\(name), strippingAllComments: \(removed)")
        }
    }

    /// A whole-line comment on a later line of the same interpolation is still the whole of its
    /// line: it goes, with its newline, and the line after it stays.
    @Test("A comment line later in an interpolation is still dropped with its newline")
    func aLaterCommentLineIsStillDropped() {
        let source = #"""
            let s = """
                \(f(1,
                // c
                g(2)))
                """
            """#
        let expected = #"""
            let s = """
                \(f(1,
                g(2)))
                """
            """#
        #expect(SeamScanner.strippingComments(source) == expected)
    }

    /// `RoleCensus` keeps every line, so that a failure names the line the source has. The role
    /// below is on line 5 of the source; with the comment after the `\(` read as the whole of its
    /// line, it was found on line 4.
    ///
    /// **Mutation:** as above. Run: red here.
    @Test("The role census names the source's own line after a comment right after a \\(")
    func theCensusNamesTheSourcesOwnLine() {
        let source = #"""
            let s = """
                \( // note
                f(1))
                """
            private let latch: any ThermalLatchRole
            """#
        #expect(Self.lines(RoleCensus.code(of: source)) == Self.lines(source))
        let found = RoleCensus.occurrences(
            inSource: source, path: "Some/File.swift", roles: ["ThermalLatchRole"])
        #expect(found.map(\.line) == [5], "\(found)")
        #expect(found.first?.statement == "let latch: any ThermalLatchRole", "\(found)")
    }
}
