import Foundation
import Testing

// Where a test builds a composition or a plane over the real SMC, and whether it requires the
// result to hold no write channel before anything else touches it. A sibling file of
// `RuleZeroScan` for length; `NotBuiltRequireTripwireTests` is the rule.
extension RuleZeroScan {

    /// What a construction builds, and so what its require reads.
    enum Built: Sendable, Equatable {
        /// `HelperComposition.production` — required through `.plane.holdsWriteChannel`.
        case composition
        /// `SMCFanControlPlane(…)` or `supervisorPlane(…)` — required through `.holdsWriteChannel`.
        case plane
    }

    /// One construction, and what the rule found about it.
    struct Construction: Sendable, Equatable {
        let built: Built
        /// The `let` it initialises, or `nil` when it initialises none.
        let binding: String?
        /// `nil` when the rule holds; otherwise why not.
        let violation: String?
    }

    /// The constructions the rule covers: the production factory, as a call **or** a value, on
    /// any receiver but `fanctl`'s two (`RuleZeroScan.productionMember`), and the real plane's two
    /// spellings. A declaration (`func production`) is not one.
    ///
    /// **An initialiser the scan cannot read exempts nothing.** There is no "this one is a fake"
    /// exemption to fall into: a construction outside every `let` it parsed is a violation, so a
    /// statement it misreads goes red rather than green (#436's review, B-1).
    ///
    /// The plane is a construction however its initialiser is spelled: `SMCFanControlPlane(…)`,
    /// `SMCFanControlPlane.init(…)`, and `.init(…)` behind a `SMCFanControlPlane` annotation
    /// (#436's delta review, B3).
    private static let constructions: [(pattern: String, built: Built)] = [
        (productionMember, .composition),
        (#"(?<![A-Za-z0-9_.])SMCFanControlPlane\s*(?:\(|\.\s*init(?![A-Za-z0-9_]))"#, .plane),
        (#"(?<=SMCFanControlPlane\s{0,4}\??\s{0,4}=\s{0,4})\.\s*init\s*\("#, .plane),
        (#"(?<!func\s)(?<![A-Za-z0-9_.])supervisorPlane\s*\("#, .plane),
    ]

    /// The one spelling the rule accepts, for a failure message: a statement of its own, the
    /// negation and nothing after it but the message.
    static func acceptedRequire(_ built: Built, _ name: String) -> String {
        "try #require(!\(name)\(built == .composition ? ".plane" : "").holdsWriteChannel, \"…\")"
    }

    /// Every construction in `code` — comments and strings already removed — judged by the rule:
    /// it is the whole initialiser of a `let`, and the first later mention of that `let` is
    /// `try #require(!<name>.plane.holdsWriteChannel …)` for a composition, or
    /// `try #require(!<name>.holdsWriteChannel …)` for a plane, with no `?` or `!` on the `try`.
    static func constructions(in code: String) throws -> [Construction] {
        let bindings = try letAndVarBindings(in: code)
        var found: [Construction] = []
        for (pattern, built) in constructions {
            let expression = try NSRegularExpression(pattern: pattern)
            for match in expression.matches(in: code, range: NSRange(code.startIndex..., in: code))
            {
                guard let at = Range(match.range, in: code) else { continue }
                found.append(judge(built, at: at, bindings: bindings, in: code))
            }
        }
        return found
    }

    private struct Binding {
        let keyword: String
        let name: String
        let initializer: Range<String.Index>
    }

    private static func judge(
        _ built: Built, at site: Range<String.Index>, bindings: [Binding], in code: String
    ) -> Construction {
        guard let binding = bindings.last(where: { $0.initializer.contains(site.lowerBound) })
        else {
            return Construction(built: built, binding: nil, violation: "it initialises no let")
        }
        guard binding.keyword == "let" else {
            return Construction(
                built: built, binding: binding.name, violation: "it initialises a var, not a let")
        }
        // A stored property is built once per suite instance and read by every test in it, in an
        // order Swift Testing does not promise, so no single require can be its first use (B2).
        if isStored(at: binding.initializer.lowerBound, in: code) {
            return Construction(
                built: built, binding: binding.name,
                violation: "it is a stored property, which no one require can guard")
        }
        // The whole initialiser: nothing may follow the call, or the binding is something else.
        if let close = callEnd(at: site, in: code) {
            let rest = code[code.index(after: close)..<binding.initializer.upperBound]
            if rest.contains(where: { !$0.isWhitespace }) {
                return Construction(
                    built: built, binding: binding.name,
                    violation: "the let is bound to something built from it, not to it")
            }
        }
        let path = built == .composition ? #"\s*\.\s*plane"# : ""
        // The `try` begins a statement — not an argument, an autoclosure or a `let`'s initialiser.
        let required = try? NSRegularExpression(
            pattern: #"(?:\A|[\n;}])[ \t]*try\s*#require\s*\(\s*!\s*\z"#)
        // `self.helper` and `Self.helper` are the binding too (B2).
        let name = NSRegularExpression.escapedPattern(for: binding.name)
        let mention = try? NSRegularExpression(
            pattern: #"(?:(?<![A-Za-z0-9_.])|(?<=[sS]elf\s{0,3}\.\s{0,3}))"# + name
                + #"(?![A-Za-z0-9_])"#)
        let after = NSRange(binding.initializer.upperBound..., in: code)
        guard let next = mention?.firstMatch(in: code, range: after),
            let named = Range(next.range, in: code)
        else {
            return Construction(
                built: built, binding: binding.name, violation: "it is never required")
        }
        let before = String(code[..<named.lowerBound])
        let tail = String(code[named.upperBound...])
        // The whole first argument is the negation: nothing may follow it but the message, so
        // `|| true`, `== false` and `&& x` are not the require (#436's delta review).
        let reads = try? NSRegularExpression(
            pattern: #"\A"# + path + #"\s*\.\s*holdsWriteChannel\s*[,)]"#)
        let isRequire =
            required?.firstMatch(in: before, range: NSRange(before.startIndex..., in: before))
            != nil
            && reads?.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
        guard isRequire else {
            return Construction(
                built: built, binding: binding.name,
                violation: "its first later use is not the holdsWriteChannel require; the "
                    + "accepted spelling is \(acceptedRequire(built, binding.name))")
        }
        // No brace opened since the binding is still open at the require: a require inside
        // `do {…} catch {}`, `withKnownIssue {…}`, an `if`, a closure or a `Task` can be swallowed
        // or skipped, and the test carries on to its drive (B1).
        // A conditional-compilation directive between them is a block too: `#if DEBUG` compiles
        // the require out of CI's `-c release`, and `#if false` out of everything (#436's final
        // review, S1).
        let between = code[binding.initializer.upperBound..<named.lowerBound]
        if between.range(
            of: #"(?m)^[ \t]*#(?:if|elseif|else|endif)\b"#, options: .regularExpression)
            != nil
        {
            return Construction(
                built: built, binding: binding.name,
                violation: "a conditional-compilation directive stands between it and its require, "
                    + "which can compile the require out; the accepted spelling is "
                    + "\(acceptedRequire(built, binding.name)), with no #if around it")
        }
        guard bracesBalance(between) else {
            return Construction(
                built: built, binding: binding.name,
                violation: "its require is inside a block the binding is not, which can swallow or "
                    + "skip it; the accepted spelling is \(acceptedRequire(built, binding.name)), "
                    + "at the binding's own depth")
        }
        return Construction(built: built, binding: binding.name, violation: nil)
    }

    /// Whether every `{` in `text` is closed in it, and no `}` closes one opened before it.
    private static func bracesBalance(_ text: Substring) -> Bool {
        var depth = 0
        for character in text {
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    /// Whether `position` sits directly in a type's body, or at file scope, rather than inside a
    /// function, an initialiser, an accessor or a closure: the innermost open brace before it is a
    /// `struct`, `class`, `enum`, `actor`, `extension` or `protocol` body, or there is none.
    static func isStored(at position: String.Index, in code: String) -> Bool {
        var open: [String.Index] = []
        var index = code.startIndex
        while index < position {
            if code[index] == "{" { open.append(index) }
            if code[index] == "}", !open.isEmpty { open.removeLast() }
            index = code.index(after: index)
        }
        guard let brace = open.last else { return true }
        let headerStart =
            code[..<brace].lastIndex { "{};".contains($0) }.map { code.index(after: $0) }
            ?? code.startIndex
        let header = String(code[headerStart..<brace])
        let typeBody = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])(?:struct|enum|actor|extension|protocol|"#
                + #"class(?!\s+(?:func|var|let)\b))\s+[A-Za-z_]"#)
        return typeBody?.firstMatch(in: header, range: NSRange(header.startIndex..., in: header))
            != nil
    }

    /// The `)` that closes the construction at `site`, or `nil` when it is a value and not a call:
    /// the plane's patterns include their `(`, and the factory's is the next non-space character.
    private static func callEnd(at site: Range<String.Index>, in code: String) -> String.Index? {
        let open: String.Index
        if let inside = code[site].firstIndex(of: "(") {
            open = inside
        } else if let next = code[site.upperBound...].firstIndex(where: { !$0.isWhitespace }),
            code[next] == "("
        {
            open = next
        } else {
            return nil
        }
        return SeamScanner.closingParenthesis(in: code, openingAt: open)
    }

    /// Every `let name =` and `var name =` in `code`, with the range of its initialiser: from the
    /// `=` to the newline that ends the statement outside every bracket.
    private static func letAndVarBindings(in code: String) throws -> [Binding] {
        let expression = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_.])(let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]*)?=(?!=)"#)
        var bindings: [Binding] = []
        for match in expression.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let whole = Range(match.range, in: code),
                let keyword = Range(match.range(at: 1), in: code),
                let name = Range(match.range(at: 2), in: code)
            else { continue }
            var depth = 0
            // The initialiser may start on the next line — swift-format breaks after `=` — so the
            // statement starts at its first non-blank character, never at the newline.
            var index = code[whole.upperBound...].firstIndex { !$0.isWhitespace } ?? code.endIndex
            while index < code.endIndex {
                let character = code[index]
                if "([{".contains(character) { depth += 1 }
                if ")]}".contains(character) {
                    if depth == 0 { break }
                    depth -= 1
                }
                if character == "\n", depth == 0 {
                    // A statement continues onto a line that begins with `.`, as a wrapped chain.
                    let rest = code[code.index(after: index)...].drop { $0 == " " }
                    if rest.first != "." { break }
                }
                index = code.index(after: index)
            }
            bindings.append(
                Binding(
                    keyword: String(code[keyword]), name: String(code[name]),
                    initializer: whole.upperBound..<index))
        }
        return bindings
    }
}
