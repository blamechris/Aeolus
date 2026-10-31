import Foundation
import Testing

/// How `MemberAccessScan` reads a line that is nothing but modifiers, when the modifier is an
/// attribute with an argument ([#604](https://github.com/blamechris/Aeolus/issues/604), and the
/// review of #606 that found the first scan to join these lines dropped members the base scan
/// saw).
///
/// An attribute's argument is free text: `message: "see https://example.com/issue"` holds a `//`
/// that is not a comment, and `message: "call f( instead"` holds a parenthesis that opens
/// nothing. A modifier line is therefore read outside string literals, has to close its own
/// parentheses, and is walked apart from the declaration line it sits above, so no spelling of
/// the line above can change what the declaration line itself parses as.
@Suite("MemberAccessScan reads a modifier line whole, whatever its attribute holds")
struct MemberAccessScanAttributeLineTests {

    @Test("An attribute alone on the line above, with a string argument, hides nothing below it")
    func anAttributeWithAStringArgumentDoesNotHideTheMemberBelow() {
        let fixture = """
            actor Probe {
                @available(*, deprecated, message: "see https://example.com/issue")
                public func hiddenBySlashes() {
                }

                @available(*, deprecated, message: "call f( instead")
                public func hiddenByParen() {
                }

                public func shownWithoutSlashes() {
                }

                func after() {
                }
            }
            """
        let methods = MemberAccessScan.members(inSource: fixture, keyword: .method)

        #expect(
            methods.map(\.name) == [
                "hiddenBySlashes", "hiddenByParen", "shownWithoutSlashes", "after",
            ],
            """
            the #606 review's fixture. Base saw all four. The first scan to join the lines above \
            cut the first attribute at the `//` inside its string and read the second one's `(` \
            as an attribute that never closes, and the unclosed attribute then consumed the \
            declaration beneath it, so a new member in this spelling left the population. Found \
            \(methods.map(\.name)).
            """
        )
        #expect(methods.map(\.isPrivate) == [false, false, false, false])
        #expect(
            methods.map(\.spelling) == [
                #"@available(*, deprecated, message: "see https://example.com/issue") "#
                    + "public func hiddenBySlashes()",
                #"@available(*, deprecated, message: "call f( instead") "#
                    + "public func hiddenByParen()",
                "public func shownWithoutSlashes()",
                "func after()",
            ])
    }

    @Test("A declaration whose attribute string holds a parenthesis lends its privacy to nothing")
    func anAttributeStringParenthesisDoesNotCarryOnIntoTheNextMember() {
        let fixture = """
            actor Probe {
                @available(*, message: "a (") private func old() {
                }
                func shown() {
                }
                @available(*, message: "see https://example.com/issue") private func older() {
                }
                func alsoShown() {
                }
            }
            """
        let methods = MemberAccessScan.members(inSource: fixture, keyword: .method)

        #expect(
            methods.map { "\($0.name):\($0.isPrivate)" } == [
                "old:true", "shown:false", "older:true", "alsoShown:false",
            ],
            """
            a line that holds a declaration is not a modifier line, whatever its attribute \
            argument contains. Read as one, `old` would lend its `private` to `shown` and \
            `older` to `alsoShown`, which fails open: a non-private member judged private. \
            Found \(methods.map { "\($0.name):\($0.isPrivate)" }).
            """
        )
    }

    @Test("A modifier line handed in cannot change what the declaration line parses as")
    func aModifierLineAboveCannotConsumeTheDeclarationBelow() throws {
        let code = "actor Probe {\n    public func widened() {\n    }\n}"
        let line = try #require(code.split(separator: "\n").dropFirst().first)
        let unclosed = ["@available(*,", "deprecated,"] as [Substring]

        let member = MemberAccessScan.member(in: line, preceded: unclosed, keyword: .method)

        #expect(
            member?.name == "widened",
            """
            the tokens of a modifier line above are walked apart from the line's own, so an \
            attribute they leave open ends with them and does not reach `public func widened()`. \
            Walked together, it consumed the declaration and the member left the population. \
            Found \(String(describing: member?.name)).
            """
        )
        #expect(member?.isPrivate == false)
    }

    @Test("A line that leaves a parenthesis open is not a modifier line; one that closes it is")
    func aModifierLineHasToCloseItsParentheses() {
        func tokens(_ line: Substring) -> [String]? {
            MemberAccessScan.modifierOnlyTokens(of: line)?.map(String.init)
        }

        #expect(tokens(#"    @available(*, message: "a","#) == nil)
        #expect(
            tokens(#"    @available(*, message: "a (")"#) == [
                "@available(*,", "message:", #""a"#, #"(")"#,
            ])
        #expect(tokens("    nonisolated(unsafe)  // why") == ["nonisolated(unsafe)"])
        #expect(tokens(#"    @available(*, message: "see https://x.y") public"#)?.last == "public")
        #expect(
            tokens(#"    @available(*, message: "say \"hi\" (") private func old() {"#) == nil,
            """
            a line that holds a declaration is not a modifier line, and an attribute left open \
            would consume it: an escaped quote does not end the string, and the `(` inside it \
            does not open anything.
            """
        )
    }

    @Test("A modifier above an attribute wrapped over lines is not reached, and the run ends")
    func aWrappedAttributeEndsTheRun() {
        let fixture = """
            actor Probe {
                public
                @available(
                    macOS 26.0, *
                )
                nonisolated
                func widened() {
                }
            }
            """
        let methods = MemberAccessScan.members(inSource: fixture, keyword: .method)

        #expect(
            methods.map(\.spelling) == ["nonisolated func widened()"],
            """
            stated rather than implied: a line whose parentheses do not close ends the run, so \
            `nonisolated` joins `func widened()` and the `public` above the wrapped attribute \
            does not. Joining an attribute left open would let it consume what follows it. \
            Found \(methods.map(\.spelling)).
            """
        )
    }

    @Test("An attribute above a named member stays in its judged text, so a caller is red")
    func anAttributeAboveTheJudgedDeclarationFailsAClosedCaller() throws {
        let code = """
            actor Probe {
                @available(*, deprecated, message: "see https://example.com/issue")
                private var counter = 0
                @available(*, deprecated, message: "call f( instead")
                private var other = 0
            }
            """
        let counter = try MemberAccessScan.declaration(
            of: "var counter = 0", in: code, from: "Probe.swift")
        let other = try MemberAccessScan.declaration(
            of: "var other = 0", in: code, from: "Probe.swift")

        #expect(
            counter
                == #"@available(*, deprecated, message: "see https://example.com/issue") "#
                + "private var counter = 0")
        #expect(
            other
                == #"@available(*, deprecated, message: "call f( instead") "#
                + "private var other = 0")
        #expect(
            !counter.hasPrefix("private ") && !other.hasPrefix("private "),
            """
            the suites that check `hasPrefix("private ")` are red for a modifier ahead of \
            `private`, on one line or on the line above, whatever the attribute's string \
            contains. Read otherwise they would go green on a line they cannot read. Found \
            \(counter) and \(other).
            """
        )
    }
}
