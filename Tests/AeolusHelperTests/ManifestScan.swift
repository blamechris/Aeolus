import Foundation

/// What the build-setting tripwire (`SeamBuildSettingTests`) reads out of a package manifest and
/// out of the other files that can pass a compiler flag: which flags they name, and where each
/// target's sources live.
///
/// Not a Swift parser, and it does not try to be one. It fails closed: a `path:` it cannot read as
/// a single string literal, a `name:` it cannot read, and a path that resolves outside the
/// directories every other scan here reads are all findings, never exemptions (#441).
enum ManifestScan {

    // MARK: - Flags

    /// What opens the seam to a plain-import test (#436's final review, S3):
    /// `-Xfrontend -disable-access-control` makes every `private` and SPI member nameable, the
    /// daemon's forwarder and entry point among them; `-enable-private-imports` lets a private
    /// import of a source file see them; and `unsafeFlags` is the only way a manifest can pass
    /// either. `-enable-testing`, which CI passes to its release test run, is none of these and is
    /// not listed: it is what keeps `@testable import` working in a release build.
    static let openingFlags = ["unsafeFlags", "-disable-access-control", "-enable-private-imports"]

    /// The opening flags `text` names, in `openingFlags` order. The raw text is read, comments
    /// included: a flag in prose is a file to reword, and no lexer stands between a flag and this.
    static func flags(in text: String) -> [String] {
        openingFlags.filter { text.contains($0) }
    }

    // MARK: - Manifests

    /// The names among `entries` that SwiftPM may read as the package manifest: `Package.swift`,
    /// and every `Package@swift-<version>.swift`, which SwiftPM prefers to `Package.swift` for the
    /// toolchain versions it names. Compared without case, because the checkout may be on a
    /// case-insensitive volume, where `package@swift-6.swift` is the same file.
    static func manifestNames(among entries: [String]) -> [String] {
        entries.filter {
            let name = $0.lowercased()
            return name.hasPrefix("package") && name.hasSuffix(".swift")
        }
        .sorted()
    }

    // MARK: - Targets

    /// The constructors that declare a target.
    static let targetKinds = [
        "target", "executableTarget", "testTarget", "macro", "plugin", "systemLibrary",
        "binaryTarget",
    ]

    /// How a target names its sources.
    enum SourcePath: Equatable {
        /// No `path:`. SwiftPM takes `Sources/<name>`, or `Tests/<name>` for a test target.
        case absent
        /// Exactly one string literal: no interpolation, escape, concatenation or ternary.
        case literal(String)
        /// Anything else, as written: a variable, `"a" + b`, `"\(root)/x"`, a raw string.
        case computed(String)
    }

    struct Target: Equatable {
        let kind: String
        /// The `name:` literal, or `nil` when it is not one.
        let name: String?
        let path: SourcePath
    }

    /// Every target `manifest` declares, in order. A constructor nested inside another target's
    /// arguments — `.target(name: "A")` as a dependency, `.plugin(name:package:)` as a plugin
    /// use — declares nothing and is skipped. Comments are removed first.
    static func targets(in manifest: String) throws -> [Target] {
        let code = SeamScanner.strippingAllComments(manifest)
        let constructor = try NSRegularExpression(
            pattern: #"\.\s*("# + targetKinds.joined(separator: "|") + #")\s*\("#)
        var found: [Target] = []
        var enclosed = code.startIndex..<code.startIndex
        for match in constructor.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let whole = Range(match.range, in: code),
                let kind = Range(match.range(at: 1), in: code),
                !enclosed.contains(whole.lowerBound)
            else { continue }
            let open = code.index(before: whole.upperBound)
            guard let close = SeamScanner.closingParenthesis(in: code, openingAt: open) else {
                // A constructor that never closes cannot be read; it is a finding, not a skip.
                found.append(
                    Target(
                        kind: String(code[kind]), name: nil,
                        path: .computed("an unterminated constructor")))
                continue
            }
            enclosed = whole.lowerBound..<close
            let arguments = topLevelArguments(of: code[code.index(after: open)..<close])
            func argument(_ label: String) -> String? {
                arguments.first { $0.label == label }?.value
            }
            var path = SourcePath.absent
            if let written = argument("path") {
                path = literal(written).map(SourcePath.literal) ?? .computed(written)
            }
            found.append(
                Target(
                    kind: String(code[kind]), name: argument("name").flatMap(literal), path: path))
        }
        return found
    }

    /// The text inside `value` when it is exactly one plain string literal.
    private static func literal(_ value: String) -> String? {
        guard value.range(of: #"^"[^"\\]*"$"#, options: .regularExpression) != nil else {
            return nil
        }
        return String(value.dropFirst().dropLast())
    }

    /// The arguments of a call at its own nesting level: split on commas outside every bracket and
    /// string literal, each as its label (if it has one) and its trimmed text.
    static func topLevelArguments(of body: Substring) -> [(label: String?, value: String)] {
        var pieces: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var escaped = false
        for character in body {
            if inString {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
                current.append(character)
            case "(", "[", "{":
                depth += 1
                current.append(character)
            case ")", "]", "}":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                pieces.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        pieces.append(current)
        return pieces.compactMap { piece -> (label: String?, value: String)? in
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard let label = text.range(of: #"^[A-Za-z_]\w*\s*:"#, options: .regularExpression)
            else { return (nil, text) }
            return (
                String(text[label].dropLast().trimmingCharacters(in: .whitespaces)),
                String(text[label.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    // MARK: - Where a target's sources live

    /// The directories every other scan under `Tests/` reads. A target compiled from anywhere else
    /// is a target no guard here has seen: a `.target` at `Probe/`, linked into a test, could hold
    /// an opt-in to the write SPI that no census counts.
    static let scannedRoots: Set<String> = ["Sources", "Tests", "Tools"]

    /// `path` with `.` and empty components dropped and `..` resolved, or `nil` when it is
    /// absolute or climbs above the package. `Tests/../Probe` is `Probe`.
    static func resolved(_ path: String) -> [String]? {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default:
                parts.append(String(part))
            }
        }
        return parts
    }

    /// Why `target`'s sources are not somewhere the scans read, or `nil` when they are.
    /// `directoryExists` takes a path from the package root and says whether it is a directory.
    static func problem(with target: Target, directoryExists: (String) -> Bool) -> String? {
        let called = ".\(target.kind)(\(target.name ?? "?"))"
        let declared: String
        switch target.path {
        case .computed(let text):
            return "\(called) has a path: that is not a string literal (\(text)), so where its "
                + "sources live cannot be read"
        case .literal(let path):
            declared = path
        case .absent:
            guard let name = target.name else {
                return "\(called) has a name: that is not a string literal, so its default "
                    + "directory cannot be named"
            }
            declared = (target.kind == "testTarget" ? "Tests/" : "Sources/") + name
        }
        guard let parts = resolved(declared), let root = parts.first, scannedRoots.contains(root)
        else {
            return "\(called) takes its sources from \(declared), which is not under "
                + "\(scannedRoots.sorted().joined(separator: ", ")): no scan here reads it"
        }
        guard directoryExists(parts.joined(separator: "/")) else {
            return "\(called) takes its sources from \(parts.joined(separator: "/")), which is "
                + "not a directory"
        }
        return nil
    }
}
