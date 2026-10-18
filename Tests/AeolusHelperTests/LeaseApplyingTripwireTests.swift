import Foundation
import Testing

/// `LeaseApplying`, the role through which the privilege boundary reaches level 6 (ADR 0014's A6
/// PR-3 amendment), carries one verb, takes no permit, and is reached only from
/// `SupervisedFanAuthority.swift`.
///
/// Claims about what a protocol declares and where a name is written, which no behavioural test
/// observes: a role widened by an extension, refined into a second protocol, or a verb called from
/// a second file passes every scenario, because the scenarios call only what the authority calls.
/// So they are asserted against the source, by census (`RoleCensus`, #402):
///
/// - **The role declares exactly one requirement and refines only `Sendable`.** No permit type
///   appears in it: the authority hands it the client's settings, the lease and the connection,
///   which is what a decoded message carries.
/// - **The role's name is written only where it is listed:** its declaration, `LeaseApplier`'s
///   conformance, and the authority's stored property and initialiser parameter. An extension, a
///   refinement, a second conformer, an alias and a cast all have to write it.
/// - **The verb is called only where it is listed.** In the helper, `apply` is spelled at its
///   declarations, at the authority's one call through the role, and at the session's one call
///   through its `FanAuthority`; nowhere else. A conversion inside the authority's file is
///   `AuthorityRoleTripwireTests.theAuthorityHoldsNoPlane`'s.
@Suite("The role the boundary reaches level 6 through", .timeLimit(.minutes(1)))
struct LeaseApplyingTripwireTests {

    static let rolePath = "AeolusHelper/Control/LeaseApplying.swift"
    static let roleFile = "LeaseApplying.swift"
    static let levelSixPath = "AeolusHelper/Control/LeaseApplier.swift"
    static let authorityPath = "AeolusHelper/SupervisedFanAuthority.swift"

    /// Every statement under `Sources/` that may write the role's name.
    static let roleListings = [
        RoleCensus.Listing(path: rolePath, statement: "protocol LeaseApplying: Sendable"),
        RoleCensus.Listing(
            path: levelSixPath,
            statement: "actor LeaseApplier<Plane: FanControlPlane>: LeaseApplying"),
        RoleCensus.Listing(path: authorityPath, statement: "let control: any LeaseApplying"),
        RoleCensus.Listing(path: authorityPath, statement: "control: some LeaseApplying"),
    ]

    /// Every statement in the helper's code that writes `apply`, string literals blanked: each
    /// declaration, and the verb's two calls. The session calls its `FanAuthority`'s `apply`, and
    /// the authority calls its role's; nothing else calls either.
    static let verbListings = [
        RoleCensus.Listing(path: "AeolusHelper/FanAuthority.swift", statement: "func apply"),
        RoleCensus.Listing(
            path: "AeolusHelper/ReadOnlyFanAuthority.swift", statement: "func apply"),
        RoleCensus.Listing(path: authorityPath, statement: "func apply"),
        RoleCensus.Listing(path: authorityPath, statement: "try await control.apply"),
        RoleCensus.Listing(path: rolePath, statement: "func apply"),
        RoleCensus.Listing(path: levelSixPath, statement: "func apply"),
        RoleCensus.Listing(path: "AeolusHelper/HelperXPCService.swift", statement: "func apply"),
        RoleCensus.Listing(
            path: "AeolusHelper/HelperXPCService.swift",
            statement: "[session] in await session.apply"),
        RoleCensus.Listing(
            path: "AeolusHelper/HelperConnectionSessionMessages.swift", statement: "func apply"),
        RoleCensus.Listing(
            path: "AeolusHelper/HelperConnectionSessionMessages.swift",
            statement: "try await authority.apply"),
    ]

    /// **Mutation:** add `func cycle() async` to `LeaseApplying`, with an empty `cycle()` on
    /// `LeaseApplier` and on the test target's `NoLevelSix` so the target builds. Run: red here, on
    /// the body. **Mutation:** make it
    /// `protocol LeaseApplying: Actor`. Run: red here, on the header.
    @Test("The role declares exactly one requirement, takes no permit, and refines only Sendable")
    func theRoleDeclaresExactlyOneRequirement() throws {
        let code = SeamScanner.strippingAllComments(
            try MemberAccessScan.strippedSource(of: Self.roleFile))
        let declaration = try #require(
            code.range(
                of: #"protocol LeaseApplying(?![A-Za-z0-9_])[^{]*\{[\s\S]*?\n\}"#,
                options: .regularExpression),
            "\(Self.roleFile) does not declare the role")
        let text = String(code[declaration])
        let open = try #require(text.firstIndex(of: "{"))
        let header = SeamScanner.collapsingWhitespace(String(text[..<open]))
        // Whitespace collapsed and then tightened inside the parentheses, so the line the
        // formatter breaks the signature at is not part of what is pinned.
        let body = SeamScanner.collapsingWhitespace(
            String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        )
        .replacingOccurrences(of: "( ", with: "(").replacingOccurrences(of: " )", with: ")")

