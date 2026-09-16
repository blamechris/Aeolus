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

    /// Whether `manifestText` declares a `.testTarget` naming both `name: "<name>Tests"`
    /// and `path: "Tests/<name>Tests"` — not merely containing the two substrings
    /// somewhere in the file (which two unrelated targets could each satisfy half of), but
    /// within the same `.testTarget(...)` block. Blocks are split on the literal
    /// `.testTarget(` marker, which is unambiguous here because it never appears inside a
    /// string literal or comment anywhere in this manifest.
    static func manifestDeclaresTestTarget(named name: String, in manifestText: String) -> Bool {
        let expectedName = "name: \"\(name)Tests\""
        let expectedPath = "path: \"Tests/\(name)Tests\""
        let blocks = manifestText.components(separatedBy: ".testTarget(")
        return blocks.contains { block in
            block.contains(expectedName) && block.contains(expectedPath)
        }
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
                seamText.contains("forbiddenTokens") && !seamText.contains("forbiddenTokens = []"),
                """
                \(expected.path) declares no non-empty forbiddenTokens list — a seam suite \
                with nothing forbidden never fails, regardless of what Tools/\(name) does.
                """
            )
        }
    }
}
