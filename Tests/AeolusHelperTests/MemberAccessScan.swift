import Foundation
import Testing

/// The member parse the access guards share: which files a type is written in, what its own
/// members are, and which of them are not `private` — read off the source rather than off a
/// call site.
///
/// It was written for `LeaseAuthorityAccessTests` when
/// [#128](https://github.com/blamechris/Aeolus/issues/128) split `LeaseAuthority.swift` and
/// five properties had to be widened for the second file to compile.
/// [#98](https://github.com/blamechris/Aeolus/issues/98) is the same split on
/// `HelperConnectionSession.swift` and needs the same guard, so the parse lives here and both
/// suites call it. Two copies that must agree is the arrangement `SeamScanner`'s own doc
/// comment records replacing, and this is a second instance of it, not an exception.
///
/// ## Why the modifiers are parsed rather than assumed absent
///
/// The first version of this classified a line by `hasPrefix("let ")` or `hasPrefix("var ")`
/// after trimming, which meant every declaration carrying an explicit modifier —
/// `internal var`, `package var`, `static var`, and worst of all `private(set) var` — was
/// skipped rather than checked. The widening an exhaustive guard exists to catch could
/// therefore be written in a spelling it could not see, and `private(set) var table` is the
/// exact worst case: an internal *getter* on the state that guard exists to keep unreadable.
/// `member(in:keyword:)` strips the modifier run instead, and treats `private(set)` as
/// internal because that is what its getter is.
///
/// A method is scanned for the same reason a property is. `WriteVerbAllowlistTests` filters
/// its population on `isAsync || mentions(anyOf: permits)`, and an actor's *synchronous*
/// isolated method is `async` only at the call site — that suite records the blind spot in its
/// own doc comment — so a synchronous internal method reaching private storage would be
/// reachable from every file in `AeolusHelper` and caught by nothing else.
///
/// ## Why an attribute is skipped by its parentheses rather than by its whitespace
///
/// The modifier walk dropped one whitespace-separated token per `@`, which is right for
/// `@objc` and for `@_spi(FanWrite)` and wrong for every attribute whose argument carries a
/// space. `@available(macOS 26.0, *) func reopenGate(force flag: Bool) { hasInvalidated =
/// false }` tokenises as `@available(macOS`, `26.0,`, `*)`, `func`, … — the walk stopped at
/// `26.0,`, `tokens[0]` was never `func`, and an internal synchronous method that reopens the
/// teardown gate dropped out of the population altogether while
/// `HelperConnectionSessionAccessTests` and `WriteVerbAllowlistTests` stayed green. That is
/// not a contrived spelling: `swift format lint --recursive --strict` accepts it on one line,
/// so the mutation was landable. The parenthesis depth is counted now
/// ([#236](https://github.com/blamechris/Aeolus/issues/236)).
///
/// ## Why a method carries a signature rather than a bare name
///
/// An acknowledged list keyed on the bare name cannot see a second method that reuses one.
/// `invalidate()` is acknowledged on `HelperConnectionSession`, and
/// `func invalidate(reopening: Bool) { hasInvalidated = false; negotiated = nil }` added
/// beside it — internal, synchronous, and reopening *both* gates — produced the identical key
/// `invalidate`, landed on the acknowledged entry, and left 38 tests in 4 suites green (#236).
/// `Member.key` carries the argument labels **and** the parameter types, for the reason
/// `SeamScanner.Function.key` records at length: a label-only key cannot see an overload
/// either, and that defect has already landed once in this repository.
///
/// ## Why a member carries its spelling, not just its key
///
/// `Member.key` is the name, or the name and parameter types: enough to tell two members apart,
/// and blind to how either is exposed. An acknowledged list keyed on it passes `public func
/// discardConnection` for `func discardConnection`, so a member acknowledged as `internal` could
/// be made callable from the app with every access test green
/// ([#604](https://github.com/blamechris/Aeolus/issues/604)). `Member.spelling` is the modifier
/// run, in source order and including any modifier-only line above, then the introducer, then
/// the key, and a list that holds it fails on a respelling as it does on a new member. What it
/// still cannot see is a modifier on the `extension` a member sits in, which is on no member's
/// line: `public extension HelperClient {` is `extensionHeaders(of:inTarget:)`'s.
///
/// ## The four-space indent, and the gate that actually holds it
///
/// A member is recognised at exactly four spaces of indent. Nothing here enforces that —
/// **`swift format lint --recursive --strict Sources`, which CI runs, is the gate**, because
/// four-space indentation is `.swift-format`'s `indentation` setting rather than a rule of
/// Swift. A member written at any other indent is therefore invisible to this scan and red in
/// that gate, and the two facts are one sentence apart here because a scan whose precondition
/// is held somewhere else reads as though it held the precondition itself.
///
/// **One spelling is the exception, and the formatter is not its gate:** a modifier alone on a
/// line, the declaration beneath it at eight spaces, is what `swift format` writes for a
/// declaration broken after its modifier, and it passes `--strict`. The declaration line is
/// read as a nested member and skipped, so a *new* member written so is in no population
/// ([#605](https://github.com/blamechris/Aeolus/issues/605)); an acknowledged one goes missing,
/// which an exact list notices. `MemberAccessScanSpellingTests` pins this as a limit.
enum MemberAccessScan {

