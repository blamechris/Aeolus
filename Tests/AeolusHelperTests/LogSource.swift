import Foundation

/// The comment-stripped source of the helper's log files, for the scans that hold a log line to
/// its route. Shared by `HelperLogTests.everyLineTakesTheOneRoute` and `LogRouteTests`, so the
/// three logs are read, and counted, the same way.
enum LogSource {

    /// A call of a logging method on any receiver, qualified or not: `log.fault(`,
    /// `self.log.notice(`, `other.log(`.
    static let loggerCall =
        #"\b\w+\s*\.\s*(fault|error|notice|debug|info|log|trace|warning|critical)\s*\("#

    /// The three things a log type's own file does to reach the unified log: name the `Logger`
    /// type (a construction, an annotation, `os.Logger`), name `os_log`, or call a logging
    /// method on a receiver. Nothing else is counted.
    static let route = #"\bLogger\b|\bos_log\b|"# + loggerCall

    /// A log type's declaration or extension. `struct` as well as `extension`, because
    /// `HelperLog` is declared by a `struct` and extended elsewhere.
    static let declaration = #"\b(?:struct|extension)\s+(?:HelperLog|SafetyLog|LeaseLog)\b"#

    /// The one way a log's closure writes the message it was handed: as a `.public` string. The
    /// per-field `privacy:` arguments of the old `LeaseLog` are gone with the interpolations.
    static let publicMessage = #""\\\(message, privacy: \.public\)""#

    private static var helperRoot: URL {
        SeamScanner.sourcesRoot.appendingPathComponent("AeolusHelper")
    }

    /// `path`, relative to `Sources/AeolusHelper`, with comments removed.
    ///
    /// **Fails closed.** A file that is missing or unreadable throws, so a scan that reads it
    /// goes red instead of counting nothing and passing. The path is the whole relative path,
    /// not the last component, so a file of the same name elsewhere is not mistaken for it.
    static func stripped(_ path: String) throws -> String {
        let url = helperRoot.appendingPathComponent(path)
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// Every `.swift` file under `Sources/AeolusHelper`: its path relative to that directory,
    /// and its source with comments removed.
    static func helperFiles() throws -> [(path: String, code: String)] {
        let prefix = helperRoot.path + "/"
        return try SeamScanner.swiftFiles(under: "AeolusHelper").map { url in
            let path = String(url.path.dropFirst(prefix.count))
            return (path, try stripped(path))
        }.sorted { $0.path < $1.path }
    }

    static func matches(of pattern: String, in code: String) throws -> [String] {
        try NSRegularExpression(pattern: pattern)
            .matches(in: code, range: NSRange(code.startIndex..., in: code))
            .compactMap { Range($0.range, in: code).map { String(code[$0]) } }
    }

    /// The logs `code` declares or extends: `HelperLog`, `SafetyLog`, `LeaseLog`.
    static func logsDeclared(in code: String) throws -> Set<String> {
        Set(
            try matches(of: declaration, in: code).compactMap {
                $0.components(separatedBy: .whitespacesAndNewlines).last
            })
    }

    /// Where `code` reaches the unified log, as written: each `Logger`, each `os_log`, each
    /// logging-method call, in source order.
    static func routes(in code: String) throws -> [String] {
        try matches(of: route, in: code)
    }

    /// Where a file that is **not** a log's home reaches the unified log, if it declares or
    /// extends one of the three logs: nothing, for the file that extends none.
    static func routesOfAnExtension(in code: String) throws -> [String] {
        try logsDeclared(in: code).isEmpty ? [] : routes(in: code)
    }

    /// The source of the braces that follow the first match of `declaration`, comments removed,
    /// with every whitespace character removed too, so a reformat is not an edit.
    static func compactBody(of declaration: String, in code: String) throws -> String? {
        let opening = try NSRegularExpression(pattern: declaration + #"[^{]*\{"#)
        guard
            let match = opening.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
            let range = Range(match.range, in: code)
        else { return nil }

        var depth = 1
        var body = ""
        for character in code[range.upperBound...] {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if depth == 0 { break }
            if !character.isWhitespace { body.append(character) }
        }
        return depth == 0 ? body : nil
    }
}
