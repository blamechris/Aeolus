import Foundation
import Testing

/// The member parse the access guards share: what a type's own members are, and which of them
/// are not `private`, read off the source rather than off a call site.
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
enum MemberAccessScan {

    enum Keyword {
        case property
        case method
    }

    struct Member {
        let name: String
        let isPrivate: Bool
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

    /// Every member of the requested kind declared at a type's own member indent, across every
    /// file the type is written in.
    ///
    /// Four spaces is that indent. Scanning only the main file would let the next split widen
    /// a member simply by putting it in a second one — which is the move that made these
    /// guards necessary — so every file is read. A caller must therefore keep a second type
    /// out of the files it names, or the second type's members are counted as the first's.
    static func members(in files: [String], keyword: Keyword) throws -> [Member] {
        var found: [Member] = []
        for file in files {
            let code = try strippedSource(of: file)
            for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let member = member(in: line, keyword: keyword) else { continue }
                found.append(member)
            }
        }
        return found
    }

    /// One line, classified — or `nil` when it declares nothing of the requested kind.
    static func member(in line: Substring, keyword: Keyword) -> Member? {
        guard line.hasPrefix("    "), !line.hasPrefix("     ") else { return nil }
        var tokens = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        var isPrivate = false

        while let token = tokens.first {
            let head = String(token.prefix { $0 != "(" })
            if token.hasPrefix("@") {
                tokens.removeFirst()
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
        return Member(name: String(name), isPrivate: isPrivate)
    }

    static func strippedSource(of file: String) throws -> String {
        let url = try #require(
            SeamScanner.swiftFiles().first { $0.lastPathComponent == file },
            "\(file) is not in the source tree")
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }
}