    enum Keyword {
        case property
        case method
    }

    struct Member {
        /// The declared name, with no signature: what a failure message reads best as.
        let name: String
        let isPrivate: Bool
        /// What an acknowledged list is spelled in. `name` for a property, which cannot be
        /// overloaded; `name(label: Type, label: Type)` for a method, so that two methods
        /// sharing a name are two entries — see the type's doc comment for the mutation that
        /// made this necessary.
        let key: String
        /// The declaration as the scan reads it, for an acknowledged list that pins access exactly:
        /// the modifier run in source order — attributes, `public`, `private(set)`, and any
        /// modifier-only line above — then `let`, `var` or `func`, then `key`. So `public var
        /// negotiated`, `private(set) var interruptions`, and `nonisolated public func
        /// healthUpdates()`. A respelling is a different string by design: see the type's
        /// account of why a bare key could not see a widening.
        let spelling: String
    }

    /// Where a type's members may be written: its own declaration, and every extension of it.
    struct DeclarationSites {
        /// The files declaring the type itself — `actor`, `class`, `struct` or `enum`. More
        /// than one means two types share a name, which the callers of this assert against.
        let declarations: [String]
        /// Every file the type's members can be written in, sorted: the declaration and every
        /// extension of it.
        let members: [String]
    }

    /// The modifiers that may precede `let`/`var`/`func` without changing what is declared.
    ///
    /// `private` and `fileprivate` are handled separately because they are the answer, not
    /// noise. A modifier written with a parenthesised argument — `private(set)`,
    /// `nonisolated(unsafe)` — is matched on the part before the parenthesis, and
    /// `private(set)` deliberately does **not** count as private: it restricts the setter and
    /// leaves an internal getter on whatever it guards.
    static let ignorableModifiers: Set<String> = [
        "internal", "package", "public", "open", "static", "class", "final", "lazy", "weak",
        "unowned", "override", "mutating", "nonmutating", "dynamic", "distributed",
        "nonisolated", "isolated", "borrowing", "consuming", "indirect", "required",
        "convenience", "optional",
    ]

