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

    /// Whether any file under `Tools/SMCSampler` contains `token`; see `contains(_:inSource:)`.
    static func anyFileContains(_ token: String) throws -> Bool {
        try swiftFiles().contains {
            contains(token, inSource: try String(contentsOf: $0, encoding: .utf8))
        }
    }

    /// Whether `source` contains `token`, with `//` line comments stripped first — the same
    /// reason `SeamScanner.strippingComments` gives: a tripwire that fires on the sentence
    /// explaining the rule is a tripwire nobody keeps. Unlike `SeamScanner`, this does not strip
    /// block comments; nothing under `Tools/SMCSampler` uses one today.
    ///
    /// **Backticks and whitespace are removed from the source and the token before they are
    /// compared** (#441, T07). The tool's source is on `WriteSeamTestIsolationTests.spiMentioners`
    /// because its prose names `@_spi(FanWrite)`, so the raw census never sees a second mention
    /// there, and this literal match is the only guard on an import in that file. It read
    /// `` @`_spi`(FanWrite) import SMCCore `` as not containing the token, and so would
    /// `@_spi( FanWrite )`, which the compiler accepts (whitespace is allowed inside the
    /// parentheses, and nowhere else in the attribute). Taking the whitespace out also joins a
    /// `SMCConnection` and a `.write` the formatter split over two lines.
    ///
    /// The alternative was to take the file off the census list, so the raw `_spi` token covers
    /// it. That means rewording the tool's own header to stop naming the attribute, an edit
    /// outside the test files, and it would trade a literal match for a census a new mention can
    /// only trip once. Normalising keeps both guards, and the token is the attribute's name and
    /// group whatever import form carries it, so an access level before `import` needs nothing.
    /// The cost is a loud false positive when two identifiers on adjacent lines join into a
    /// forbidden word, and no file under `Tools/SMCSampler` does.
    static func contains(_ token: String, inSource source: String) -> Bool {
        let stripped =
            source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        return normalised(stripped).contains(normalised(token))
    }

    private static func normalised(_ text: String) -> String {
        text.filter { $0 != "`" && !$0.isWhitespace }
    }
}
