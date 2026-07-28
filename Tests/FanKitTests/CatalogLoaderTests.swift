import Foundation
import Testing

@testable import FanKit

// Force unwrapping is fine in tests: a malformed fixture here is a typo, and a crashing
// test is simply a failing test. See .swiftlint.yml.
// swiftlint:disable force_unwrapping

@Suite("Catalog loading — bundled resource")
struct CatalogBundledLoadTests {

    /// Exercises the real production entry point against the real, committed
    /// `Resources/catalog/catalog.json` — currently `{"schemaVersion": 1, "entries": []}`
    /// per #44 (seeding is a separate issue). This is the "decodes from the bundled
    /// resource" acceptance criterion, proven against the actual shipped file rather
    /// than a stand-in.
    ///
    /// - Important: This test is *why* `CatalogLoader.supportedSchemaVersion`'s
    ///   reject-don't-guess policy (see its doc comment) is safe rather than reckless. If
    ///   this build's `supportedSchemaVersion` and the committed catalog's
    ///   `schemaVersion` ever drift apart, this assertion goes red at commit/CI time —
    ///   loudly, in the one place a maintainer is already looking — instead of quietly
    ///   shipping an app that rejects its own bundled catalog and shows no labels to
    ///   every user. Do not weaken `warnings.isEmpty` here without understanding that
    ///   this is the thing standing between "reject on mismatch" and "silently blind on
    ///   mismatch".
    @Test("The real bundled catalog decodes with no warnings")
    func realBundledCatalogDecodes() {
        let outcome = CatalogLoader.loadBundled()

        #expect(outcome.catalog.schemaVersion == SensorCatalog.currentSchemaVersion)
        #expect(outcome.catalog.entries.isEmpty)
        #expect(outcome.warnings.isEmpty)
    }

    /// A bundle that doesn't contain the resource at all — simulating a stripped or
    /// broken build — must degrade to an empty, usable catalog rather than throwing or
    /// crashing.
    @Test("A bundle missing the catalog resource degrades to an empty catalog, with a warning")
    func missingBundledResourceDegradesGracefully() throws {
        let emptyDirectory = try makeTemporaryDirectory()
        let fakeBundle = Bundle(url: emptyDirectory)!

        let outcome = CatalogLoader.loadBundled(bundle: fakeBundle)

        #expect(outcome.catalog == .empty)
        #expect(outcome.warnings.count == 1)
        guard case .bundledCatalogUnavailable = outcome.warnings.first else {
            Issue.record("expected a bundledCatalogUnavailable warning, got \(outcome.warnings)")
            return
        }
    }

    /// The important regression case: SwiftPM's generated `Bundle.module` accessor calls
    /// `fatalError` when it can't find `Aeolus_FanKit.bundle` — a real crash, reproduced
    /// by moving the resource bundle aside and running a `FanKit`-linked executable from
    /// somewhere else on disk (see the PR discussion on #42/#49). `loadBundled()` no
    /// longer goes anywhere near `Bundle.module`; this exercises the *actual* production
    /// function — not a bundle-injected stand-in — with a candidate search that cannot
    /// possibly succeed, proving the real code path degrades instead of trapping.
    @Test(
        "loadBundled() degrades gracefully, through its real search, when every candidate misses"
    )
    func realSearchDegradesGracefullyWhenExhausted() {
        let unresolvableDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aeolus-catalog-tests-nowhere-\(UUID().uuidString)")

        let outcome = CatalogLoader.loadBundled(
            searching: [nil, unresolvableDirectory, nil])

        #expect(outcome.catalog == .empty)
        guard case .bundledCatalogUnavailable = outcome.warnings.first else {
            Issue.record("expected a bundledCatalogUnavailable warning, got \(outcome.warnings)")
            return
        }
    }