    /// Every file in `target` that `type`'s members can be written in, derived from the tree.
    ///
    /// A hand-listed file set is what #236 was filed about. Three files were named;
    /// `Sources/AeolusHelper/HelperConnectionSessionExtra.swift` declaring
    /// `extension HelperConnectionSession { func reopenTheGateSideways(…) }` was scanned by
    /// nothing, and left 8 tests in 2 suites green. Deriving the set makes *adding the file*
    /// the thing that fails, rather than remembering to list it — which is the same move
    /// `swiftFilesUnderTests()` exists for.
    ///
    /// The name is matched whole, so `extension HelperConnectionSessionGates` is a different
    /// type, and comments are stripped first, so the prose naming a file is not one. The two
    /// residual inaccuracies both fail loudly rather than quietly: a declaration inside a
    /// string literal adds a file to the set, and a file holding a *second* top-level type
    /// contributes that type's members to the caller's population.
    static func filesDeclaring(
        _ type: String, inTarget target: String
    ) throws -> DeclarationSites {
        let declaration = try NSRegularExpression(
            pattern: #"\b(?:actor|class|struct|enum)\s+\#(type)(?![A-Za-z0-9_])"#)
        let extending = try NSRegularExpression(
            pattern: #"\bextension\s+\#(type)(?![A-Za-z0-9_])"#)
        var declarations: [String] = []
        var members: [String] = []

        for url in try SeamScanner.swiftFiles(under: target) {
            let code = SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            let declares = declaration.firstMatch(in: code, range: range) != nil
            let extends = extending.firstMatch(in: code, range: range) != nil

            if declares { declarations.append(url.lastPathComponent) }
            if declares || extends { members.append(url.lastPathComponent) }
        }
        return DeclarationSites(declarations: declarations.sorted(), members: members.sorted())
    }

    /// Every member of the requested kind declared at a type's own member indent, across every
    /// file the type is written in.
    ///
    /// Scanning only the main file would let the next split widen a member simply by putting
    /// it in a second one — which is the move that made these guards necessary — so every file
    /// is read. A caller must therefore keep a second type out of the files it names, or the
    /// second type's members are counted as the first's, and must derive `files` from
    /// `filesDeclaring(_:inTarget:)` rather than list them, or a file added later is scanned
    /// by nothing.
    static func members(in files: [String], keyword: Keyword) throws -> [Member] {
        var found: [Member] = []
        for file in files {
            found += members(inSource: try strippedSource(of: file), keyword: keyword)
        }
        return found
    }

    /// `members(in:keyword:)`'s parse, over one file's text.
    ///
    /// Separated from the file resolution so `MemberAccessScanParsingTests` can put a fixture
    /// through it. A parser exercised only by the tree it scans is exercised only for the
    /// spellings already written there, which is exactly how #236's mutations were landable:
    /// no fixture named an attribute with a space in it, and none named two methods sharing a
    /// name, so nothing reported that neither could be seen.
    static func members(inSource code: String, keyword: Keyword) -> [Member] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.indices.compactMap { index in
            member(
                in: lines[index], preceded: precedingModifiers(above: index, in: lines),
                keyword: keyword)
        }
    }

    /// One line, classified — or `nil` when it declares nothing of the requested kind.
    ///
    /// `line` must be a slice of the whole file: a method's signature is parsed from
    /// `line.base`, because the formatter wraps a parameter list that does not fit and a
    /// line-local parse would key every wrapped declaration on an empty clause. `preceded` is the
    /// modifier tokens of the modifier-only lines directly above, which belong to this declaration
    /// and are read ahead of the line's own — see `MemberAccessScanModifiers.swift`.
    static func member(
        in line: Substring, preceded: [Substring] = [], keyword: Keyword
    ) -> Member? {
        guard line.hasPrefix("    "), !line.hasPrefix("     ") else { return nil }
        let written = preceded + line.drop(while: { $0 == " " }).split(separator: " ")
        var tokens = written
        let isPrivate = consumeModifiers(from: &tokens)
        let modifiers = written.dropLast(tokens.count).map(String.init)

        let introducers: Set<String> = keyword == .property ? ["let", "var"] : ["func"]
        guard tokens.count > 1, introducers.contains(String(tokens[0])) else { return nil }

        let name = tokens[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !name.isEmpty else { return nil }

        let key =
            keyword == .property
            ? String(name) : signature(named: String(name), after: name.endIndex, in: line.base)
        return Member(
            name: String(name), isPrivate: isPrivate, key: key,
            spelling: (modifiers + [String(tokens[0]), key]).joined(separator: " "))
    }

    /// One file's source with comments stripped, resolved by basename across `Sources`.
    ///
    /// **Exactly one** match is required. `first` was taken until #236, and the order
    /// `FileManager.enumerator` answers in is undefined — it is directory order, not
    /// alphabetical — so a second file of the same basename anywhere under `Sources` made
    /// every tripwire built on this read an arbitrary one of them. That is not a tie-breaking
    /// detail: with a decoy at `Sources/FanKit/HelperConnectionSession.swift` winning the
    /// order, all three of the connection session's stored properties were widened to
    /// `internal` and `HelperConnectionSessionAccessTests` passed all three of its tests.
    static func strippedSource(of file: String) throws -> String {
        let matches = try SeamScanner.swiftFiles().filter { $0.lastPathComponent == file }
        let url = try #require(
            matches.count == 1 ? matches[0] : nil,
            """
            \(file) has to name exactly one file under Sources, and names \(matches.count): \
            \(matches.isEmpty ? "none" : matches.map(\.path).sorted().joined(separator: ", ")). \
            This scan resolves a file by its basename in an undefined enumeration order, so a \
            duplicate makes it read an arbitrary one and pass while the file it names is \
            unguarded.
            """)
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// The declaration of `member`, as the guard naming it spelled it: the one line of `code`
    /// that contains it, trimmed, **behind any modifier-only lines directly above it**.
    ///
    /// Both suites name a handful of members whose privacy is load-bearing and judge the line
    /// each one is declared on. **Exactly one** line may contain the fragment, for the same
    /// reason `strippedSource(of:)` requires exactly one file: `first` answers a question with
    /// two answers without mentioning that it had a choice. `private var hasInvalidated =
    /// false` inside a nested type, written above the actor's own — now `internal` — `var
    /// hasInvalidated = false`, satisfied the prefix check and left
    /// `theSessionStateStaysPrivate` **green** with the teardown gate's input writable from
    /// every file in `AeolusHelper`. Only the exhaustive sibling assertion caught that, and the
    /// sibling is answered by adding a name to an acknowledged list, which is a thing
    /// maintainers do.
    ///
    /// Zero matches is the other direction, and was always checked: a guard naming a member
    /// that has been renamed away asserts nothing while still reading like protection.
    ///
    /// **The line above is part of the declaration** (#604). `nonisolated(unsafe)` alone on a
    /// line, then `    private(set) var interruptions: UInt64 = 0`, judged only the second line and
    /// passed an equality on it, with the first a modifier that rewinds the counter. The run is
    /// read as `MemberAccessScanModifiers.swift` describes, and joined to the line with a space, so
    /// the judged text is `nonisolated(unsafe) private(set) var interruptions: UInt64 = 0`.
    /// A caller that checks `hasPrefix("private ")` is red for the same modifier ahead of
    /// `private`, as it already was written on one line; the tree has no such line.
    ///
    /// **A trailing comment on the declaration line stays in the judged text**, because
    /// `SeamScanner.strippingComments` drops whole-line comments only. An equality fails
    /// closed on it, and a caller's message says to put the comment on the line above.
    static func declaration(
        of member: String, in code: String, from file: String
    ) throws -> String {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let matches = lines.indices.filter { lines[$0].contains(member) }
        let reason =
            matches.isEmpty
            ? """
            is declared on none. A guard naming a member that has been renamed, moved to a \
            sibling file or respelled has to be re-stated there, or the entry is protecting \
            nothing
            """
            : """
            matches \(matches.count) of them: \(matches.map { trimmed[$0] }). This guard \
            judges one line, so a second — a nested type's member, or a second declaration of \
            the same shape — decides which of them is judged and leaves the other unguarded
            """

        let index = try #require(
            matches.count == 1 ? matches[0] : nil,
            "`\(member)` has to be declared on exactly one line of \(file), and \(reason).")
        let modifiers = precedingModifiers(above: index, in: lines).map(String.init)
        return (modifiers + [trimmed[index]]).joined(separator: " ")
    }

    /// The accessor block of the member-indent `var name:` in `code`, braces included — or `nil`
    /// when the declaration reaches a `=` or a newline before any `{`, which is a stored one, or
    /// is not a `var` with a type annotation at all.
    ///
    /// The block is read whole, brace-matched from the declaration, so a `get { … } set { … }`
    /// pair or a `_modify` split across lines is seen by a caller scanning it. String literals
    /// are stepped over, so a `}` written inside one cannot close the block early and leave a
    /// `set` after it unread. `ReclamationWatchdogAccessTests` and
    /// `LeaseAuthorityRegistersAccessTests` both hold their views to it, so it lives here rather
    /// than in either.
    static func accessorBlock(of name: String, in code: String) throws -> String? {
        let declaration = try NSRegularExpression(
            pattern: #"(?m)^    (?:[^\s]+ )*var \#(name)\s*:"#)
        guard
            let match = declaration.firstMatch(
                in: code, range: NSRange(code.startIndex..., in: code)),
            let found = Range(match.range, in: code),
            let open = code[found.upperBound...].firstIndex(where: { "{=\n".contains($0) }),
            code[open] == "{"
        else { return nil }

        var depth = 0
        var index = open
        var skipped = ""
        while index < code.endIndex {
            if code[index] == "\"" {
                let delimiter = code[index...].hasPrefix("\"\"\"") ? "\"\"\"" : "\""
                index = SeamScanner.copyDelimited(
                    code, from: index, delimiter: delimiter, into: &skipped)
                continue
            }
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return String(code[open...index]) }
            }
            index = code.index(after: index)
        }
        return nil
    }

