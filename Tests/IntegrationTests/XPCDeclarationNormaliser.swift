import Foundation

/// Reads a protocol declaration out of Swift source and reduces it to a form that changes
/// when the contract changes and not when the formatter runs.
///
/// A deliberately small parser, and the reason it is not `SeamScanner` is target boundaries:
/// that scanner lives in `AeolusHelperTests` and this suite cannot import it. Only the
/// comment-stripping loop is genuinely duplicated; the rest — brace matching to a protocol
/// body, whitespace canonicalisation, selector inference — has no counterpart there.
enum XPCDeclarationNormaliser {

    // MARK: - Extraction

    /// Everything between the braces of `protocol <name> { … }`, comments already gone.
    ///
    /// `nil` when the declaration is not in this source at all, which is a failure the
    /// caller must surface: a guard that quietly finds nothing to check passes forever.
    static func protocolBody(named name: String, in source: String) -> String? {
        let code = strippingComments(source)
        guard let declaration = declarationRange(ofProtocolNamed: name, in: code),
            let open = code[declaration.upperBound...].firstIndex(of: "{"),
            let close = closingBrace(in: code, openingAt: open)
        else { return nil }
        return String(code[code.index(after: open)..<close])
    }

    /// The range of `protocol <name>`, with the name required to end where it says it does.
    ///
    /// An unanchored prefix match takes the first occurrence, so a longer name sharing the
    /// prefix — `protocol AeolusXPCProtocolPrivileged` declared above the real one — would
    /// be fingerprinted in its place. The consequence is a loud mismatch rather than a
    /// vacuous pass, but the failure would list the wrong protocol's methods and send the
    /// reader after a change that did not happen, so the match is anchored here instead.
    private static func declarationRange(
        ofProtocolNamed name: String, in code: String
    ) -> Range<String.Index>? {
        var searchStart = code.startIndex
        while let found = code.range(of: "protocol \(name)", range: searchStart..<code.endIndex) {
            let following = found.upperBound < code.endIndex ? code[found.upperBound] : " "
            if !isIdentifierCharacter(following) { return found }
            searchStart = found.upperBound
        }
        return nil
    }

