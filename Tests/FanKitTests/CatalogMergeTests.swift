import Foundation
import Testing

@testable import FanKit

@Suite("Catalog decoding")
struct CatalogDecodeTests {

    @Test("A schemaVersion this build does not support is rejected, not guessed at")
    func unsupportedSchemaVersionIsRejected() {
        let json = Data(#"{"schemaVersion": 2, "entries": []}"#.utf8)

        let result = CatalogLoader.decode(json)

        guard case .failure(.unsupportedSchemaVersion(let found, let supported)) = result else {
            Issue.record("expected an unsupportedSchemaVersion failure, got \(result)")
            return
        }
        #expect(found == 2)
        #expect(supported == CatalogLoader.supportedSchemaVersion)
    }

    @Test("Garbage bytes are reported as invalid JSON, not a crash")
    func garbageIsInvalidJSON() {
        let result = CatalogLoader.decode(Data("not json at all".utf8))

        guard case .failure(.invalidJSON) = result else {
            Issue.record("expected an invalidJSON failure, got \(result)")
            return
        }
    }

    @Test("A well-formed catalog decodes successfully")
    func wellFormedCatalogDecodes() throws {
        let json = Data(
            """
            {"schemaVersion": 1, "entries": [
              {
                "key": "Tp09", "label": "CPU", "category": "cpu",
                "confidence": "verified", "source": "#1"
              }
            ]}
            """.utf8)

        let result = CatalogLoader.decode(json)

        guard case .success(let catalog) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(catalog.entries.count == 1)
        #expect(catalog.entries[0].confidence == .verified)
    }

    // MARK: - Schema constraints Decodable alone doesn't enforce

    /// `Decodable` happily accepts any string for `key`; the schema requires exactly
    /// four characters. A typo in a *value* must be caught the same way a typo in a
    /// *field name* already is, not load silently — see `firstSchemaViolation`.
    @Test("A key that is not exactly four characters is rejected")
    func overLongKeyIsRejected() {
        let json = Data(
            #"""
            {"schemaVersion": 1, "entries": [
              {"key": "TOO_LONG_KEY", "label": "CPU", "category": "cpu", "confidence": "guess"}
            ]}
            """#.utf8)

        let result = CatalogLoader.decode(json)

        guard case .failure(.invalidJSON(let reason)) = result else {
            Issue.record("expected an invalidJSON failure, got \(result)")
            return
        }
        #expect(reason.contains("TOO_LONG_KEY"))
    }

    @Test("An empty label is rejected")
    func emptyLabelIsRejected() {
        let json = Data(
            #"""
            {"schemaVersion": 1, "entries": [
              {"key": "Tp09", "label": "", "category": "cpu", "confidence": "guess"}
            ]}
            """#.utf8)

        let result = CatalogLoader.decode(json)

        guard case .failure(.invalidJSON(let reason)) = result else {
            Issue.record("expected an invalidJSON failure, got \(result)")
            return
        }
        #expect(reason.contains("label"))
    }

    /// The asymmetry this closes: a typo in a field *name* was already loud (missing
    /// required key → `DecodingError`); a typo in a field *value* used to load silently.
    /// Confirms the good case — a correctly-shaped, in-bounds entry — still decodes.
    @Test("A key of exactly four characters and a non-empty label both pass validation")
    func validKeyAndLabelPassValidation() throws {
        let json = Data(
            #"""
            {"schemaVersion": 1, "entries": [
              {"key": "Tp09", "label": "x", "category": "cpu", "confidence": "guess"}
            ]}
            """#.utf8)

        let result = CatalogLoader.decode(json)

        guard case .success(let catalog) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(catalog.entries.count == 1)
    }
}

@Suite("Catalog override precedence")
struct CatalogMergePrecedenceTests {

    /// The headline precedence rule: an override entry with the same key **and** the
    /// same hardware scope as a bundled entry replaces it outright.
    @Test("An override entry replaces a bundled entry with the same key and match")
    func identicalKeyAndMatchOverrideWins() {
        let bundled = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", label: "Bundled guess", category: .cpu, confidence: .guess)
            ])
        let override = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", label: "My verified label", category: .cpu, confidence: .verified,
                    source: "manual")
            ])

        let merged = CatalogLoader.merge(bundled: bundled, override: override)

        #expect(merged.entries.count == 1)
        #expect(merged.entries[0].label == "My verified label")
        #expect(merged.entries[0].confidence == .verified)
    }

    /// A key can legitimately appear more than once, scoped to different hardware by
    /// `match`. An override targeting one scope must not delete a bundled entry for a
    /// *different* scope under the same key.
    @Test(
        "An override with the same key but a different match does not replace the bundled entry")
    func sameKeyDifferentMatchBothSurvive() {
        let bundled = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: ["M1"]),
                    label: "M1 CPU cluster", category: .cpu, confidence: .community)
            ])
        let override = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: ["M2"]),
                    label: "M2 CPU cluster (mine)", category: .cpu, confidence: .verified,
                    source: "manual")
            ])

        let merged = CatalogLoader.merge(bundled: bundled, override: override)

        #expect(merged.entries.count == 2)
        #expect(Set(merged.entries.map(\.label)) == ["M1 CPU cluster", "M2 CPU cluster (mine)"])
    }

    @Test("An override entry for a novel key is added alongside the bundled entries")
    func novelKeyIsAdded() {
        let bundled = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(key: "Tp09", label: "CPU", category: .cpu, confidence: .guess)
            ])
        let override = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tg0P", label: "GPU (mine)", category: .gpu, confidence: .verified)
            ])

        let merged = CatalogLoader.merge(bundled: bundled, override: override)

        #expect(Set(merged.entries.map(\.key)) == ["Tp09", "Tg0P"])
    }

    @Test("Bundled entries the override never mentions are preserved unchanged")
    func untouchedBundledEntriesSurvive() {
        let bundled = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(key: "Tp09", label: "CPU", category: .cpu, confidence: .guess),
                CatalogEntry(key: "Tg0P", label: "GPU", category: .gpu, confidence: .guess),
            ])
        let override = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", label: "CPU (mine)", category: .cpu, confidence: .verified)
            ])

        let merged = CatalogLoader.merge(bundled: bundled, override: override)

        #expect(merged.entries.contains(where: { $0.key == "Tg0P" && $0.label == "GPU" }))
    }

    /// Merge output lists override entries first. On a genuine two-scope situation this
    /// carries no resolution meaning (a downstream resolver matches by hardware, not
    /// position) — but it is the second line of defence for any near-miss that
    /// normalization still lets through: a first-match resolver reads the user's
    /// explicit override before it reaches the bundled guess.
    @Test("Merged entries list override entries before surviving bundled entries")
    func overrideEntriesComeFirst() {
        let bundled = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(key: "Tp09", label: "Bundled CPU", category: .cpu, confidence: .guess),
                CatalogEntry(
                    key: "Tg0P", match: CatalogMatch(chipFamily: ["M1"]),
                    label: "Bundled GPU (M1)", category: .gpu, confidence: .guess),
            ])
        let override = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tg0P", match: CatalogMatch(chipFamily: ["M2"]),
                    label: "Override GPU (M2)", category: .gpu, confidence: .verified)
            ])

        let merged = CatalogLoader.merge(bundled: bundled, override: override)

        #expect(merged.entries.first?.label == "Override GPU (M2)")
    }
}

@Suite("Catalog override precedence — match normalization")
struct CatalogMergeMatchNormalizationTests {

    /// `chipFamily`/`modelIdentifier` are unordered sets of hardware labels, not
    /// sequences — a hand-edited override listing the same chips in a different order
    /// than the bundled entry means the same scope, and must still replace it rather
    /// than sit alongside it as a spurious duplicate.
    @Test("Reordering chipFamily does not defeat override replacement")
    func reorderedChipFamilyStillMatches() {
        let bundled = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: ["M4", "M4 Max"]),
                    label: "Bundled guess", category: .cpu, confidence: .guess)
            ])
        let override = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: ["M4 Max", "M4"]),
                    label: "My verified label", category: .cpu, confidence: .verified,
                    source: "manual")
            ])

        let merged = CatalogLoader.merge(bundled: bundled, override: override)

        #expect(merged.entries.count == 1)
        #expect(merged.entries[0].label == "My verified label")
    }

    /// No `match` key at all and an explicit `"match": {}` both mean "no hardware
    /// restriction" — the same scope, spelled two different ways a hand edit could
    /// plausibly produce.
    @Test("An explicit empty match object matches a bundled entry with no match at all")
    func emptyMatchObjectMatchesNoMatch() {
        let bundled = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", label: "Bundled guess", category: .cpu, confidence: .guess)
            ])
        let override = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: nil, modelIdentifier: nil),
                    label: "My verified label", category: .cpu, confidence: .verified,
                    source: "manual")
            ])

        let merged = CatalogLoader.merge(bundled: bundled, override: override)

        #expect(merged.entries.count == 1)
        #expect(merged.entries[0].label == "My verified label")
    }

    /// `chipFamily`/`modelIdentifier` values are free-text hardware labels, not raw SMC
    /// keys — case is not meaningful for them the way it is for `key`.
    @Test("Case differences in chipFamily do not defeat override replacement")
    func caseDifferenceStillMatches() {
        let bundled = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: ["M4 Max"]),
                    label: "Bundled guess", category: .cpu, confidence: .guess)
            ])
        let override = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: ["m4 max"]),
                    label: "My verified label", category: .cpu, confidence: .verified,
                    source: "manual")
            ])

        let merged = CatalogLoader.merge(bundled: bundled, override: override)

        #expect(merged.entries.count == 1)
        #expect(merged.entries[0].label == "My verified label")
    }

    /// `modelIdentifier` gets the same normalization as `chipFamily` — reordering it
    /// alone must not create a spurious duplicate either.
    @Test("Reordering modelIdentifier does not defeat override replacement")
    func reorderedModelIdentifierStillMatches() {
        let bundled = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09",
                    match: CatalogMatch(modelIdentifier: ["Mac16,5", "MacBookPro18,3"]),
                    label: "Bundled guess", category: .cpu, confidence: .guess)
            ])
        let override = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09",
                    match: CatalogMatch(modelIdentifier: ["MacBookPro18,3", "Mac16,5"]),
                    label: "My verified label", category: .cpu, confidence: .verified,
                    source: "manual")
            ])

        let merged = CatalogLoader.merge(bundled: bundled, override: override)

        #expect(merged.entries.count == 1)
        #expect(merged.entries[0].label == "My verified label")
    }
}
