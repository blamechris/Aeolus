import Foundation
import Testing

/// A comment inside an interpolation is a comment, and a carriage return is refused (#460).
///
/// An interpolation is code, so the walker reads it as code: `copyDelimited` strips the comments in
/// it with the same walker that strips them outside a literal, and `interpolationEnd` skips a
/// comment on its way to the `)` that closes it, so a `)`, a `(` or a `"` in a comment neither
/// closes the interpolation early nor opens a literal. Before this, the text of an interpolation
/// was copied as it stood, and every scan that reads `RuleZeroScan.code(of:)` read a comment in it
/// as code. `RuleZeroScanInterpolationCommentTests` holds what the rule-zero scans then do with
/// the text.
///
/// The fixtures are lexical text, never compiled or run. Each `GONE` is text that must not
/// survive, and each `KEPT` is code that must.
@Suite("A comment inside an interpolation is a comment, and a carriage return is refused")
struct SeamScannerInterpolationCommentTests {

    /// The three views every scan reads: the two strippers, and the rule-zero code built on them.
    private static func views(_ source: String) -> [(name: String, text: String)] {
        [
            ("strippingComments", SeamScanner.strippingComments(source)),
            ("strippingAllComments", SeamScanner.strippingAllComments(source)),
            ("RuleZeroScan.code", RuleZeroScan.code(of: source)),
        ]
    }

    // MARK: - Comments inside an interpolation

