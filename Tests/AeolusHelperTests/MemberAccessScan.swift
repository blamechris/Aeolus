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
/// ## The four-space indent, and the gate that actually holds it
///
/// A member is recognised at exactly four spaces of indent. Nothing here enforces that —
/// **`swift format lint --recursive --strict Sources`, which CI runs, is the gate**, because
/// four-space indentation is `.swift-format`'s `indentation` setting rather than a rule of
/// Swift. A member written at any other indent is therefore invisible to this scan and red in
/// that gate, and the two facts are one sentence apart here because a scan whose precondition
/// is held somewhere else reads as though it held the precondition itself.
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
        var found: [Member] = []
        var lineStart = code.startIndex

        while true {
            let lineEnd = code[lineStart...].firstIndex(of: "\n") ?? code.endIndex
            if let member = member(in: code[lineStart..<lineEnd], keyword: keyword) {
                found.append(member)
            }
            guard lineEnd < code.endIndex else { break }
            lineStart = code.index(after: lineEnd)
        }
        return found
    }

    /// One line, classified — or `nil` when it declares nothing of the requested kind.
    ///
    /// `line` must be a slice of the whole file: a method's signature is parsed from
    /// `line.base`, because the formatter wraps a parameter list that does not fit and a
    /// line-local parse would key every wrapped declaration on an empty clause.
    static func member(in line: Substring, keyword: Keyword) -> Member? {
        guard line.hasPrefix("    "), !line.hasPrefix("     ") else { return nil }
        var tokens = line.drop(while: { $0 == " " }).split(separator: " ")
        var isPrivate = false

        while let token = tokens.first {
            let head = String(token.prefix { $0 != "(" })
            if token.hasPrefix("@") {
                dropAttribute(from: &tokens)
            } else if head == "private" || head == "fileprivate" {
                // `private(set)` leaves the getter internal, so only the bare form answers.
                if head.count == token.count { isPrivate = true }
                tokens.removeFirst()
            } else if ignorableModifiers.contains(head) {
                tokens.removeFirst()
            } else {
                break
            }
        }

        let introducers: Set<String> = keyword == .property ? ["let", "var"] : ["func"]
        guard tokens.count > 1, introducers.contains(String(tokens[0])) else { return nil }

        let name = tokens[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !name.isEmpty else { return nil }

        switch keyword {
        case .property:
            return Member(name: String(name), isPrivate: isPrivate, key: String(name))
        case .method:
            return Member(
                name: String(name), isPrivate: isPrivate,
                key: signature(named: String(name), after: name.endIndex, in: line.base))
        }
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

    /// The one line of `code` declaring `member`, trimmed, as the guard naming it spelled it.
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
    static func declaration(
        of member: String, in code: String, from file: String
    ) throws -> String {
        let matches =
            code
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains(member) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let reason =
            matches.isEmpty
            ? """
            is declared on none. A guard naming a member that has been renamed, moved to a \
            sibling file or respelled has to be re-stated there, or the entry is protecting \
            nothing
            """
            : """
            matches \(matches.count) of them: \(matches). This guard judges one line, so a \
            second — a nested type's member, or a second declaration of the same shape — \
            decides which of them is judged and leaves the other unguarded
            """

        return try #require(
            matches.count == 1 ? matches[0] : nil,
            "`\(member)` has to be declared on exactly one line of \(file), and \(reason).")
    }

    // MARK: - Parsing

    /// Drops one attribute from the head of the modifier run, counting parentheses rather than
    /// whitespace — see the type's doc comment for the spelling that made the difference.
    private static func dropAttribute(from tokens: inout [Substring]) {
        var depth = 0
        repeat {
            let token = tokens.removeFirst()
            depth += token.filter { $0 == "(" }.count
            depth -= token.filter { $0 == ")" }.count
        } while depth > 0 && !tokens.isEmpty
    }

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