    /// One normalised signature per `func` in the body, plus anything the body carries
    /// before the first one.
    ///
    /// A protocol requirement has no body, so each declaration simply runs to the next
    /// declaration or to the end — no statement parsing required, and a `func` that turned
    /// up somewhere unexpected produces a signature that fails the pin loudly rather than
    /// vanishing from it.
    ///
    /// A declaration starts at the beginning of the line its `func` sits on, not at the
    /// `func` keyword, so `@objc optional func …` and `static func …` are inside the
    /// fingerprinted text. Text above the first declaration's line — a property
    /// requirement, or an attribute written on a line of its own — is emitted as an extra
    /// entry rather than dropped: it is not a signature, it fails the pin, and that is the
    /// point. Only whitespace is discarded.
    ///
    /// The residual: a modifier written on the line *above* a later `func` still lands in
    /// the preceding declaration's slice. It is fingerprinted, so the change goes red; the
    /// failure message names the method above it.
    static func normalisedDeclarations(inProtocolBody body: String) -> [String] {
        let starts = declarationStarts(inProtocolBody: body)

        var declarations: [String] = []
        let preamble = normalised(String(body[body.startIndex..<(starts.first ?? body.endIndex)]))
        if !preamble.isEmpty { declarations.append(preamble) }

        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : body.endIndex
            declarations.append(normalised(String(body[start..<end])))
        }
        return declarations
    }

    /// The start of each declaration: the line start of every whole-word `func`, except
    /// where two requirements share a line and the second keeps its own keyword position.
    private static func declarationStarts(inProtocolBody body: String) -> [String.Index] {
        var starts: [String.Index] = []
        var index = body.startIndex
        while let found = body.range(of: "func", range: index..<body.endIndex) {
            index = found.upperBound
            let atStart = found.lowerBound == body.startIndex
            let preceding = atStart ? " " : body[body.index(before: found.lowerBound)]
            let following = found.upperBound < body.endIndex ? body[found.upperBound] : " "
            guard !isIdentifierCharacter(preceding), !isIdentifierCharacter(following) else {
                continue
            }
            let lineStart = startOfLine(of: found.lowerBound, in: body)
            if let previous = starts.last, lineStart <= previous {
                starts.append(found.lowerBound)
            } else {
                starts.append(lineStart)
            }
        }
        return starts
    }

    private static func startOfLine(of position: String.Index, in text: String) -> String.Index {
        var index = position
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous] == "\n" { return index }
            index = previous
        }
        return text.startIndex
    }

    // MARK: - Normalisation

    /// Whitespace runs collapsed, then punctuation spaced one way and one way only, so that
    /// a wrapped parameter list, a different indent, or a trailing comma all reduce to the
    /// same text.
    ///
    /// The limit is that this is spacing, not lexing: `->Void` written with no spaces at all
    /// still normalises to `-> Void`, but a type spelled two ways — `[String: Int]` against
    /// `Dictionary<String, Int>` — is two fingerprints. That direction fails loudly, which
    /// is the safe one for a guard.
    static func normalised(_ declaration: String) -> String {
        let collapsed = collapsingWhitespace(
            collapsingWhitespace(declaration).replacingOccurrences(of: "->", with: " -> "))

        var tightened = ""
        for character in collapsed {
            if character == " ", tightened.last == "(" { continue }
            if character == "," || character == ")" || character == ":", tightened.last == " " {
                tightened.removeLast()
            }
            // A trailing comma before the closing parenthesis is a formatting choice, not a
            // parameter.
            if character == ")", tightened.last == "," { tightened.removeLast() }
            tightened.append(character)
        }

        var spaced = ""
        for character in tightened {
            if let last = spaced.last, last == "," || last == ":", character != " " {
                spaced.append(" ")
            }
            spaced.append(character)
        }
        return spaced
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Selector inference

    /// The Objective-C selector Swift infers for a normalised `@objc` method declaration:
    /// base name, `With`, the first argument label capitalised, then each remaining label.
    ///
    /// Plain inference only — no `@objc(…)` rename, no wildcard label, no preposition
    /// splitting. Its correctness for this protocol is not assumed: the caller compares the
    /// derived set to the selectors the runtime guard pins.
    static func selector(forNormalisedSignature signature: String) -> String? {
        guard signature.hasPrefix("func "),
            let open = signature.firstIndex(of: "("),
            let close = signature.lastIndex(of: ")"),
            open < close
        else { return nil }

        let name = signature[signature.index(signature.startIndex, offsetBy: 5)..<open]
            .trimmingCharacters(in: .whitespaces)
        let labels = topLevelComponents(of: String(signature[signature.index(after: open)..<close]))
            .map { component -> String in
                String(component.prefix(while: { $0 != ":" }))
            }
        guard !name.isEmpty, let first = labels.first else { return nil }

        let rest = labels.dropFirst().map { "\($0):" }.joined()
        return "\(name)With\(first.prefix(1).uppercased())\(first.dropFirst()):\(rest)"
    }

    /// A parameter list split at its top-level commas: a reply block's own arguments —
    /// `(Data?, Error?)` — are not parameters of the method.
    private static func topLevelComponents(of clause: String) -> [String] {
        var components: [String] = []
        var current = ""
        var depth = 0
        var previous: Character = " "

        for character in clause {
            switch character {
            case "(", "[", "<": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            // The `>` of a return arrow closes nothing; only a generic bracket's does.
            // Load-bearing: `Pair<() -> Void, Data>` splits at the wrong comma without it,
            // which is what `selectorSurvivesAFunctionTypeInsideAGeneric` holds.
            case ">" where previous != "-": depth = max(0, depth - 1)
            default: break
            }
            if character == "," && depth == 0 {
                components.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        components.append(current)
        return
            components
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Lexical helpers

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// The `}` closing the `{` at `open`. Comments are gone by the time this runs; string
    /// literals carry no brace in this file and are not tracked.
    private static func closingBrace(
        in code: String, openingAt open: String.Index
    ) -> String.Index? {
        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// Comments removed, string literals preserved.
    ///
    /// Swift nests block comments, so depth is counted rather than the first `*/` taken. A
    /// `/*` inside a string literal opens nothing — for a single-quoted `"…"` literal, which
    /// is the only kind handled. A multi-line `"""` or raw `#"…"#` literal would be scanned
    /// as code: `"""` opens and immediately closes an empty literal. Nothing in
    /// `AeolusXPCProtocol.swift` is spelled that way, and if one arrives carrying a brace or
    /// a comment token the scan breaks *loudly* — `protocolBody` returns nil and the
    /// `#require` in the suite fails — rather than fingerprinting a truncated body.
    /// This much is the same shape as
    /// `SeamScanner.strippingComments`, and is duplicated because the two live in different
    /// test targets; unlike that one it removes a comment *trailing* code rather than only
    /// whole comment lines, which is what lets a `// note` after a parameter list disappear.
    static func strippingComments(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        var depth = 0

        func matches(_ token: String, at position: String.Index) -> Bool {
            source[position...].hasPrefix(token)
        }

        while index < source.endIndex {
            if depth > 0 {
                if matches("/*", at: index) {
                    depth += 1
                    index = source.index(index, offsetBy: 2)
                } else if matches("*/", at: index) {
                    depth -= 1
                    index = source.index(index, offsetBy: 2)
                } else {
                    if source[index] == "\n" { output.append("\n") }
                    index = source.index(after: index)
                }
                continue
            }

            if matches("/*", at: index) {
                depth = 1
                index = source.index(index, offsetBy: 2)
            } else if matches("//", at: index) {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
            } else if source[index] == "\"" {
                index = copyingLiteral(source, from: index, into: &output)
            } else {
                output.append(source[index])
                index = source.index(after: index)
            }
        }
        return output
    }

    /// One `"…"` literal copied through unread, escapes included.
    private static func copyingLiteral(
        _ source: String, from start: String.Index, into output: inout String
    ) -> String.Index {
        var index = start
        output.append(source[index])
        index = source.index(after: index)

        while index < source.endIndex {
            let character = source[index]
            output.append(character)
            index = source.index(after: index)
            if character == "\\", index < source.endIndex {
                output.append(source[index])
                index = source.index(after: index)
                continue
            }
            if character == "\"" { break }
        }
        return index
    }
}
