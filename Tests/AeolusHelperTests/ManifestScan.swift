import Foundation

/// What the build-setting tripwire (`SeamBuildSettingTests`) reads out of a package manifest and
/// out of the other files that can pass a compiler flag: which flags they name, where each
/// target's sources live, and which targets depend on the helper.
///
/// Not a Swift parser, and it does not try to be one. It fails closed: a `path:` it cannot read as
/// a single string literal, a `name:` it cannot read, a `dependencies:` it cannot read as one array
/// of names, and a path that resolves outside the directories every other scan here reads are all
/// findings, never exemptions (#441, #445).
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

    /// What a target lists in `dependencies:`.
    enum Dependencies: Equatable {
        /// No `dependencies:` argument.
        case absent
        /// One array literal, every element of which was read: a string literal, or `.target`,
        /// `.byName` or `.product` with a `name:` string literal. The names, in order.
        case named([String])
        /// Anything else, as written, or the first element that could not be read: a variable,
        /// `base + ["A"]`, `[.target(name: dependency)]`, a raw or escaped string. It is a
        /// finding and never an empty list, because a list that cannot be read cannot be said to
        /// leave out the helper (#445).
        case unreadable(String)
    }

    struct Target: Equatable {
        let kind: String
        /// The `name:` literal, or `nil` when it is not one.
        let name: String?
        let path: SourcePath
        var dependencies: Dependencies = .absent
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
                        path: .computed("an unterminated constructor"),
                        dependencies: .unreadable("an unterminated constructor")))
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
                    kind: String(code[kind]), name: argument("name").flatMap(literal), path: path,
                    dependencies: argument("dependencies").map(dependencies(from:)) ?? .absent))
        }
        return found
    }

    /// The dependencies `written` lists: every element when `written` is one array literal of
    /// readable elements, and `.unreadable` for the first thing that is not (#445).
    ///
    /// An element is read as a string literal or as `.target(name:)`, `.byName(name:)` or
    /// `.product(name:package:)` with a `name:` string literal, with anything else in the call
    /// (`condition:`, `package:`) ignored. `Target.Dependency.target(name:)` spelled in full is
    /// not read, nor is a `name:` that is a variable or an escaped or raw string: each is
    /// refused where it would otherwise have to be guessed at.
    static func dependencies(from written: String) -> Dependencies {
        guard written.hasPrefix("["), written.hasSuffix("]") else { return .unreadable(written) }
        var names: [String] = []
        for element in topLevelArguments(of: written.dropFirst().dropLast()) {
            guard element.label == nil, let name = dependencyName(element.value) else {
                return .unreadable(element.value)
            }
            names.append(name)
        }
        return .named(names)
    }

    /// The target or product one element names, or `nil` when it is not one of the readable forms.
    private static func dependencyName(_ element: String) -> String? {
        if let name = literal(element) { return name }
        guard
            let head = element.range(
                of: #"^\.\s*(?:target|byName|product)\s*\("#, options: .regularExpression)
        else { return nil }
        let open = element.index(before: head.upperBound)
        let last = element.index(before: element.endIndex)
        // The call is the whole element: `.target(name: "A").foo` or `.target(name: "A") + x`
        // is not a dependency this reads.
        guard SeamScanner.closingParenthesis(in: element, openingAt: open) == last else {
            return nil
        }
        return topLevelArguments(of: element[element.index(after: open)..<last])
            .first { $0.label == "name" }
            .flatMap { literal($0.value) }
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

    /// The directories a target of `kind` may take its sources from, because a scan reads them.
    ///
    /// A test target is held to `Tests/`, the one directory rule zero reads
    /// (`RuleZeroScan.files(under: "Tests")`): a test target at `Sources/X` that composes the real
    /// graph with no require leaves the whole suite green (#442's review, A15), and the guard
    /// this one replaced refused it. Every other kind is held to `Sources/` and `Tools/`, which the
    /// SPI census and the scans over the helper, the clients and the tools read.
    ///
    /// **Rule zero does not read those two.** Its construction rule reads `Tests/` only
    /// (`NotBuiltRequireTripwireTests.everyRealConstructionIsRequiredOnFirstUse`), so a non-test
    /// target there that composed the real graph would be out of its sight. What keeps one from
    /// doing so is not this root but `dependencyProblem(with:)`, which refuses any non-test target
    /// that lists the helper, and the import census in `HelperDependentsTests`, which refuses any
    /// `Sources/` or `Tools/` file outside the helper that imports it (#445). A target anywhere
    /// else is code no scan here reads: a `.target` at `Probe/`, linked into a test, could hold an
    /// opt-in to the write SPI that no census counts.
    static func roots(for kind: String) -> [String] {
        kind == "testTarget" ? ["Tests"] : ["Sources", "Tools"]
    }

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
        let allowed = roots(for: target.kind)
        guard let parts = resolved(declared), let root = parts.first, allowed.contains(root)
        else {
            let why =
                target.kind == "testTarget"
                ? "rule zero reads only Tests/, so a test target anywhere else can build the real "
                    + "graph with no !holdsWriteChannel require"
                : "the scans of the helper, the clients and the tools read only Sources/ and "
                    + "Tools/, and a file under Tests/ is held only to the rules for tests, which "
                    + "let it import the helper"
            return "\(called) takes its sources from \(declared), which is not under "
                + "\(allowed.joined(separator: ", ")): \(why)"
        }
        guard directoryExists(parts.joined(separator: "/")) else {
            return "\(called) takes its sources from \(parts.joined(separator: "/")), which is "
                + "not a directory"
        }
        return nil
    }

    // MARK: - Who depends on the helper

    /// The module whose dependents are pinned: the root daemon's, the only one that can build the
    /// real graph over the real SMC.
    static let helperModule = "AeolusHelper"

    /// Whether `target` lists the helper among the dependencies this scan could read. A list it
    /// could not read is `dependencyProblem(with:)`'s, and is not an answer here.
    static func dependsOnHelper(_ target: Target) -> Bool {
        if case .named(let names) = target.dependencies { return names.contains(helperModule) }
        return false
    }

    /// Why `target`'s dependencies let something outside rule zero's sight reach the helper, or
    /// cannot be told apart from one; `nil` when they do not.
    ///
    /// Rule zero reads `Tests/` only, so only a test target may list the helper: a
    /// `.target(name: "X", dependencies: ["AeolusHelper"], path: "Sources/X")` whose file builds
    /// `HelperComposition.production(log:)` leaves every test green, and any test target can then
    /// depend on it (#445). A list this scan cannot read is refused for every kind, a test
    /// target's included, because the set of targets that depend on the helper is pinned and an
    /// unread list could be in it.
    static func dependencyProblem(with target: Target) -> String? {
        let called = ".\(target.kind)(\(target.name ?? "?"))"
        switch target.dependencies {
        case .absent:
            return nil
        case .unreadable(let text):
            return "\(called) lists dependencies this scan cannot read (\(text)), so whether it "
                + "depends on \(helperModule) cannot be told. It reads one array literal of "
                + "string literals and of .target, .byName and .product with a name: literal"
        case .named:
            guard dependsOnHelper(target), target.kind != "testTarget" else { return nil }
            return "\(called) depends on \(helperModule) and is not a test target. Rule zero "
                + "reads only Tests/, so anything else that links the helper can build its real "
                + "graph over the real SMC with no !holdsWriteChannel require in sight"
        }
    }
}
