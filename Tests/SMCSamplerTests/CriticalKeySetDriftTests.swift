import Foundation
import Testing

@testable import smc_sampler

/// A textual drift check between `MeasurementKeySet`'s mirror of the Mac16,5 die/package
/// cluster and `CriticalSensorSet.mac16x5`, the type it deliberately does not import — see
/// `MeasurementKeySet`'s own documentation for why a second transcript, rather than a
/// shared import, is the correct isolation here. Nothing can enforce the two agree via
/// types, because `CriticalSensorSet` is `internal` to `AeolusHelper` on purpose, and this
/// target may not depend on `AeolusHelper` at all — see `ToolsSeamTests`. This is the
/// mechanical alternative: read both source files as text and compare the literal suffix
/// and prefix lists each one hard-codes, the way `ToolsSeamScanner` already reads source as
/// text rather than importing across the same boundary.
///
/// Mutation this is meant to catch: widen `CriticalSensorSet.mac16x5`'s suffix or prefix
/// list without touching `SMCSamplerCore.swift`'s mirror. Every existing test in this
/// target stays green under that mutation — `MeasurementKeySetTests` only asserts this
/// file's own output against itself — which is exactly the drift the finding this suite
/// closes described.
@Suite("MeasurementKeySet mirrors CriticalSensorSet.mac16x5")
struct CriticalKeySetDriftTests {

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/SMCSamplerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    private static var criticalSensorSetSource: String {
        get throws {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "Sources/AeolusHelper/Safety/CriticalSensorSet.swift"),
                encoding: .utf8)
        }
    }

    private static var samplerCoreSource: String {
        get throws {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "Tools/SMCSampler/SMCSamplerCore.swift"),
                encoding: .utf8)
        }
    }

    /// The bracketed literal immediately after `let suffixes = [` in one file's source —
    /// present, identically shaped, in both `CriticalSensorSet.swift` and
    /// `SMCSamplerCore.swift` today. Whitespace-stripped, so line-wrapping differences
    /// between the two files (one per `.swift-format`'s line-length limit, not a content
    /// difference) do not themselves fail the comparison.
    private static func suffixLiteral(in source: String) throws -> String {
        let marker = "let suffixes = ["
        let markerRange = try #require(
            source.range(of: marker), "no \"\(marker)\" found in source")
        let tail = source[markerRange.upperBound...]
        let close = try #require(tail.firstIndex(of: "]"), "unterminated suffixes literal")
        return String(tail[..<close]).filter { !$0.isWhitespace }
    }

    /// The individual suffix strings a `suffixLiteral(in:)` result names, in order.
    private static func suffixes(fromLiteral literal: String) -> [String] {
        literal
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    /// The two-element prefix literal each file writes for the Mac16,5 cluster:
    /// `CriticalSensorSet.swift` as `dieClusterKeys(prefixes: ["TPD", "TRD"])`,
    /// `SMCSamplerCore.swift` as `["TPD", "TRD"].flatMap`. Anchored on the substring
    /// `["TPD", "TRD"]` itself rather than on either surrounding call, so either file
    /// rewording the call around it does not defeat the check.
    private static func prefixLiteral(in source: String) -> String? {
        guard
            let range = source.range(
                of: #"\["TPD",\s*"TRD"\]"#, options: .regularExpression)
        else { return nil }
        return String(source[range]).filter { !$0.isWhitespace }
    }

    @Test("the suffix literal is character-for-character identical in both files")
    func suffixListsMatch() throws {
        let helperSuffixes = try Self.suffixLiteral(in: Self.criticalSensorSetSource)
        let samplerSuffixes = try Self.suffixLiteral(in: Self.samplerCoreSource)

        #expect(
            helperSuffixes == samplerSuffixes,
            """
            CriticalSensorSet.swift's suffix list and SMCSamplerCore.swift's mirror have \
            drifted — update MeasurementKeySet.mac16x5CriticalKeys to match \
            CriticalSensorSet.mac16x5.
            """)
    }

    @Test("the TPD/TRD prefix pair appears identically in both files")
    func prefixListsMatch() throws {
        let helperPrefixes = try #require(
            Self.prefixLiteral(in: Self.criticalSensorSetSource),
            "CriticalSensorSet.swift no longer names [\"TPD\", \"TRD\"]")
        let samplerPrefixes = try #require(
            Self.prefixLiteral(in: Self.samplerCoreSource),
            "SMCSamplerCore.swift no longer names [\"TPD\", \"TRD\"]")

        #expect(helperPrefixes == samplerPrefixes)
    }

    /// The end-to-end version of the two textual checks above: build the 34-key set
    /// `CriticalSensorSet.mac16x5` actually carries, purely from the literals in its own
    /// source, and compare it key-for-key against `MeasurementKeySet.criticalKeys(forModel:)`'s
    /// real output. `MeasurementKeySetTests.mac16x5ResolvesToDieCluster` already asserts
    /// this file's output by count and prefix; this checks the same output against the
    /// type it is a mirror of, not merely against itself.
    @Test(
        "MeasurementKeySet's Mac16,5 keys match the keys built from CriticalSensorSet's own literals"
    )
    func resolvedKeysMatchCriticalSensorSetLiterals() throws {
        let suffixes = Self.suffixes(
            fromLiteral: try Self.suffixLiteral(in: Self.criticalSensorSetSource))
        let expected = ["TPD", "TRD"].flatMap { prefix in suffixes.map { prefix + $0 } }

        #expect(expected.count == 34)
        #expect(MeasurementKeySet.criticalKeys(forModel: "Mac16,5") == expected)
    }
}
