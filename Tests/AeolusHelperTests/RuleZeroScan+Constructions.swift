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
    private static let constructions: [(pattern: String, built: Built)] = [
        (productionMember, .composition),
        (#"(?<![A-Za-z0-9_.])SMCFanControlPlane\s*\("#, .plane),
        (#"(?<!func\s)(?<![A-Za-z0-9_.])supervisorPlane\s*\("#, .plane),
    ]

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
        let required = try? NSRegularExpression(
            pattern: #"try\s*#require\s*\(\s*!\s*$"#)
        let mention = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_.])"# + NSRegularExpression.escapedPattern(for: binding.name)
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
        let reads = try? NSRegularExpression(
            pattern: "^" + path + #"\s*\.\s*holdsWriteChannel(?![A-Za-z0-9_])"#)
        let isRequire =
            required?.firstMatch(in: before, range: NSRange(before.startIndex..., in: before))
            != nil
            && reads?.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
        return Construction(
            built: built, binding: binding.name,
            violation: isRequire ? nil : "its first later use is not the holdsWriteChannel require")
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
