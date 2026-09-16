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
@Suite("Tools/ directories each own a seam suite")
struct ToolsSeamCoverageTests {

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AeolusHelperTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    /// The name of every immediate subdirectory of `Tools/` — one per maintainer tool.
    static func toolDirectoryNames() throws -> [String] {
        let toolsRoot = repositoryRoot.appendingPathComponent("Tools")
        let contents = try FileManager.default.contentsOfDirectory(
            at: toolsRoot, includingPropertiesForKeys: [.isDirectoryKey])
        let names = try contents.filter { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true
        }.map(\.lastPathComponent)
        #expect(!names.isEmpty, "Tools/ contains no tool directories under \(toolsRoot.path)")
        return names
    }

    /// Fails the moment a tool directory arrives with no `<Name>Tests/ToolsSeamTests.swift`
    /// beside it — the exact shape `Tools/PowerObserver` and `Tools/SMCSampler` both use.
    /// Mutation: create `Tools/ThirdTool/ThirdTool.swift` with no matching test target and
    /// this test goes red; remove the directory and it is green again.
    @Test("every Tools/ directory has a ToolsSeamTests.swift under its own test target")
    func everyToolHasASeamSuite() throws {
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
        }
    }
}
