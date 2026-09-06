import Foundation
import Testing

/// A minimal, standalone source scanner over `Tools/`, deliberately not shared with
/// `Tests/AeolusHelperTests/SeamScanner.swift`.
///
/// The brief this suite was written against is explicit that the two must not be coupled:
/// `PowerObserverTests` may not `import AeolusHelper` or its test target, because this whole
/// tool exists to be independent of that boundary — a shared scanner would be one more thing
/// pulling `Tools/` toward `Sources/AeolusHelper`, which is precisely the coupling
/// `ToolsSeamTests` exists to keep at zero. What is duplicated here is small on purpose: a
/// file walk and a substring search, not `SeamScanner`'s declaration parser.
enum ToolsSeamScanner {

    /// Every `.swift` file under `Tools/`.
    static func swiftFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/PowerObserverTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Tools")

        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return files
    }

    /// Whether any file under `Tools/` contains `token`, with `//` line comments stripped
    /// first — the same reason `SeamScanner.strippingComments` gives: a tripwire that fires
    /// on the sentence explaining the rule is a tripwire nobody keeps. Unlike `SeamScanner`,
    /// this does not strip block comments; nothing under `Tools/` uses one today, which is
    /// exactly the kind of shortcut this file is allowed to take that `SeamScanner` is not —
    /// see this type's header note on why the two are not shared.
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
