import Foundation
import Testing

/// `SeamScanner.writeVerbs(named:)`, put through fixtures rather than through the tree it scans.
///
/// The scan found a verb's parameter list with `\([^)]*\)`, which ends at the first `)` it
/// meets. A default value with a call in it — `under lease: UUID = UUID()` — carries one, so the
/// verb did not match and **dropped out of the population** `everyEngageVerbTakesAPermit` and
/// `everyTargetWriteVerbTakesAnAuthorisation` assert over. They stayed green on a signature that
/// gave the engage verb a second parameter, which is the shape ADR 0008 exists to forbid
/// ([#362](https://github.com/blamechris/Aeolus/issues/362)).
///
/// `WriteVerbAllowlistTests` still caught that mutation, and nothing here is exploitable: it is a
/// test-time guard on source shape. But a tripwire that a common Swift idiom evades is weaker than
/// it reads, and a tree that holds no such declaration today cannot show the scan handles one.
@Suite("The write-verb scan lists a verb whatever its parameter list holds")
struct SeamScannerWriteVerbTests {

    /// One declaration the scan must list, with the parameter clause it must report.
    struct Shape: Sendable, CustomTestStringConvertible {
        let name: String
        let source: String
        /// The text between the declaration's own parentheses, whitespace collapsed.
        let parameters: String

        var testDescription: String { name }
    }