        #expect(
            header == "protocol LeaseApplying: Sendable",
            "`\(header)`: the role refines `Sendable` and nothing else")
        #expect(
            body
                == """
                func apply(_ settings: [FanSetting], leaseID lease: UUID, from connection: \
                ConnectionID) async throws
                """,
            """
            the role declares `\(body)`. It carries level 6's one verb and no permit; a second \
            requirement is a second thing a decoded client message can reach.
            """)
    }

    /// **Mutation:** add `extension LeaseApplying { func probe() {} }` to `LeaseApplier.swift`.
    /// Run: red here, at that line. **Mutation:** add `protocol WiderApplying: LeaseApplying {}`
    /// to `LeaseApplying.swift`. Run: red here.
    @Test("The role's name is written under Sources only where it is listed")
    func theRoleIsNamedOnlyWhereListed() throws {
        let verdict = RoleCensus.reconcile(
            try RoleCensus.occurrences(roles: ["LeaseApplying"]), with: Self.roleListings)
        #expect(
            verdict.unlisted.isEmpty,
            """
            The role is named where it is not listed:\(Self.lines(verdict.unlisted))
            An extension, a refinement, a conformer, an alias or a cast widens what the privilege \
            boundary can reach of level 6. Say why here and in ADR 0014.
            """)
        #expect(verdict.missing.isEmpty, "Listed and not found:\(Self.lines(verdict.missing))")
    }

    /// **Mutation:** add `func probe(_ settings: [FanSetting], _ lease: UUID, _ connection:
    /// ConnectionID) async throws { try await leaseApplier.apply(settings, leaseID: lease, from:
    /// connection) }` to `HelperComposition`, with `import Foundation`. Run: red here, at that
    /// line.
    @Test("The verb is called in the helper only from the authority and the session")
    func theVerbIsCalledOnlyWhereListed() throws {
        let verdict = RoleCensus.reconcile(
            try Self.verbOccurrences(underTarget: "AeolusHelper"), with: Self.verbListings)
        #expect(
            verdict.unlisted.isEmpty,
            """
            `apply` is written in the helper where it is not listed:\(Self.lines(verdict.unlisted))
            Level 6's verb is reached only from SupervisedFanAuthority.swift, after the shutdown \
            refusal; a second caller is a second route from a decoded message to a write.
            """)
        #expect(verdict.missing.isEmpty, "Listed and not found:\(Self.lines(verdict.missing))")
    }

    /// The census above reads code, not prose: a word in a string literal, on one line or many,
    /// raw or not, is not a spelling of the verb, and a call is one however it is spaced, an
    /// interpolation's included. A raw literal's `"` does not end it, so a call after one is code.
    ///
    /// **Mutation:** make `blankingStringLiterals(_:)` return `code` unchanged. Run: red here, on
    /// the literals. **Mutation:** in `blankingProse(of:hashes:)`, blank an interpolation's code
    /// as prose. Run: red here, on the interpolated calls. **Mutation:** in
    /// `blankingStringLiterals(_:)`, count no `#` (`let hashes = 0`). Run: red here, the call after
    /// the raw literal blanked. **Mutation:** skip no raw escape when looking for the literal's end
    /// (`step` always 1). Run: red here, the call after `\#"` blanked.
    @Test("The verb census blanks string literals and keeps every call")
    func theVerbCensusReadsCodeNotProse() {
        let source = ###"""
            let refused = "level 6's apply was refused"
            log("""
                the apply in flight
                """)
            try await control . apply(settings)
            let detail = "an \"apply\" quoted"
            try await other.apply(settings)
            let note = "\(try await hidden.apply(settings)) and a \\(apply) escaped"
            let raw = #"say " hi"#
            try await sneaky.apply(settings)
            let prose = ##"an "# apply"##
            let rawNote = #"\#(try await rawHidden.apply(settings)) and \(apply) as text"#
            let escaped = #"say \#"# hi"#
            try await sneakier.apply(settings)
            """###
        let found = RoleCensus.occurrences(
            inSource: Self.blankingStringLiterals(RoleCensus.code(of: source)), path: "Probe.swift",
            roles: ["apply"])
        #expect(
            found.map(\.statement) == [
                // A blanked literal is whitespace, so the walk back from a call can cross it to the
                // declaration it sat in: the statement names the call either way.
                "try await control . apply", "let detail = try await other.apply",
                "let note = try await hidden.apply", "let raw = try await sneaky.apply",
                "let rawNote = try await rawHidden.apply",
                "let escaped = try await sneakier.apply",
            ],
            "the census read \(found.map(\.statement))")
        #expect(
            found.map(\.line) == [5, 7, 8, 10, 12, 14],
            "a blanked literal moved the lines: \(found)")
    }

    /// Every spelling of `apply` in `target`'s code, string literals blanked, by path and then
    /// position.
    static func verbOccurrences(underTarget target: String) throws -> [RoleCensus.Occurrence] {
        let root = SeamScanner.sourcesRoot.path + "/"
        var found: [RoleCensus.Occurrence] = []
        for file in try SeamScanner.swiftFiles(under: target).sorted(by: { $0.path < $1.path }) {
            let path =
                file.path.hasPrefix(root) ? String(file.path.dropFirst(root.count)) : file.path
            let code = Self.blankingStringLiterals(
                RoleCensus.code(of: try String(contentsOf: file, encoding: .utf8)))
            found += RoleCensus.occurrences(inSource: code, path: path, roles: ["apply"])
        }
        return found
    }

    /// `code` with the prose of every string literal replaced by spaces, its newlines kept, so a
    /// word in prose is not read as a spelling of the verb. An interpolation's code is kept: a call
    /// inside `\( … )`, or `\#( … )` in a raw literal, is still a call.
    ///
    /// An ordinary literal's end is found by `SeamScanner.copyDelimited`, the walker every scan
    /// here shares, with its limit: a `"` inside an interpolation ends the literal early, and what
    /// follows is read as code. A raw literal, `#"…"#`, `##"…"##` and their `"""` forms, ends only
    /// at its quotes followed by as many `#` as opened it, so a `"` inside it hides nothing, and a
    /// raw escape, a `\` with those `#` and one character after (`\#"` in a `#` literal), is text
    /// and never its end.
    static func blankingStringLiterals(_ code: String) -> String {
        var output = ""
        var index = code.startIndex
        while index < code.endIndex {
            let hashes = code[index...].prefix { $0 == "#" }.count
            let quote = code.index(index, offsetBy: hashes)
            guard quote < code.endIndex, code[quote] == "\"" else {
                // Not a literal: a `#` of `#expect` or `#if`, or any other character.
                let next = hashes > 0 ? quote : code.index(after: index)
                output += code[index..<next]
                index = next
                continue
            }
            let delimiter = code[quote...].hasPrefix("\"\"\"") ? "\"\"\"" : "\""
            if hashes == 0 {
                var literal = ""
                index = SeamScanner.copyDelimited(
                    code, from: index, delimiter: delimiter, into: &literal)
                output += Self.blankingProse(of: literal)
            } else {
                let closing = delimiter + String(repeating: "#", count: hashes)
                let escape = "\\" + String(repeating: "#", count: hashes)
                var end = code.index(quote, offsetBy: delimiter.count)
                while end < code.endIndex, !code[end...].hasPrefix(closing) {
                    let step = code[end...].hasPrefix(escape) ? escape.count + 1 : 1
                    end = code.index(end, offsetBy: step, limitedBy: code.endIndex) ?? code.endIndex
                }
                end =
                    code.index(end, offsetBy: closing.count, limitedBy: code.endIndex)
                    ?? code.endIndex
                output += Self.blankingProse(of: String(code[index..<end]), hashes: hashes)
                index = end
            }
        }
        return output
    }

    /// One literal, delimiters included, as spaces with its newlines kept, except the code inside
    /// each interpolation. An escape is a `\` and as many `#` as the literal's delimiter carries,
    /// then one character: so `\\(` is an escaped backslash and not an interpolation, a line
    /// continuation keeps its newline, and in a raw literal a lone `\` is prose.
    static func blankingProse(of literal: String, hashes: Int = 0) -> String {
        let escape = "\\" + String(repeating: "#", count: hashes)
        var output = ""
        var depth = 0
        var index = literal.startIndex
        while index < literal.endIndex {
            let character = literal[index]
            let after =
                literal.index(index, offsetBy: escape.count, limitedBy: literal.endIndex)
                ?? literal.endIndex
            if depth > 0 {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                output.append(depth > 0 ? character : " ")
                index = literal.index(after: index)
            } else if literal[index...].hasPrefix(escape), after < literal.endIndex {
                depth = literal[after] == "(" ? 1 : 0
                output += String(repeating: " ", count: escape.count)
                output.append(literal[after] == "\n" ? "\n" : " ")
                index = literal.index(after: after)
            } else {
                output.append(character == "\n" ? "\n" : " ")
                index = literal.index(after: index)
            }
        }
        return output
    }

    private static func lines(_ items: [some CustomStringConvertible]) -> String {
        items.map { "\n  \($0)" }.joined()
    }
}
