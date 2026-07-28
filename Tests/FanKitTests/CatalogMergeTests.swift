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
}
