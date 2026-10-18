import Foundation
import Testing

/// A minimal, standalone source scanner over `Tools/AppIcon`, deliberately not shared with
/// `Tests/PowerObserverTests/ToolsSeamScanner.swift` or `Tests/SMCSamplerTests`'s: each tool
/// under `Tools/` has its own brief and so its own forbidden list, and a scanner walking
/// the whole tree would make one tool's correct dependency fail another's tripwire.
///
/// What is duplicated is small on purpose — a file walk and a substring search.
enum ToolsSeamScanner {

    /// Every `.swift` file under `Tools/AppIcon`.
    static func swiftFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AppIconTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Tools")
            .appendingPathComponent("AppIcon")

        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "Tools/AppIcon sources were not found under \(root.path)")
        return files
    }

    /// Whether any file under `Tools/AppIcon` contains `token`, with `//` line comments
    /// stripped first: a tripwire that fires on the sentence explaining the rule is a
    /// tripwire nobody keeps. Block comments are not stripped; nothing under `Tools/AppIcon`
    /// uses one (swift-format's `NoBlockComments` forbids them repo-wide).
    static func anyFileContains(_ token: String) throws -> Bool {
        for file in try swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let stripped =
                source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if stripped.contains(token) { return true }
        }
        return false
    }
}