    /// Every shape puts a comment in the code of an interpolation, and `KEPT(2)` after it.
    private static let comments: [(name: String, source: String)] = [
        (
            "a comment line, in a multi-line literal",
            #"""
            let s = """
                \(f(1,
                // GONE
                KEPT(2)))
                """
            """#
        ),
        (
            "a block comment on one line",
            #"""
            let s = """
                \(f(1, /* GONE */ KEPT(2)))
                """
            """#
        ),
        (
            "a block comment across lines",
            #"""
            let s = """
                \(f(1, /* GONE
                still GONE */ KEPT(2)))
                """
            """#
        ),
        (
            "a nested block comment",
            #"""
            let s = """
                \(f(1, /* GONE /* GONE */ GONE */ KEPT(2)))
                """
            """#
        ),
        (
            "a raw literal",
            ##"""
            let s = #"""
                \#(f(1,
                // GONE
                KEPT(2)))
                """#
            """##
        ),
        (
            "a literal nested in an interpolation",
            #"""
            let s = """
                \(wrap("""
                \(f(1,
                // GONE
                KEPT(2)))
                """))
                """
            """#
        ),
        (
            "a comment that holds a closing parenthesis",
            #"""
            let s = """
                \(f(1, /* ) GONE ) */
                KEPT(2)))
                """
            """#
        ),
    ]

    /// **Mutation:** put `copyDelimited`'s copy of an interpolation back to the text as it stands.
    /// Run: red here, at every shape.
    @Test("A comment inside an interpolation is stripped by every view")
    func aCommentInAnInterpolationIsStripped() {
        for (name, source) in Self.comments {
            for (view, text) in Self.views(source) {
                #expect(!text.contains("GONE"), "\(name), \(view): \(text)")
                #expect(text.contains("KEPT(2)"), "\(name), \(view): \(text)")
            }
        }
    }

    /// The same two shapes with the comment **trailing code**: `strippingComments` leaves a
    /// trailing comment where it reads code and `strippingAllComments` removes it, in an
    /// interpolation as outside one. A trailing comment in an interpolation was never stripped by
    /// either, so the rule-zero code read it.
    private static let trailing: [(name: String, source: String)] = [
        (
            "trailing, in a multi-line literal",
            #"""
            let s = """
                \(f(1, // GONE
                KEPT(2)))
                """
            """#
        ),
        (
            "trailing, in a raw literal",
            ##"""
            let s = #"""
                \#(f(1, // GONE
                KEPT(2)))
                """#
            """##
        ),
        (
            "trailing, after a nested literal",
            #"""
            let s = """
                \(f("x", // GONE
                KEPT(2)))
                """
            """#
        ),
    ]

    /// **Mutation:** as above. Run: red here.
    @Test("A trailing comment in an interpolation is kept by one stripper and dropped by the rest")
    func aTrailingCommentInAnInterpolation() {
        for (name, source) in Self.trailing {
            let kept = SeamScanner.strippingComments(source)
            #expect(kept.contains("// GONE"), "\(name), strippingComments: \(kept)")
            #expect(kept.contains("KEPT(2)"), "\(name), strippingComments: \(kept)")
            for (view, text) in Self.views(source).dropFirst() {
                #expect(!text.contains("GONE"), "\(name), \(view): \(text)")
                #expect(text.contains("KEPT(2)"), "\(name), \(view): \(text)")
            }
        }
    }

    /// A `)`, a `(` or a `"` in a comment is not counted, so the interpolation ends where Swift
    /// ends it: `KEPT(2)` on the next line is code in it, `KEPT(3)` after the literal is code, and
    /// the comment's own text, `GONE`, is read as no kind of code. A trailing comment is kept by
    /// `strippingComments`, which is the one view that may hold `GONE`.
    ///
    /// **Mutations**, each run with the comment skip taken out of `interpolationEnd`, one for each
    /// kind of comment: red here, by the issues the walker records when a `(` leaves the
    /// interpolation open or a `"` opens a literal inside a comment, and, for `// ))`, by the
    /// comment's tail read as code. Counted, the `))` ended the interpolation at the comment.
    @Test("A parenthesis or a quote in a comment does not end or open anything")
    func aCommentsPunctuationIsNotCounted() {
        let markers: [(comment: String, trailing: Bool)] = [
            ("// )) GONE", true), ("// ( GONE", true), ("// don't \"quote GONE", true),
            ("// \"\"\" GONE", true), ("/* ) GONE */", false), ("/* \" GONE */", false),
        ]
        for (comment, trailing) in markers {
            let source =
                "let s = \"\"\"\n    \\(f(1, \(comment)\n    KEPT(2)))\n    \"\"\"\nKEPT(3)"
            for (view, text) in Self.views(source) {
                #expect(text.contains("KEPT(2)"), "\(comment), \(view): \(text)")
                #expect(text.contains("KEPT(3)"), "\(comment), \(view): \(text)")
                if !trailing || view != "strippingComments" {
                    #expect(!text.contains("GONE"), "\(comment), \(view): \(text)")
                }
            }
        }
    }

    /// What is not a comment stays as it was: a `//` in a string inside an interpolation, a
    /// division, and an interpolation with nothing to strip, which every view copies unchanged.
    @Test("A comment marker in a string inside an interpolation, and a division, are code")
    func nothingElseIsStripped() {
        let untouched = [
            #"let s = "\(f("a // b", KEPT(1)))""#,
            #"let s = "\(a / b) \(c/d)""#,
            "let s = \"\"\"\n    \\(f(1,\n    KEPT(2)))\n    \"\"\"",
            #"let s = "\(flag ? "x" : "y//z")""#,
            #"let s = "\(String(describing: x)) http://example.com//path""#,
        ]
        for source in untouched {
            #expect(SeamScanner.strippingComments(source) == source, "\(source)")
            #expect(SeamScanner.strippingAllComments(source) == source, "\(source)")
        }
        let kept = SeamScanner.strippingAllComments(#"let s = "\(f("a // b", KEPT(1)))""#)
        #expect(kept.contains("a // b"), "\(kept)")
        let code = RuleZeroScan.code(of: #"let s = "\(f("a // b", KEPT(1)))""#)
        #expect(code.contains("KEPT(1)"), "\(code)")
        #expect(!code.contains("a // b"), "\(code)")
    }

    // MARK: - A carriage return

    /// Swift ends a line at `\n`, at `\r` and at `\r\n`. The walker ended a `//` comment at `\n`
    /// only, and `"\r\n"` is a single `Character` that is not `"\n"`. So after `// note\r` the code
    /// up to the next `\n` was a comment to it, and in a file with `\r\n` line ends the first
    /// comment ran to the end of the file, taking every scan's view of the rest with it.
    /// **A source with a carriage return is refused** rather than read, as one that ends inside a
    /// literal is: every `\n` test in the scans, in this walker and outside it, would otherwise
    /// need to know that `\r` and `\r\n` end a line too, and the tree has none to read.
    private static let carriageReturns: [(name: String, source: String)] = [
        ("a lone CR ends a comment", "// note\rlet helper = X.production(log: L())\nawait x()"),
        ("a CRLF ends a comment", "// note\r\nlet helper = X.production(log: L())\nawait x()"),
        ("a CR at the end", "let a = 1\r"),
        ("a CR in a multi-line literal", "let s = \"\"\"\r    text\r    \"\"\"\nawait x()"),
        ("a CR in a block comment", "/* a\rb */ let x = 1"),
        ("a CR in an interpolation", "let s = \"\"\"\n    \\(f(1,\r    2))\n    \"\"\""),
    ]

    /// **Mutation:** make `holdsCarriageReturn` look for `"\r"` as a `Character`, which `\r\n` is
    /// not. Run: red here, at the one source whose `\r` is part of a `\r\n`.
    @Test("The test for a carriage return finds one in every position and every spelling")
    func aCarriageReturnIsFound() {
        for (name, source) in Self.carriageReturns {
            #expect(SeamScanner.holdsCarriageReturn(source), "\(name)")
        }
        #expect(!SeamScanner.holdsCarriageReturn("let a = 1\nlet b = 2\n"))
    }

    /// The two shapes the issue names, through every view that reads source: each records an issue
    /// rather than returning what it read.
    ///
    /// **Mutation:** delete the call to `refuseCarriageReturns` in `strippingComments`. Run: red
    /// here, at every view of both.
    @Test("A source with a carriage return is refused by every view")
    func aCarriageReturnIsRefused() {
        for source in [Self.carriageReturns[0].source, Self.carriageReturns[1].source] {
            for read in [
                { _ = SeamScanner.strippingComments(source) },
                { _ = SeamScanner.strippingAllComments(source) },
                { _ = RuleZeroScan.code(of: source) },
            ] {
                withKnownIssue {
                    read()
                } matching: { issue in
                    issue.comments.contains { $0.rawValue.contains("carriage return") }
                }
            }
        }
    }

    /// The escape `\r` in a literal is two characters of source, and is no carriage return.
    @Test("The escape \\r in source text is not a carriage return")
    func theEscapeIsNotACarriageReturn() {
        let source = ##"let s = "a\rb"; let t = "\r\n"; let u = #"\r"#"##
        #expect(!SeamScanner.holdsCarriageReturn(source))
        #expect(SeamScanner.strippingComments(source) == source)
        #expect(SeamScanner.strippingAllComments(source) == source)
    }
}
