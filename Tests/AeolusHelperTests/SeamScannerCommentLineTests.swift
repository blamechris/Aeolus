import Foundation
import Testing

/// A `//` at the start of a line opens a comment only where the lexer is reading code (#457).
///
/// `SeamScanner.strippingComments` used to drop every line whose trimmed text began `//` before the
/// literal walker saw the source. A line of a multi-line literal that began `//` went with them,
/// and so did the call in an interpolation on it:
///
/// ```swift
/// """
/// //\(HelperComposition<SMCFanControlPlane>.production(log: HelperLog()))
/// """
/// ```
///
/// No rule-zero scan saw a `production` token in that: they read `RuleZeroScan.code(of:)`, which is
/// built on that function. Nobody writes it by accident, and a graph built that way has no write
/// channel (`production` withholds it), so this closes a hole in what the scans read and not a
/// route to the SMC. ADR 0014's compiler seam is the control; these scans catch accidents.
///
/// The whole-line filter is now the walker's: it drops a `//` comment that is the whole of its
/// line, where it is reading code, and is never offered a line that is inside a literal.
@Suite("A line that begins // is a comment only where the lexer reads code")
struct SeamScannerCommentLineTests {

    /// The call the fixtures hide, as a rule-zero reach pattern would meet it.
    private static let call = "X.production(log: L())"

    private static func code(_ source: String) -> String { RuleZeroScan.code(of: source) }

