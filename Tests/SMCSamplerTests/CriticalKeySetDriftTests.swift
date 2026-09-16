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

    /// The individual prefix strings a `prefixLiteral(in:)` result names, in order — the
    /// bracketed-literal counterpart of `suffixes(fromLiteral:)` above, reused so
    /// `resolvedKeysMatchCriticalSensorSetLiterals` reads the prefix pair from
    /// `CriticalSensorSet.swift`'s own source rather than carrying a third hard-coded copy
    /// of `["TPD", "TRD"]` that `prefixListsMatch` and
    /// `mac16x5ComposesOnlyFromTheSharedLiterals` do not otherwise cover: round-3 delta
    /// review of #248 found that a helper-side prefix widening
    /// (`dieClusterKeys(prefixes: ["TPD", "TRD", "TCD"])`) left
    /// `resolvedKeysMatchCriticalSensorSetLiterals` green while `prefixListsMatch` and
    /// `mac16x5ComposesOnlyFromTheSharedLiterals` both went red — a redundancy rather than
    /// a hole today, but one this removes rather than leaves for the next literal to drift
    /// past unnoticed.
    private static func prefixes(fromLiteral literal: String) -> [String] {
        literal
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
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

    /// `CriticalSensorSet.mac16x5`'s own `keys:` argument, whitespace-stripped, taken from
    /// `static let mac16x5 = CriticalSensorSet(` up to the following `provenance:` label.
    ///
    /// The three checks above (`suffixListsMatch`, `prefixListsMatch`,
    /// `resolvedKeysMatchCriticalSensorSetLiterals`) all compare the *shared* `suffixes`
    /// array and the `["TPD", "TRD"]` prefix pair that `dieClusterKeys(prefixes:)` takes as
    /// an argument — none of them look at `mac16x5`'s own construction, so a term appended
    /// there (`dieClusterKeys(prefixes: ["TPD", "TRD"]) + [known("TCAL")]`, say — the
    /// natural way to add one measured key to one model without widening `suffixes` for
    /// every model that calls it) passes all three unchanged: the shared literals it reads
    /// are untouched. This anchors on the composition itself.
    private static func mac16x5KeysArgumentLiteral(in source: String) throws -> String {
        let startMarker = "static let mac16x5 = CriticalSensorSet("
        let startRange = try #require(
            source.range(of: startMarker), "no \"\(startMarker)\" found in source")
        let tail = source[startRange.upperBound...]
        let provenanceRange = try #require(
            tail.range(of: "provenance:"),
            "no \"provenance:\" found after mac16x5's keys: argument")
        return String(tail[..<provenanceRange.lowerBound]).filter { !$0.isWhitespace }
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

    /// Mutation this closes, cited on its own rather than folded into a suffix-list
    /// mutation that never touches the prefix pair (round-2 delta review of #248 flagged
    /// the original commit for citing a "Y"-suffix mutation here, under which this test
    /// correctly stays green — a suffix change is not a prefix change): change
    /// `dieClusterKeys(prefixes: ["TPD", "TRD"])` to `dieClusterKeys(prefixes: ["TPD",
    /// "TRD", "TCD"])` in either file without touching the other, and the
    /// whitespace-stripped literals stop matching.
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
        let prefixLiteral = try #require(
            Self.prefixLiteral(in: Self.criticalSensorSetSource),
            "CriticalSensorSet.swift no longer names [\"TPD\", \"TRD\"]")
        let prefixes = Self.prefixes(fromLiteral: prefixLiteral)
        let expected = prefixes.flatMap { prefix in suffixes.map { prefix + $0 } }

        #expect(
            expected.count == 34,
            """
            expected the well-known 34-key Mac16,5 die cluster (2 prefixes x 17 suffixes); \
            got \(expected.count) — CriticalSensorSet.swift's suffix or prefix literal \
            changed shape
            """)
        #expect(MeasurementKeySet.criticalKeys(forModel: "Mac16,5") == expected)
    }

    /// Closes the gap none of the three checks above cover: `mac16x5`'s own `keys:`
    /// argument must be exactly `dieClusterKeys(prefixes: ["TPD", "TRD"])`, with nothing
    /// appended or substituted — a widening of the *composition* rather than of the shared
    /// literals the other three tests compare.
    ///
    /// Mutation this closes: `Sources/AeolusHelper/Safety/CriticalSensorSet.swift`'s
    /// `keys: dieClusterKeys(prefixes: ["TPD", "TRD"])` becomes
    /// `keys: dieClusterKeys(prefixes: ["TPD", "TRD"]) + [known("TCAL")]` — the exact
    /// mutation the round-2 delta review ran, under which `suffixListsMatch`,
    /// `prefixListsMatch`, and `resolvedKeysMatchCriticalSensorSetLiterals` all stayed
    /// green.
    @Test(
        "mac16x5's keys: argument is exactly dieClusterKeys(prefixes: [\"TPD\", \"TRD\"]), nothing appended"
    )
    func mac16x5ComposesOnlyFromTheSharedLiterals() throws {
        let actual = try Self.mac16x5KeysArgumentLiteral(in: Self.criticalSensorSetSource)
        #expect(
            actual == #"keys:dieClusterKeys(prefixes:["TPD","TRD"]),"#,
            """
            CriticalSensorSet.mac16x5's keys: argument is no longer exactly \
            dieClusterKeys(prefixes: ["TPD", "TRD"]) — got \(actual). If a key was added \
            (or the shared suffixes/prefixes were widened instead), update \
            MeasurementKeySet.mac16x5CriticalKeys in SMCSamplerCore.swift to match.
            """)
    }
}
