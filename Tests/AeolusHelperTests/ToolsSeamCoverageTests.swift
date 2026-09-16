import Foundation
import Testing

/// The completeness check the per-tool seam scanners depend on but do not provide on their
/// own.
///
/// `Tests/PowerObserverTests/ToolsSeamScanner.swift` and
/// `Tests/SMCSamplerTests/ToolsSeamScanner.swift` each replaced one tripwire that covered all
/// of `Tools/` with a scanner scoped to a single tool directory — necessarily, since the two
/// tools have opposite briefs about naming `SMCCore`. What that split loses for free is the
/// property the blanket scanner used to have: a *third* tool dropped under `Tools/` with no
/// seam suite of its own is invisible to every existing test, because each one only ever
/// walks its own directory. This suite restores that property — not by scanning source, but
/// by scanning the test tree itself for the suite each tool directory is expected to own.
///
/// Round-2 delta review of #248 found the original version of this suite checked only that
/// `Tests/<Name>Tests/ToolsSeamTests.swift` *exists* — a file present on disk but never
/// compiled (no matching `.testTarget` in `Package.swift`) or containing no suite at all
/// satisfied it just as well as a real one. `everyToolHasARunningSeamSuite` below closes
/// both gaps: it additionally reads `Package.swift` as text for the target wiring, and the
/// seam file's own contents for a non-empty `forbiddenTokens` list under a `@Suite`.
@Suite("Tools/ directories each own a seam suite")
struct ToolsSeamCoverageTests {

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AeolusHelperTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    /// The name of every immediate, non-hidden subdirectory of `Tools/` — one per
    /// maintainer tool. `contentsOfDirectory(at:includingPropertiesForKeys:)` with no
    /// `.skipsHiddenFiles` option includes dotfiles/dot-directories, so an incidental
    /// `.DS_Store`-adjacent directory (or a stray `.build` someone points at `Tools/`)
    /// would otherwise demand its own `Tests/.buildTests/ToolsSeamTests.swift` and fail
    /// this suite for a directory that is not a tool at all.
    static func toolDirectoryNames() throws -> [String] {
        let toolsRoot = repositoryRoot.appendingPathComponent("Tools")
        let contents = try FileManager.default.contentsOfDirectory(
            at: toolsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        let names = try contents.filter { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true
        }.map(\.lastPathComponent)
        #expect(!names.isEmpty, "Tools/ contains no tool directories under \(toolsRoot.path)")
        return names
    }

    /// `Package.swift`'s full text, read once per test run. Read as text rather than
    /// parsed — the same "good enough for a tripwire, not a build-graph model" trade-off
    /// `ToolsSeamScanner` itself makes for `Tools/`'s own source.
    static func packageManifestText() throws -> String {
        let manifest = repositoryRoot.appendingPathComponent("Package.swift")
        return try String(contentsOf: manifest, encoding: .utf8)
    }

    /// Every `.testTarget(...)` call's argument text in `manifestText`, each one closed at
    /// its own matching close paren rather than at the next `.testTarget(` marker or the
    /// end of the file. Found by depth-counting parens from just after each `.testTarget(`
    /// — not by splitting on the literal marker and truncating each piece at the following
    /// occurrence, which is unambiguous for every block except the *last*: with nothing
    /// after it to split on, that final block ran to the end of the manifest and so
    /// included every subsequent `.target(...)`/`.executableTarget(...)` declaration and
    /// the closing `]`/`)` of the `targets:` array and `Package(...)` call themselves.
    /// Round-3 delta review of #248 flagged this as a note rather than a live gap — no
    /// non-test target today declares both a `name: "<Name>Tests"` and a matching
    /// `path: "Tests/<Name>Tests"` — but a future one placed after the last `.testTarget(`
    /// would have satisfied the check without a test target existing at all.
    static func testTargetBlocks(in manifestText: String) -> [Substring] {
        var blocks: [Substring] = []
        var searchStart = manifestText.startIndex
        while let markerRange = manifestText.range(
            of: ".testTarget(", range: searchStart..<manifestText.endIndex)
        {
            var depth = 1
            let start = markerRange.upperBound
            var index = start
            while index < manifestText.endIndex, depth > 0 {
                switch manifestText[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                index = manifestText.index(after: index)
            }
            blocks.append(manifestText[start..<index])
            searchStart = index
        }
        return blocks
    }

    /// Whether `manifestText` declares a `.testTarget` naming both `name: "<name>Tests"`
    /// and `path: "Tests/<name>Tests"` — not merely containing the two substrings
    /// somewhere in the file (which two unrelated targets could each satisfy half of), but
    /// within the same `.testTarget(...)` block, as delimited by `testTargetBlocks(in:)`.
    static func manifestDeclaresTestTarget(named name: String, in manifestText: String) -> Bool {
        let expectedName = "name: \"\(name)Tests\""
        let expectedPath = "path: \"Tests/\(name)Tests\""
        return testTargetBlocks(in: manifestText).contains { block in
            block.contains(expectedName) && block.contains(expectedPath)
        }
    }

    /// Whether `seamText` declares a non-empty `forbiddenTokens` array — not merely
    /// containing the word "forbiddenTokens" while lacking the exact single-line spelling
    /// `forbiddenTokens = []`. Round-3 delta review of #248 flagged that spelling as a
    /// substring test an empty list still satisfies two other ways both suites already use
    /// as their declaration style (`static let forbiddenTokens = [` on its own line): a
    /// type-annotated `forbiddenTokens: [String] = []`, and a multi-line `= [\n]`. This
    /// instead locates the bracketed literal after the word and checks it for at least one
    /// quoted string, the same "does the literal actually contain an element" test
    /// `CriticalKeySetDriftTests.swift`'s `suffixLiteral`/`prefixLiteral` helpers use for a
    /// different manifest-adjacent literal.
    static func declaresNonEmptyForbiddenTokens(in seamText: String) -> Bool {
        guard let nameRange = seamText.range(of: "forbiddenTokens") else { return false }
        guard
            let openBracket = seamText.range(
                of: "[", range: nameRange.upperBound..<seamText.endIndex)
        else { return false }
        guard
            let closeBracket = seamText.range(
                of: "]", range: openBracket.upperBound..<seamText.endIndex)
        else { return false }
        let body = seamText[openBracket.upperBound..<closeBracket.lowerBound]
        return body.contains("\"")
    }

    /// Fails the moment a tool directory arrives with no `<Name>Tests/ToolsSeamTests.swift`
    /// beside it, with that file compiled into a real test target, containing a `@Suite`,
    /// and declaring at least one forbidden token — the exact shape `Tools/PowerObserver`
    /// and `Tools/SMCSampler` both use.
    ///
    /// Mutation 1: create `Tools/ThirdTool/ThirdTool.swift` with no matching test target —
    /// red on the file-existence check.
    /// Mutation 2 (the gap the original version of this test missed): additionally create
    /// `Tests/ThirdToolTests/ToolsSeamTests.swift` containing only a comment, with no
    /// matching `.testTarget` added to `Package.swift` — red on the manifest-wiring check,
    /// where the original passed.
    @Test("every Tools/ directory has a compiled, non-empty seam suite")
    func everyToolHasARunningSeamSuite() throws {
        let manifestText = try Self.packageManifestText()
        for name in try Self.toolDirectoryNames() {
            let expected = Self.repositoryRoot
                .appendingPathComponent("Tests")
                .appendingPathComponent("\(name)Tests")
                .appendingPathComponent("ToolsSeamTests.swift")
            #expect(
                FileManager.default.fileExists(atPath: expected.path),
                """
                Tools/\(name) has no \(expected.path) — a new maintainer tool under Tools/ \
                needs its own forbidden-token seam suite, the way PowerObserver and \
                SMCSampler each do.
                """
            )
            #expect(
                Self.manifestDeclaresTestTarget(named: name, in: manifestText),
                """
                Package.swift has no .testTarget with both name: "\(name)Tests" and \
                path: "Tests/\(name)Tests" — a seam file that exists on disk but is never \
                compiled into a test target never runs, and CI stays green either way.
                """
            )

            guard let seamText = try? String(contentsOf: expected, encoding: .utf8) else {
                continue  // already reported by the fileExists expectation above
            }
            #expect(
                seamText.contains("@Suite"),
                """
                \(expected.path) exists but declares no @Suite — an empty file satisfies \
                the file-existence check for nothing.
                """
            )
            #expect(
                Self.declaresNonEmptyForbiddenTokens(in: seamText),
                """
                \(expected.path) declares no non-empty forbiddenTokens list — a seam suite \
                with nothing forbidden never fails, regardless of what Tools/\(name) does.
                """
            )
        }
    }

    /// Round-3 delta review of #248's Mutation D: append a non-test target after the last
    /// real `.testTarget(...)` in the manifest, naming `name: "FooTests"` and
    /// `path: "Tests/FooTests"` — the exact shape a component-split, truncate-at-next-marker
    /// scan would have folded into its final "block" and accepted. `testTargetBlocks(in:)`
    /// closes each block at its own matching paren, so a declaration after the true close
    /// of the last `.testTarget(...)` call is never included in any block.
    @Test("a non-test target declared after the last .testTarget(...) is not mistaken for one")
    func testTargetBlocksStopsAtItsOwnClose() {
        let manifest = """
            .testTarget(
                name: "RealTests",
                dependencies: ["Real"],
                path: "Tests/RealTests"
            ),
            .target(
                name: "FooTests",
                path: "Tests/FooTests"
            ),
            """
        #expect(!Self.manifestDeclaresTestTarget(named: "Foo", in: manifest))
        #expect(Self.manifestDeclaresTestTarget(named: "Real", in: manifest))
    }

    /// A `.testTarget(...)` block whose dependencies include a nested call —
    /// `.product(name: "Foo", package: "Bar")` — has more `)` characters before its own
    /// close than a naive "stop at the next `)`" scan would expect. `testTargetBlocks(in:)`
    /// depth-counts, so it is not fooled by the nesting.
    @Test("a .testTarget(...) block with a nested call closes at its own matching paren")
    func testTargetBlocksHandlesNestedParens() {
        let manifest = """
            .testTarget(
                name: "NestedTests",
                dependencies: [.product(name: "Foo", package: "Bar")],
                path: "Tests/NestedTests"
            ),
            """
        #expect(Self.manifestDeclaresTestTarget(named: "Nested", in: manifest))
    }

    /// Round-3 delta review of #248: the single-line spelling `forbiddenTokens = []` is not
    /// the only way to write an empty list. A type-annotated declaration and a multi-line
    /// empty literal both name the word "forbiddenTokens" while declaring nothing forbidden,
    /// and both must be rejected exactly like the single-line form.
    @Test(
        "an empty forbiddenTokens list is rejected in every spelling, not just the single-line one"
    )
    func declaresNonEmptyForbiddenTokensRejectsEveryEmptySpelling() {
        #expect(!Self.declaresNonEmptyForbiddenTokens(in: "static let forbiddenTokens = []"))
        #expect(
            !Self.declaresNonEmptyForbiddenTokens(
                in: "static let forbiddenTokens: [String] = []"))
        #expect(
            !Self.declaresNonEmptyForbiddenTokens(
                in: "static let forbiddenTokens: [String] = [\n]"))
        #expect(!Self.declaresNonEmptyForbiddenTokens(in: "// no forbiddenTokens here at all"))
    }

    @Test("a non-empty forbiddenTokens list is accepted")
    func declaresNonEmptyForbiddenTokensAcceptsARealList() {
        #expect(
            Self.declaresNonEmptyForbiddenTokens(
                in: """
                    static let forbiddenTokens = [
                        "AeolusHelper",
                    ]
                    """))
    }
}