    /// Every shape that puts an interpolation on a line of a literal that begins `//`. Each is
    /// lexical text, never compiled or run.
    private static let hidingShapes: [(name: String, source: String)] = [
        (
            "multi-line",
            #"""
            let s = """
                //\(X.production(log: L()))
                """
            """#
        ),
        (
            "the shape #457 names, as a function's result",
            #"""
            func zzDescribe() -> String {
                """
                //\(X.production(log: L()))
                """
            }
            """#
        ),
        (
            "flush left, as the issue wrote it",
            #"""
            """
            //\(X.production(log: L()))
            """
            """#
        ),
        (
            "an indented marker",
            #"""
            let s = """
                    //\(X.production(log: L()))
                """
            """#
        ),
        (
            "a tab before the marker",
            "let s = \"\"\"\n\t//\\(X.production(log: L()))\n\t\"\"\""
        ),
        (
            "a triple slash",
            #"""
            let s = """
                ///\(X.production(log: L()))
                """
            """#
        ),
        (
            "after a line of text",
            #"""
            let s = """
                some text
                //\(X.production(log: L()))
                more text
                """
            """#
        ),
        (
            "raw",
            ##"""
            let s = #"""
                //\#(X.production(log: L()))
                """#
            """##
        ),
        (
            "nested in an interpolation",
            #"""
            let s = """
                \(wrap("""
                //\(X.production(log: L()))
                """))
                """
            """#
        ),
        (
            "a raw literal nested in an interpolation",
            ##"""
            let s = """
                \(wrap(#"""
                //\#(X.production(log: L()))
                """#))
                """
            """##
        ),
    ]

    @Test("An interpolation on a //-led line of a multi-line literal is code, in every shape")
    func anInterpolationOnACommentLedLineIsCode() throws {
        for (name, source) in Self.hidingShapes {
            let stripped = SeamScanner.strippingComments(source)
            #expect(stripped.contains(Self.call), "\(name), strippingComments: \(stripped)")
            let kept = SeamScanner.strippingAllComments(source)
            #expect(kept.contains(Self.call), "\(name), strippingAllComments: \(kept)")
            let code = Self.code(source)
            #expect(code.contains(Self.call), "\(name), RuleZeroScan.code: \(code)")
            #expect(
                try RuleZeroScan.count(RuleZeroScan.productionMember, in: code) == 1,
                "\(name): \(code)")
        }
    }

    /// A line of a literal that begins `//` and holds no interpolation is only text, and is removed
    /// with the rest of the literal's text, so the filter's change adds no code to the scans.
    @Test("A //-led line of a literal with no interpolation is text, and is stripped as text")
    func aCommentLedLineWithNoInterpolationIsText() {
        let source = #"""
            let s = """
                // production(log: L()) is prose here
                """
            await helper.bringUp()
            """#
        #expect(SeamScanner.strippingComments(source).contains("// production(log: L())"))
        #expect(SeamScanner.strippingAllComments(source).contains("// production(log: L())"))
        let code = Self.code(source)
        #expect(!code.contains("production"), "\(code)")
        #expect(code.contains("await helper.bringUp()"), "\(code)")
    }

    @Test("A comment line outside a literal is dropped, beside a literal that keeps its own")
    func aCommentLineOutsideALiteralIsDropped() {
        let source = #"""
            // before: Before.production(log: L())
            let s = """
                //\(Inside.production(log: L()))
                """
                /// after: After.production(log: L())
            /* block */ // block-led: Block.production(log: L())
            /* spans
               lines */ // spanning: Spanning.production(log: L())
            let t = 1
            """#
        let stripped = SeamScanner.strippingComments(source)
        for gone in ["Before", "After", "Block", "Spanning"] {
            #expect(!stripped.contains(gone), "\(gone): \(stripped)")
        }
        let code = Self.code(source)
        #expect(code.contains("Inside.production(log: L())"), "\(code)")
        #expect(code.contains("let t = 1"), "\(code)")
        for gone in ["Before", "After", "Block", "Spanning"] {
            #expect(!code.contains(gone), "\(gone): \(code)")
        }
    }

    @Test("A // inside a single-line literal is text: kept by one stripper, dropped by the other")
    func aCommentMarkerInASingleLineLiteralIsText() {
        let source = #"""
            let a = "// not a comment"; await helper.bringUp() // trailing
            let b = "// say \(X.production(log: L()))"
            let c = "https://example.com//path"
            """#
        let kept = SeamScanner.strippingAllComments(source)
        #expect(kept.contains(#""// not a comment""#), "\(kept)")
        #expect(kept.contains(#""https://example.com//path""#), "\(kept)")
        #expect(!kept.contains("trailing"), "\(kept)")
        let code = Self.code(source)
        #expect(code.contains("await helper.bringUp()"), "\(code)")
        #expect(code.contains(Self.call), "\(code)")
        for text in ["not a comment", "say", "example.com", "path", "trailing"] {
            #expect(!code.contains(text), "\(text): \(code)")
        }
    }

    /// What the walker does with a dropped line has to be what the filter did: the line and one
    /// newline go, and nothing else. A scan that counts lines or reads what follows a comment line
    /// reads the same text as before.
    @Test("A dropped comment line takes its own newline and nothing else")
    func aDroppedLineTakesItsOwnNewline() {
        let cases: [(source: String, stripped: String)] = [
            ("a\n// c\nb", "a\nb"),
            ("// c\na", "a"),
            ("a\n// c", "a"),
            ("a\n// c\n", "a\n"),
            ("// c", ""),
            ("// c\n", ""),
            ("// c\n// d", ""),
            ("a\n// c\n// d", "a"),
            ("a\n\n// c", "a\n"),
            ("a\n\n// c\n\nb", "a\n\n\nb"),
            ("a\n    // c\nb", "a\nb"),
            ("a\n\t// c\nb", "a\nb"),
            ("a\n///doc\nb", "a\nb"),
            ("a\n/* x */ // c\nb", "a\nb"),
            ("a\n/* x\ny */ // c\nb", "a\n \nb"),
            ("a // c\nb", "a // c\nb"),
            ("a\n/ / c\nb", "a\n/ / c\nb"),
            ("let r = 4 / 2\n// c\nlet s = 1", "let r = 4 / 2\nlet s = 1"),
            ("let r = #//a/#\n// c\nlet s = 1", "let r = #//a/#\nlet s = 1"),
        ]
        for (source, stripped) in cases {
            #expect(SeamScanner.strippingComments(source) == stripped, "\(source.debugDescription)")
        }
    }
}
