import Foundation
import Testing

@testable import FanKit

/// The loader-side half of the `match`-validation rules. `catalog.schema.json` enforces
/// these for the bundled catalog via `catalog-validate.yml`, but a user override at
/// `~/Library/Application Support/Aeolus/catalog.json` is never validated against the
/// schema — so without these checks an override could declare a restriction that silently
/// restricts nothing, and apply to every machine at whatever confidence it claimed.
/// Review of #57 found that gap still open after the schema was tightened.
@Suite("Catalog decode — a declared match must actually restrict")
struct CatalogMatchValidationTests {
    private func decode(matchJSON: String) -> Result<SensorCatalog, CatalogDecodeError> {
        let json = """
            {"schemaVersion": 1, "entries": [{"key": "Tp09", "label": "Applies everywhere",
             "category": "cpu", "confidence": "verified", "match": \(matchJSON)}]}
            """
        return CatalogLoader.decode(Data(json.utf8))
    }

    @Test("An empty chipFamily array is rejected, not read as 'applies everywhere'")
    func emptyChipFamilyRejected() {
        #expect(throws: Never.self) {}
        guard case .failure = decode(matchJSON: #"{"chipFamily": []}"#) else {
            Issue.record("an empty chipFamily array should be rejected")
            return
        }
    }

    @Test("A blank-string scope value is rejected")
    func blankScopeValueRejected() {
        guard case .failure = decode(matchJSON: #"{"modelIdentifier": ["   "]}"#) else {
            Issue.record("a blank modelIdentifier value should be rejected")
            return
        }
    }

    @Test("An omitted match still means 'applies everywhere' and loads")
    func omittedMatchLoads() {
        let json = """
            {"schemaVersion": 1, "entries": [{"key": "Tp09", "label": "Everywhere",
             "category": "cpu", "confidence": "guess"}]}
            """
        guard case .success(let catalog) = CatalogLoader.decode(Data(json.utf8)) else {
            Issue.record("an entry with no match should load")
            return
        }
        #expect(catalog.entries.count == 1)
    }

    @Test("A populated match still loads")
    func populatedMatchLoads() {
        guard case .success(let catalog) = decode(matchJSON: #"{"modelIdentifier": ["Mac16,5"]}"#)
        else {
            Issue.record("a populated match should load")
            return
        }
        #expect(catalog.entries.count == 1)
    }
}
