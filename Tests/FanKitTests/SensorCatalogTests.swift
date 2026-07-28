import Foundation
import Testing

@testable import FanKit

@Suite("Sensor catalog model")
struct SensorCatalogTests {

    @Test("An entry round-trips through JSON, including its optional fields")
    func entryRoundTripsThroughJSON() throws {
        let entry = CatalogEntry(
            key: "Tp09",
            match: CatalogMatch(chipFamily: ["M1", "M1 Pro"], modelIdentifier: ["Mac16,5"]),
            label: "CPU Efficiency Core Cluster",
            category: .cpu,
            confidence: .community,
            source: "#12"
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(CatalogEntry.self, from: data)

        #expect(decoded == entry)
    }

    @Test("An entry with no match or source decodes with both nil")
    func entryOptionalFieldsDefaultToNil() throws {
        let json = """
            {"key": "Tp09", "label": "CPU", "category": "cpu", "confidence": "guess"}
            """
        let entry = try JSONDecoder().decode(CatalogEntry.self, from: Data(json.utf8))

        #expect(entry.match == nil)
        #expect(entry.source == nil)
    }

    // MARK: - Unknown-carrying enums

    /// A category this build has never heard of must survive decoding rather than
    /// failing the whole entry — the same principle behind `SMCKeyType.unknown`.
    @Test("An unrecognised category is carried, not fatal")
    func unrecognisedCategorySurvives() throws {
        let json = """
            {"key": "Tp09", "label": "Something new", "category": "quantum", "confidence": "guess"}
            """
        let entry = try JSONDecoder().decode(CatalogEntry.self, from: Data(json.utf8))

        #expect(entry.category == .unknown("quantum"))
        #expect(entry.category.schemaValue == "quantum")
    }

    @Test("An unrecognised confidence is carried, not fatal")
    func unrecognisedConfidenceSurvives() throws {
        let json = """
            {"key": "Tp09", "label": "Something new", "category": "cpu", "confidence": "vibes"}
            """
        let entry = try JSONDecoder().decode(CatalogEntry.self, from: Data(json.utf8))

        #expect(entry.confidence == .unknown("vibes"))
        #expect(entry.confidence.schemaValue == "vibes")
    }

    @Test("Every known category round-trips through its schema string")
    func knownCategoriesRoundTrip() {
        let categories: [SensorCategory] = [
            .cpu, .gpu, .memory, .storage, .battery, .power, .ambient, .display, .fan, .other,
        ]
        for category in categories {
            #expect(SensorCategory(schemaValue: category.schemaValue) == category)
        }
    }

    @Test("Every known confidence round-trips through its schema string")
    func knownConfidencesRoundTrip() {
        let confidences: [CatalogConfidence] = [.verified, .community, .guess]
        for confidence in confidences {
            #expect(CatalogConfidence(schemaValue: confidence.schemaValue) == confidence)
        }
    }
}
