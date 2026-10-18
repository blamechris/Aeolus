import Foundation
import Testing

/// The shared literal walker, `SeamScanner.copyDelimited`, on the spellings that put code where a
/// quote-counter reads prose, or prose where it reads code (#436's review). Each fixture is checked
/// through both strippers that use the walker: `strippingAllComments` keeps a literal's text, and
/// `strippingStringLiterals` drops it and keeps its interpolations.
@Suite("The shared string-literal walker")
struct SeamScannerLiteralTests {

    private static func code(_ source: String) -> String {
        WriteSeamTestIsolationTests.strippingStringLiterals(
            SeamScanner.strippingAllComments(source))
    }

    @Test("A raw literal holding a quote ends at its own delimiter, and the code after it is code")
    func aRawLiteralWithAQuoteEndsAtItsDelimiter() {
        let source = #"""
            let label = #"SMC "write path"#
            await helper.prepareWritePath() // a comment
            """#
        let code = Self.code(source)
        #expect(code.contains("await helper.prepareWritePath()"))
        #expect(!code.contains("write path"))
        #expect(!code.contains("a comment"))
        #expect(SeamScanner.strippingAllComments(source).contains(##"#"SMC "write path"#"##))
    }

    @Test("A call inside an interpolation is code")
    func anInterpolatedCallIsCode() {
        let source = #"print("prepared \(await helper.prepareWritePath())")"#
        let code = Self.code(source)
        #expect(code.contains("await helper.prepareWritePath()"))
        #expect(!code.contains("prepared"))
    }

    @Test("A quote inside an interpolation does not end the literal")
    func aQuoteInsideAnInterpolationDoesNotEndTheLiteral() {
        let source = #"""
            let text = "\(row["key"]) // still the literal"; await helper.bringUp()
            """#
        #expect(SeamScanner.strippingAllComments(source).contains("// still the literal"))
        let code = Self.code(source)
        #expect(code.contains("row["))
        #expect(code.contains("await helper.bringUp()"))
        #expect(!code.contains("still the literal"))
    }

    @Test("A literal with two hashes ends only at a quote followed by two")
    func aTwoHashLiteralEndsAtItsOwnDelimiter() {
        let source = ###"let s = ##"alpha "# beta \#(gamma) "##; await helper.bringUp()"###
        let code = Self.code(source)
        #expect(code.contains("await helper.bringUp()"))
        #expect(!code.contains("beta"), "\(code)")
        #expect(!code.contains("gamma"), "a one-hash escape is text in a two-hash literal: \(code)")
    }

    @Test("A multi-line raw literal holds quotes, backslashes and comment markers as text")
    func aMultiLineRawLiteralIsText() {
        let source = ####"""
            let block = #"""
                "quoted" \" \( not code ) // not a comment
                and \#(interpolated) code
                """#
            await helper.bringUp()
            """####
        let code = Self.code(source)
        #expect(code.contains("await helper.bringUp()"))
        #expect(code.contains("interpolated"))
        #expect(!code.contains("not code"))
        #expect(!code.contains("quoted"))
        #expect(SeamScanner.strippingAllComments(source).contains("// not a comment"))
    }

    @Test("A source that ends inside a literal or an interpolation is recorded, not truncated")
    func anUnterminatedLiteralIsRecorded() {
        withKnownIssue {
            _ = Self.code(#"let s = "never closed \(still open"#)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("ends inside") }
        }
        withKnownIssue {
            _ = Self.code(#"let s = #"never closed"#)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("ends inside") }
        }
    }

    @Test("A raw literal with an odd number of quotes and a comment marker is one literal")
    func aRawLiteralWithAnOddQuoteIsOneLiteral() {
        let source = #####"let probe = #"say "hi // x"#; await helper.bringUp() // trailing"#####
        let kept = SeamScanner.strippingAllComments(source)
        #expect(kept.contains(##"#"say "hi // x"#"##), "\(kept)")
        #expect(!kept.contains("trailing"))
        let code = Self.code(source)
        #expect(code.contains("await helper.bringUp()"), "\(code)")
        #expect(!code.contains("say"))
    }

    @Test("A regex literal, bare or extended, is text, and the code after it is code")
    func aRegexLiteralIsText() {
        let fixtures: [(source: String, literal: String)] = [
            (#"let r = /"/; await helper.bringUp() // trailing"#, #"/"/"#),
            (#"let r = #/a//b"/#; await helper.bringUp() // trailing"#, #"#/a//b"/#"#),
            (#"let r = ##/a/#b"/##; await helper.bringUp() // trailing"#, #"##/a/#b"/##"#),
            // S2: an extended regex whose text begins `//` is not a comment.
            (#"let r = #//a/#; await helper.bringUp() // trailing"#, #"#//a/#"#),
            (#"let r = /a\/"b/; await helper.bringUp() // trailing"#, #"/a\/"b/"#),
            (#"guard x.contains(/"/) else { return }; await helper.bringUp() // t"#, #"/"/"#),
            (#"return /a"b/ // trailing"# + "\nawait helper.bringUp()", #"/a"b/"#),
            (
                "let r = #/\n    a \" // b\n    /#\nawait helper.bringUp() // trailing",
                "#/\n    a \" // b\n    /#"
            ),
        ]
        for (source, literal) in fixtures {
            let kept = SeamScanner.strippingAllComments(source)
            #expect(kept.contains(literal), "\(source): \(kept)")
            #expect(!kept.contains("trailing"), "\(source): \(kept)")
            let code = Self.code(source)
            #expect(code.contains("await helper.bringUp()"), "\(source): \(code)")
            #expect(!code.contains(literal), "\(source): \(code)")
        }
    }

    @Test("An extended regex literal that never closes is recorded, not read as code")
    func anUnclosedRegexLiteralIsRecorded() {
        withKnownIssue {
            _ = SeamScanner.strippingAllComments("let r = #/never closed\nlet x = 1")
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("regex literal") }
        }
        withKnownIssue {
            _ = SeamScanner.strippingAllComments("let r = #/\nnever closed")
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("ends inside a regex literal") }
        }
    }

    /// Division is copied as code, character for character, including the unspaced kind and the
    /// one an unclosed bare `/` would be.
    @Test("Division is not a regex literal")
    func divisionIsNotARegexLiteral() {
        let sources = [
            "let half = total / 2", "let rate = count/seconds", "let q = (a + b)/2",
            "x /= 2", "let z = rows[0]/rows[1]", #"let s = "a"/b"#, "let w = (x)/y/z",
            "let v = -1/x",
        ]
        for source in sources {
            #expect(SeamScanner.strippingAllComments(source) == source)
        }
    }
}