    static let shapes: [Shape] = [
        Shape(
            name: "a default value that calls an initialiser",
            source: """
                func engageManualControl(of fan: CommandableFan, under lease: UUID = UUID()) \
                async throws
                """,
            parameters: "of fan: CommandableFan, under lease: UUID = UUID()"),
        Shape(
            name: "the same, one parameter to a line",
            source: """
                func engageManualControl(
                    of fan: CommandableFan,
                    under lease: UUID = UUID()
                ) async throws
                """,
            parameters: "of fan: CommandableFan, under lease: UUID = UUID()"),
        Shape(
            name: "the effects clause wrapped onto its own line",
            source: """
                func engageManualControl(of fan: CommandableFan, under lease: UUID = UUID())
                    async throws
                """,
            parameters: "of fan: CommandableFan, under lease: UUID = UUID()"),
        Shape(
            name: "a default value with parentheses nested two deep",
            source: """
                func engageManualControl(\
                of fan: CommandableFan, under lease: UUID = lease(UUID())) async throws
                """,
            parameters: "of fan: CommandableFan, under lease: UUID = lease(UUID())"),
        Shape(
            name: "a closure-typed parameter",
            source: """
                func engageManualControl(of fan: CommandableFan, while body: () async -> Void) \
                async throws
                """,
            parameters: "of fan: CommandableFan, while body: () async -> Void"),
        Shape(
            name: "a generic clause before a defaulted parameter",
            source: """
                func engageManualControl<Plane: FanControlling>(\
                of fan: CommandableFan, under lease: UUID = UUID()) async throws
                """,
            parameters: "of fan: CommandableFan, under lease: UUID = UUID()"),
        Shape(
            name: "a close parenthesis inside a string literal default",
            source: """
                func engageManualControl(of fan: CommandableFan, mark: String = ")") async throws
                """,
            parameters: #"of fan: CommandableFan, mark: String = ")""#),
        Shape(
            name: "an open parenthesis inside a string literal default",
            source: """
                func engageManualControl(of fan: CommandableFan, mark: String = "(") async throws
                """,
            parameters: #"of fan: CommandableFan, mark: String = "(""#),
        Shape(
            name: "an escaped quote and a parenthesis inside a string literal default",
            source: #"""
                func engageManualControl(of fan: CommandableFan, mark: String = "\")") async throws
                """#,
            parameters: #"of fan: CommandableFan, mark: String = "\")""#),
        Shape(
            name: "a comment marker and a parenthesis inside a string literal default",
            source: """
                func engageManualControl(
                    of fan: CommandableFan,
                    source: String = "https://example.invalid/("
                ) async throws
                """,
            parameters: #"of fan: CommandableFan, source: String = "https://example.invalid/(""#),
        Shape(
            name: "a trailing comment inside the list that holds a parenthesis",
            source: """
                func engageManualControl(
                    of fan: CommandableFan,  // the fan (see ADR 0008
                    under lease: UUID = UUID()
                ) async throws
                """,
            parameters: "of fan: CommandableFan, under lease: UUID = UUID()"),
        Shape(
            name: "a whole-line comment inside the list that holds a parenthesis",
            source: """
                func engageManualControl(
                    of fan: CommandableFan,
                    // a lease (optional), minted here when the caller passes none
                    under lease: UUID = UUID()
                ) async throws
                """,
            parameters: "of fan: CommandableFan, under lease: UUID = UUID()"),
    ]

    private func engageVerbs(_ source: String) throws -> [SeamScanner.Declaration] {
        try SeamScanner.writeVerbs(named: #"engage\w*"#, inSource: source, file: "Fixture.swift")
    }

    /// The acceptance criterion of #362, and the shapes beside it that the same `[^)]*` class
    /// drops. Each is a legal declaration the scan must list **with its whole parameter list**: a
    /// verb that is listed with the list cut short would be asserted against a signature that is
    /// not the one written.
    ///
    /// **Run: red on the `\([^)]*\)` scan** for ten of the twelve. Nine drop the verb outright;
    /// the closure-typed parameter is listed with its list cut at the closure's own `)`, and
    /// worse, because the closure's `async` then stands in for the verb's. The open-parenthesis
    /// literal and the comment-marker literal pass on it by luck of where the first `)` falls,
    /// and are here to keep the balanced scan honest about the same literals. **Run: the
    /// escaped-quote shape alone is red on balanced scanning that lets `closingParenthesis` end
    /// a literal at `\"`**; skipping the escaped character is what turns it green.
    @Test("A verb is listed with its whole parameter list", arguments: shapes)
    func listsTheVerbWithItsWholeParameterList(_ shape: Shape) throws {
        let found = try engageVerbs(shape.source)

        #expect(found.count == 1, "\(shape.name): found \(found.map(\.text))")
        #expect(
            found.first.map { SeamScanner.collapsingWhitespace($0.parameters) }
                == shape.parameters,
            "\(shape.name): the reported parameter list is not the one written")
    }

    /// What the permit-only assertion sees for the #362 signature. It splits the clause on `:`
    /// and demands exactly two parts, so a clause that survives the scan intact is a clause that
    /// fails the assertion — which is the whole point of listing the verb.
    @Test("The defaulted second parameter reaches the permit-only assertion")
    func theSecondParameterIsVisibleToThePermitCheck() throws {
        let found = try engageVerbs(
            """
            func engageManualControl(of fan: CommandableFan, under lease: UUID = UUID()) \
            async throws
            """)

        let parts = try #require(found.first).parameters
            .split(separator: ":", omittingEmptySubsequences: false)
        #expect(parts.count == 3, "the assertion expects exactly 2 parts for a lone permit")
    }

    /// The effects clause is still what makes a verb a *write* verb. A requirement with no
    /// `async` must not borrow the next declaration's, which an unanchored search for it would.
    @Test("A synchronous declaration does not borrow the next declaration's async")
    func aSynchronousDeclarationIsNotAWriteVerb() throws {
        let found = try engageVerbs(
            """
            protocol Plane {
                func engageManualControl(of fan: CommandableFan, under lease: UUID = UUID())
                func restoreToAutomatic() async throws
            }
            func engageManualControl(of fan: CommandableFan, under lease: UUID = UUID()) throws {}
            """)

        #expect(found.isEmpty, "found \(found.map(\.text))")
    }

    /// The name pattern is matched against the whole name, because the list must open straight
    /// after it. A pattern that is only a prefix of a longer name lists nothing, rather than
    /// reading `engageManualControl` as `engage` followed by something that is not a `(`.
    @Test("A name pattern that only prefixes a longer name lists nothing")
    func aPrefixOfALongerNameIsNotThatName() throws {
        let source = """
            func engageManualControl(of fan: CommandableFan) async throws {}
            func engage(of fan: CommandableFan) async throws {}
            """

        let found = try SeamScanner.writeVerbs(named: "engage", inSource: source, file: "F.swift")

        #expect(found.map(\.text) == ["func engage(of fan: CommandableFan) async throws"])
    }

    /// Two verbs side by side are two declarations, each with its own list. A scan that read
    /// from the first `(` to the last `)` of the file would report one, and a permit-only
    /// assertion over it would judge neither.
    @Test("Neighbouring verbs are listed separately")
    func neighbouringVerbsAreListedSeparately() throws {
        let found = try engageVerbs(
            """
            func engageManualControl(
                of fan: CommandableFan, under lease: UUID = UUID()
            ) async throws {}
            func engageManualControl(of fan: CommandableFan) async throws {}
            """)

        #expect(
            found.map { SeamScanner.collapsingWhitespace($0.parameters) } == [
                "of fan: CommandableFan, under lease: UUID = UUID()",
                "of fan: CommandableFan",
            ])
    }
}