    /// The search must not just check the first candidate and give up: a real process
    /// context can have several plausible-but-wrong directories (see
    /// `defaultCandidateDirectories()`) before the one that actually holds the resource
    /// bundle.
    @Test("locateResourceBundle(searching:) falls through misses to a later matching candidate")
    func searchFallsThroughToLaterCandidate() throws {
        let missA = try makeTemporaryDirectory()
        let missB = try makeTemporaryDirectory()
        let hit = try makeTemporaryDirectory()
        try writeCatalogResource(
            into: hit.appendingPathComponent("Aeolus_FanKit.bundle", isDirectory: true),
            json: #"{"schemaVersion": 1, "entries": []}"#)

        let bundle = CatalogLoader.locateResourceBundle(searching: [missA, missB, hit])

        #expect(bundle != nil)
    }

    /// `nil` entries show up in real candidate lists whenever `Bundle.main.resourceURL`
    /// or `Bundle(for:).resourceURL` is `nil` (a bundle with no `Contents/Resources`).
    /// The search must skip them, not crash on force-unwrapping.
    @Test("locateResourceBundle(searching:) tolerates nil candidates in the list")
    func searchToleratesNilCandidates() {
        let bundle = CatalogLoader.locateResourceBundle(searching: [nil, nil, nil])

        #expect(bundle == nil)
    }

    @Test("A bundled catalog resource that resolves to a nonexistent file degrades gracefully")
    func unreadableBundledFileDegradesGracefully() {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("aeolus-catalog-tests-\(UUID().uuidString).json")

        let outcome = CatalogLoader.loadBundled(from: nonexistent)

        #expect(outcome.catalog == .empty)
        guard case .bundledCatalogUnavailable = outcome.warnings.first else {
            Issue.record("expected a bundledCatalogUnavailable warning, got \(outcome.warnings)")
            return
        }
    }

    @Test("A malformed bundled catalog file degrades to an empty catalog, not a crash")
    func malformedBundledFileDegradesGracefully() throws {
        let fileURL = try writeTemporaryFile(contents: "{ this is not json")

        let outcome = CatalogLoader.loadBundled(from: fileURL)

        #expect(outcome.catalog == .empty)
        guard case .bundledCatalogUnavailable(let reason) = outcome.warnings.first else {
            Issue.record("expected a bundledCatalogUnavailable warning, got \(outcome.warnings)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("A bundled catalog with real entries decodes them")
    func bundledCatalogWithEntriesDecodes() throws {
        let bundleRoot = try makeTemporaryDirectory()
        try writeCatalogResource(
            into: bundleRoot,
            json: """
                {
                  "schemaVersion": 1,
                  "entries": [
                    {
                      "key": "Tp09", "label": "CPU cluster", "category": "cpu",
                      "confidence": "guess"
                    }
                  ]
                }
                """)
        let fakeBundle = Bundle(url: bundleRoot)!

        let outcome = CatalogLoader.loadBundled(bundle: fakeBundle)

        #expect(outcome.warnings.isEmpty)
        #expect(outcome.catalog.entries.map(\.key) == ["Tp09"])
    }
}

@Suite("Catalog loading — user override")
struct CatalogOverrideLoadTests {

    /// The common case: no override file at all. Must not warn, must not error — the
    /// bundled catalog is returned exactly as loaded.
    @Test("Absent override degrades to the bundled catalog with no warning")
    func absentOverrideUsesBundledCatalogOnly() throws {
        let bundleRoot = try makeTemporaryDirectory()
        try writeCatalogResource(
            into: bundleRoot,
            json: """
                {"schemaVersion": 1, "entries": [
                  {"key": "Tp09", "label": "CPU", "category": "cpu", "confidence": "guess"}
                ]}
                """)
        let fakeBundle = Bundle(url: bundleRoot)!
        let nonexistentOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("aeolus-catalog-tests-\(UUID().uuidString).json")

        let outcome = CatalogLoader.load(
            bundle: fakeBundle, overrideURL: nonexistentOverride, fileManager: .default)

        #expect(outcome.warnings.isEmpty)
        #expect(outcome.catalog.entries.map(\.key) == ["Tp09"])
    }

    /// Both the bundled resource and the override are absent. This must still not be an
    /// error: it degrades all the way to "no labels", never a blank sensor *list* — the
    /// list itself is a caller's concern, driven by dynamic discovery, not the catalog.
    @Test("Absent bundled catalog and absent override both degrade to an empty catalog")
    func absentBundledAndAbsentOverrideDegradeToEmpty() throws {
        let emptyBundleRoot = try makeTemporaryDirectory()
        let fakeBundle = Bundle(url: emptyBundleRoot)!
        let nonexistentOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("aeolus-catalog-tests-\(UUID().uuidString).json")

        let outcome = CatalogLoader.load(
            bundle: fakeBundle, overrideURL: nonexistentOverride, fileManager: .default)

        #expect(outcome.catalog == .empty)
        #expect(outcome.warnings.count == 1)
        guard case .bundledCatalogUnavailable = outcome.warnings.first else {
            Issue.record("expected a bundledCatalogUnavailable warning, got \(outcome.warnings)")
            return
        }
    }

    @Test("A valid override layers new entries on top of the bundled catalog")
    func validOverrideLayersOnTop() throws {
        let bundleRoot = try makeTemporaryDirectory()
        try writeCatalogResource(
            into: bundleRoot,
            json: """
                {"schemaVersion": 1, "entries": [
                  {"key": "Tp09", "label": "CPU", "category": "cpu", "confidence": "guess"}
                ]}
                """)
        let fakeBundle = Bundle(url: bundleRoot)!
        let overrideURL = try writeTemporaryFile(
            contents: """
                {"schemaVersion": 1, "entries": [
                  {
                    "key": "Tg0P", "label": "GPU (mine)", "category": "gpu",
                    "confidence": "verified", "source": "manual"
                  }
                ]}
                """)

        let outcome = CatalogLoader.load(bundle: fakeBundle, overrideURL: overrideURL)

        #expect(outcome.warnings.isEmpty)
        #expect(Set(outcome.catalog.entries.map(\.key)) == ["Tp09", "Tg0P"])
    }

    /// The core "your edit was ignored, here's why" requirement: a malformed override
    /// never empties the sensor list. It falls back to exactly the bundled catalog.
    @Test("A malformed override falls back to the bundled catalog and reports why")
    func malformedOverrideFallsBackToBundled() throws {
        let bundleRoot = try makeTemporaryDirectory()
        try writeCatalogResource(
            into: bundleRoot,
            json: """
                {"schemaVersion": 1, "entries": [
                  {"key": "Tp09", "label": "CPU", "category": "cpu", "confidence": "guess"}
                ]}
                """)
        let fakeBundle = Bundle(url: bundleRoot)!
        let overrideURL = try writeTemporaryFile(contents: "{ not: valid json")

        let outcome = CatalogLoader.load(bundle: fakeBundle, overrideURL: overrideURL)

        #expect(outcome.catalog.entries.map(\.key) == ["Tp09"])
        guard case .overrideMalformed(let path, let reason) = outcome.warnings.first else {
            Issue.record("expected an overrideMalformed warning, got \(outcome.warnings)")
            return
        }
        #expect(path == overrideURL.path)
        #expect(!reason.isEmpty)
    }

    /// An override missing a required field (schema violation, not just bad JSON syntax)
    /// must be rejected the same way — never a partial or corrupted entry.
    @Test("An override missing a required field falls back to the bundled catalog")
    func overrideMissingRequiredFieldFallsBack() throws {
        let bundleRoot = try makeTemporaryDirectory()
        try writeCatalogResource(
            into: bundleRoot,
            json: """
                {"schemaVersion": 1, "entries": [
                  {"key": "Tp09", "label": "CPU", "category": "cpu", "confidence": "guess"}
                ]}
                """)
        let fakeBundle = Bundle(url: bundleRoot)!
        // Missing "confidence", which the schema requires.
        let overrideURL = try writeTemporaryFile(
            contents: """
                {"schemaVersion": 1, "entries": [
                  {"key": "Tg0P", "label": "GPU", "category": "gpu"}
                ]}
                """)

        let outcome = CatalogLoader.load(bundle: fakeBundle, overrideURL: overrideURL)

        #expect(outcome.catalog.entries.map(\.key) == ["Tp09"])
        guard case .overrideMalformed = outcome.warnings.first else {
            Issue.record("expected an overrideMalformed warning, got \(outcome.warnings)")
            return
        }
    }

    /// See `CatalogLoader.supportedSchemaVersion`'s doc comment: an override written
    /// against a `schemaVersion` this build doesn't understand is rejected outright, not
    /// parsed on a best-effort basis.
    @Test("An override with an unsupported schemaVersion falls back to the bundled catalog")
    func overrideWithUnsupportedSchemaVersionFallsBack() throws {
        let bundleRoot = try makeTemporaryDirectory()
        try writeCatalogResource(
            into: bundleRoot,
            json: """
                {"schemaVersion": 1, "entries": [
                  {"key": "Tp09", "label": "CPU", "category": "cpu", "confidence": "guess"}
                ]}
                """)
        let fakeBundle = Bundle(url: bundleRoot)!
        let overrideURL = try writeTemporaryFile(
            contents: """
                {"schemaVersion": 99, "entries": []}
                """)

        let outcome = CatalogLoader.load(bundle: fakeBundle, overrideURL: overrideURL)

        #expect(outcome.catalog.entries.map(\.key) == ["Tp09"])
        guard case .overrideMalformed(_, let reason) = outcome.warnings.first else {
            Issue.record("expected an overrideMalformed warning, got \(outcome.warnings)")
            return
        }
        #expect(reason.contains("99"))
    }

    @Test("An override pointing at a directory instead of a file is reported as unreadable")
    func overrideAtDirectoryIsUnreadable() throws {
        let bundleRoot = try makeTemporaryDirectory()
        try writeCatalogResource(
            into: bundleRoot,
            json: """
                {"schemaVersion": 1, "entries": []}
                """)
        let fakeBundle = Bundle(url: bundleRoot)!
        let directoryAsOverride = try makeTemporaryDirectory()

        let outcome = CatalogLoader.load(bundle: fakeBundle, overrideURL: directoryAsOverride)

        #expect(outcome.catalog == .empty)
        guard case .overrideUnreadable = outcome.warnings.first else {
            Issue.record("expected an overrideUnreadable warning, got \(outcome.warnings)")
            return
        }
    }
}

@Suite("Default override location")
struct CatalogDefaultOverrideURLTests {

    @Test("The default override URL lives under Application Support/Aeolus/catalog.json")
    func defaultOverrideURLHasExpectedShape() throws {
        let url = try #require(CatalogLoader.defaultOverrideURL())

        #expect(url.lastPathComponent == "catalog.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Aeolus")
    }
}

// MARK: - Fixtures

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("aeolus-catalog-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeTemporaryFile(contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("aeolus-catalog-tests-\(UUID().uuidString).json")
    try Data(contents.utf8).write(to: url)
    return url
}

/// Writes `catalog.json` at the root of `root`, matching the flat layout
/// `CatalogLoader.loadBundled(bundle:)` looks for via `bundle.url(forResource:withExtension:)`
/// — see `Package.swift`'s `FanKit` resource entry, which copies only the file itself.
func writeCatalogResource(into root: URL, json: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: root.appendingPathComponent("catalog.json"))
}

// swiftlint:enable force_unwrapping
