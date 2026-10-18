import Foundation
import Testing

// The calls `NotBuiltRequireTripwireTests` holds to a `.notBuilt` require, and the functions
// `WriteChannelReachTripwireTests` holds out of reach. A sibling file of `RuleZeroScan` for length.
extension RuleZeroScan {

    /// A call that writes once the plane can, and the path whose `writeCapability` must be required
    /// `.notBuilt` by the statement immediately before it.
    struct DrivenCall: Hashable, Sendable {
        /// `helper.bringUp`, `helper.signalTeardown.run`, `plane.restoreToAutomatic`.
        let call: String
        /// The first word of the receiver, whose binding says what was composed.
        let root: String
        /// `helper.plane` for a composition's verb, the receiver itself for a plane's.
        let guardPath: String
        let at: String.Index
    }

    /// `code` with no whitespace either side of a `.`, before a `(`, or inside `()`, so a call
    /// split across lines (`helper\n    .bringUp()`) is the spelling the patterns match.
    static func tightened(_ code: String) -> String {
        code.replacingOccurrences(of: #"\s*\.\s*"#, with: ".", options: .regularExpression)
            .replacingOccurrences(of: #"\s+\("#, with: "(", options: .regularExpression)
            .replacingOccurrences(of: #"\(\s+\)"#, with: "()", options: .regularExpression)
    }

    /// A receiver path: words joined by dots, not itself the tail of a longer path.
    private static let path = #"(?<![A-Za-z0-9_.])((?:[A-Za-z_]\w*\.)*?[A-Za-z_]\w*)"#

    /// The composition's verbs that write on a plane that can — bring-up runs the preparation
    /// step and reconciliation, the teardown runs the exit keystone, `apply` engages and commands
    /// — and the plane's own write verbs, which a hardware-gated test must never drive on a plane
    /// that can write.
    private static let compositionVerbs = [
        path + #"\.(bringUp|prepareWritePath|reconcileFans)\(\)"#,
        path + #"\.(signalTeardown\.run)\("#,
        path + #"\.(authority\.apply)\("#,
    ]
    private static let planeVerbs = [
        path + #"\.(restoreToAutomatic|engageManualControl|commandTarget)\("#,
        path + #"\.(prepareWritePath)\((?!\))"#,
    ]

    static func drivenCalls(in tightened: String) throws -> [DrivenCall] {
        var calls: [DrivenCall] = []
        for (patterns, isComposition) in [(compositionVerbs, true), (planeVerbs, false)] {
            for pattern in patterns {
                let expression = try NSRegularExpression(pattern: pattern)
                let range = NSRange(tightened.startIndex..., in: tightened)
                for match in expression.matches(in: tightened, range: range) {
                    guard let receiver = Range(match.range(at: 1), in: tightened),
                        let verb = Range(match.range(at: 2), in: tightened)
                    else { continue }
                    let path = String(tightened[receiver])
                    calls.append(
                        DrivenCall(
                            call: path + "." + tightened[verb],
                            root: String(path.split(separator: ".")[0]),
                            guardPath: isComposition ? path + ".plane" : path,
                            at: receiver.lowerBound))
                }
            }
        }
        return calls.sorted { $0.at < $1.at }
    }

    /// Whether the statement immediately before `call` — past its own `try` and `await` — is
    /// `#require(<guardPath>.writeCapability == .notBuilt …)`. An `#expect` does not count: it
    /// lets the test go on to drive the plane it has just found can write.
    static func isGuarded(_ call: DrivenCall, in tightened: String) -> Bool {
        var prefix = trimmingTrailingWhitespace(tightened[..<call.at])
        while let effect = ["await", "try"].first(where: { endsWithWord($0, prefix) }) {
            prefix = trimmingTrailingWhitespace(prefix.dropLast(effect.count))
        }
        guard prefix.last == ")", let open = openingParenthesis(closing: prefix) else {
            return false
        }
        guard trimmingTrailingWhitespace(prefix[..<open]).hasSuffix("#require") else {
            return false
        }
        let inner = prefix[prefix.index(after: open)..<prefix.index(before: prefix.endIndex)]
            .filter { !$0.isWhitespace }
        let expected = call.guardPath + ".writeCapability==.notBuilt"
        return inner == expected || inner.hasPrefix(expected + ",")
    }

    private static func trimmingTrailingWhitespace(_ text: Substring) -> Substring {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return text[..<end]
    }

    /// Whether `text` ends with `word` as a whole word.
    private static func endsWithWord(_ word: String, _ text: Substring) -> Bool {
        guard text.hasSuffix(word) else { return false }
        let start = text.index(text.endIndex, offsetBy: -word.count)
        guard start > text.startIndex else { return true }
        let before = text[text.index(before: start)]
        return !(before.isLetter || before.isNumber || before == "_")
    }

    private static func openingParenthesis(closing text: Substring) -> Substring.Index? {
        var depth = 0
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            if text[index] == ")" { depth += 1 }
            if text[index] == "(" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// The initialiser of the nearest `let root =` or `var root =` before `offset`, to the end of
    /// its statement, or `nil` when `root` is not bound in the file before it — a parameter, say.
    static func binding(
        of root: String, before offset: String.Index, in tightened: String
    ) throws -> String? {
        let pattern = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_.])(?:let|var)\s+"#
                + NSRegularExpression.escapedPattern(for: root)
                + #"(?![A-Za-z0-9_])\s*(?::[^=\n]*)?=(?!=)"#)
        let range = NSRange(tightened.startIndex..<offset, in: tightened)
        guard let last = pattern.matches(in: tightened, range: range).last,
            let matched = Range(last.range, in: tightened)
        else { return nil }

        var depth = 0
        var index = matched.upperBound
        while index < offset {
            let character = tightened[index]
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if character == "\n", depth <= 0 { break }
            index = tightened.index(after: index)
        }
        return String(tightened[matched.upperBound..<index])
    }

    /// Whether `call`'s receiver is bound, in this file, to a composition that builds nothing real.
    /// An unbound receiver — a parameter — is not.
    static func isBoundToAFake(_ call: DrivenCall, in tightened: String) throws -> Bool {
        guard let initializer = try binding(of: call.root, before: call.at, in: tightened) else {
            return false
        }
        return try composesAFake(initializer, in: tightened)
    }

    /// What builds the real plane, beyond what reaches a connection.
    static let realPlanePatterns =
        reachPatterns + [
            #"(?<![A-Za-z0-9_])SMCFanControlPlane\s*\("#,
            #"(?<![A-Za-z0-9_])supervisorPlane\s*\("#,
        ]

    /// Whether `initializer` composes something other than the real plane: it names nothing that
    /// builds one, and neither does the body of any function it calls that this file declares.
    /// One level, and this file only — a helper in another file that builds the real graph is not
    /// seen, which is why a hardware-gated file is never exempt.
    static func composesAFake(_ initializer: String, in tightened: String) throws -> Bool {
        if try realPlanePatterns.contains(where: { try count($0, in: initializer) > 0 }) {
            return false
        }
        let called = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])([A-Za-z_]\w*)\("#)
        let range = NSRange(initializer.startIndex..., in: initializer)
        for match in called.matches(in: initializer, range: range) {
            guard let name = Range(match.range(at: 1), in: initializer) else { continue }
            let callee = NSRegularExpression.escapedPattern(for: String(initializer[name]))
            let declaration = try NSRegularExpression(
                pattern: #"(?<![A-Za-z0-9_])func\s+"# + callee + #"(?![A-Za-z0-9_])"#)
            let whole = NSRange(tightened.startIndex..., in: tightened)
            for found in declaration.matches(in: tightened, range: whole) {
                guard let at = Range(found.range, in: tightened),
                    let open = tightened[at.upperBound...].firstIndex(of: "{")
                else { continue }
                let body = String(balanced(in: tightened, from: open))
                if try realPlanePatterns.contains(where: { try count($0, in: body) > 0 }) {
                    return false
                }
            }
        }
        return true
    }

    // MARK: - Functions that take a channel

    /// A function declared in a test file whose declaration names `SMCWriteChannel`.
    struct ChannelTaker: Hashable, Sendable {
        let path: String
        let name: String
        /// `private` or `fileprivate`: no other file can call it, so none can hand it a real one.
        let isPrivate: Bool
    }

    static func channelTakers(in file: File) throws -> [ChannelTaker] {
        let declaration = try NSRegularExpression(
            pattern:
                #"(?<![A-Za-z0-9_])((?:(?:@\w+(?:\([^)]*\))?|[a-z]+)[ \t]+)*)func\s+([A-Za-z_]\w*)"#
        )
        let code = file.code
        var takers: [ChannelTaker] = []
        for match in declaration.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let modifiers = Range(match.range(at: 1), in: code),
                let name = Range(match.range(at: 2), in: code)
            else { continue }
            let tail = code[name.upperBound...]
            let signature = tail[..<(tail.firstIndex(of: "{") ?? tail.endIndex)]
            guard signature.contains("SMCWriteChannel") else { continue }
            takers.append(
                ChannelTaker(
                    path: file.path, name: String(code[name]),
                    isPrivate: code[modifiers].contains("private")))
        }
        return takers
    }
}
