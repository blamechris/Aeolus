import Foundation
import Testing

/// How the rule-zero tripwires read the tree. **Rule zero: no test may ever write to this Mac's
/// SMC** — not on this build, where nothing can, and not once the plane can (ADR 0014's B1
/// amendment).
///
/// Every scan reads code, never prose or data: comments are removed, trailing ones included, then
/// every string literal, then every backtick (`` `writePath` `` is the same label). A needle
/// written as a string in a tripwire therefore cannot match the tripwire's own file.
enum RuleZeroScan {

    /// One `.swift` file, read as code.
    struct File: Sendable {
        /// From the repository root: `Tests/AeolusHelperTests/HelperHardwareTests.swift`.
        let path: String
        let code: String
    }

    static var repositoryRoot: URL {
        SeamScanner.sourcesRoot.deletingLastPathComponent()
    }

    /// Every `.swift` file under one top-level directory — `Sources`, `Tests` or `Tools` — read as
    /// code, in path order.
    static func files(under directory: String) throws -> [File] {
        let root = repositoryRoot.appendingPathComponent(directory)
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let urls = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!urls.isEmpty, "no Swift files were found under \(directory)")
        return try urls.map { url in
            File(
                path: relativePath(of: url),
                code: code(of: try String(contentsOf: url, encoding: .utf8)))
        }
        .sorted { $0.path < $1.path }
    }

    static func code(of source: String) -> String {
        WriteSeamTestIsolationTests.strippingStringLiterals(
            SeamScanner.strippingAllComments(source)
        )
        .replacingOccurrences(of: "`", with: "")
    }

    static func count(_ pattern: String, in text: String) throws -> Int {
        try NSRegularExpression(pattern: pattern)
            .numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func relativePath(of url: URL) -> String {
        let root = repositoryRoot.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        return components.dropFirst(root.count).joined(separator: "/")
    }

    // MARK: - Reach

    /// What puts a connection that can be opened within a file's reach:
    /// - naming `SMCConnection` at all — constructing one, or taking one handed over as a
    ///   parameter (`RawFanModeReading.read(fan:through:)` is that shape);
    /// - building the production graph, whose factory constructs one;
    /// - building an `SMCSensorProvider`, which opens the connection it is given and defaults one
    ///   of its own.
    ///
    /// `InertSMCConnection()` and `SMCConnectionRecycling` are other names, which the word
    /// boundaries keep out.
    static let reachPatterns = [
        #"(?<![A-Za-z0-9_])SMCConnection(?![A-Za-z0-9_])"#,
        #"\.\s*production\s*\("#,
        #"(?<![A-Za-z0-9_])SMCSensorProvider\s*\("#,
    ]

    static func reaches(_ code: String) throws -> Bool {
        try reachPatterns.contains { try count($0, in: code) > 0 }
    }

    // MARK: - Hardware gating

    /// The files whose suites are gated on hardware: each that names `isHardwareAvailable`, and
    /// each that extends a type one of those declares — `HelperHardwareSightingTests.swift` is an
    /// `extension HelperHardwareTests`, and takes that suite's gate.
    static func hardwareGated(_ files: [File]) throws -> Set<String> {
        let gating = try files.filter {
            try count(#"(?<![A-Za-z0-9_])isHardwareAvailable(?![A-Za-z0-9_])"#, in: $0.code) > 0
        }
        var declared: Set<String> = []
        let declaration = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])(?:struct|class|actor|enum)\s+([A-Za-z_]\w*)"#)
        for file in gating {
            let code = file.code
            let range = NSRange(code.startIndex..., in: code)
            for match in declaration.matches(in: code, range: range) {
                guard let name = Range(match.range(at: 1), in: code) else { continue }
                declared.insert(String(code[name]))
            }
        }
        var gated = Set(gating.map(\.path))
        let extending = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])extension\s+([A-Za-z_]\w*)"#)
        for file in files {
            let code = file.code
            let range = NSRange(code.startIndex..., in: code)
            for match in extending.matches(in: code, range: range) {
                guard let name = Range(match.range(at: 1), in: code) else { continue }
                if declared.contains(String(code[name])) { gated.insert(file.path) }
            }
        }
        return gated
    }

    // MARK: - Balanced text

    /// The text from `open` — a `(` or `{` — to its partner, inclusive, or to the end.
    static func balanced(in code: String, from open: String.Index) -> Substring {
        let opener = code[open]
        let closer: Character = opener == "(" ? ")" : "}"
        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == opener { depth += 1 }
            if code[index] == closer {
                depth -= 1
                if depth == 0 { return code[open...index] }
            }
            index = code.index(after: index)
        }
        return code[open...]
    }
}