    // MARK: - Parsing

    /// `name(label: Type, label: Type)` for the method whose name ends at `nameEnd` in `code`.
    ///
    /// The parameter list is parsed out of the whole file rather than out of the declaring
    /// line, because the formatter wraps one that does not fit — `LeaseAuthority.acquireLease`
    /// and `HelperConnectionSession.acknowledgeRefusal` are both written that way — and a
    /// line-local parse would key those on an empty clause and collapse two of them onto one
    /// entry, reintroducing the defect the key exists to close.
    ///
    /// `SeamScanner`'s walkers do the work, so this key and `Function.key` are the same key on
    /// the same parse, and the limits they record apply here unchanged. A `func` that is not
    /// followed by a parameter list at all — one written inside a string literal at member
    /// indent, since `strippingComments` preserves literals — keys as `name(?)`, which no
    /// acknowledged list carries and so fails loudly rather than joining an existing entry.
    private static func signature(
        named name: String, after nameEnd: String.Index, in code: String
    ) -> String {
        guard let open = SeamScanner.parameterListStart(in: code, after: nameEnd),
            let close = SeamScanner.closingParenthesis(in: code, openingAt: open)
        else { return "\(name)(?)" }

        let clause = String(code[code.index(after: open)..<close])
        let parameters = SeamScanner.parameters(in: clause)
            .map { "\($0.label): \($0.type)" }
            .joined(separator: ", ")
        return "\(name)(\(parameters))"
    }
}
