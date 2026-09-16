import Foundation
import Testing

/// A minimal, standalone source scanner over `Tools/SMCSampler`, deliberately not shared
/// with `Tests/AeolusHelperTests/SeamScanner.swift` or with
/// `Tests/PowerObserverTests/ToolsSeamScanner.swift` — see that type's header note for why
/// each isolated tool under `Tools/` gets its own scanner with its own forbidden list rather
/// than one shared implementation.
///
/// `smc-sampler`'s brief is the mirror image of `power-observer`'s: it depends on `SMCCore`
/// and `FanKit` on purpose, so those names are not forbidden here the way they are for
/// `power-observer`. What this suite still forbids is a route to the privilege boundary
/// (`AeolusHelper`) or to the SMC write path (`@_spi(FanWrite)`, `SMCConnection.write`) —
/// see `ToolsSeamTests`.
enum ToolsSeamScanner {

    /// Every `.swift` file under `Tools/SMCSampler`.
    static func swiftFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/SMCSamplerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Tools")
            .appendingPathComponent("SMCSampler")

        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "Tools/SMCSampler sources were not found under \(root.path)")
        return files
    }

    /// Whether any file under `Tools/SMCSampler` contains `token`, with `//` line comments
    /// stripped first — the same reason `SeamScanner.strippingComments` gives: a tripwire
    /// that fires on the sentence explaining the rule is a tripwire nobody keeps. Unlike
    /// `SeamScanner`, this does not strip block comments; nothing under `Tools/SMCSampler`
    /// uses one today.
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
