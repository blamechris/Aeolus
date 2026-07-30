import Foundation
import Testing

@testable import FanKit

@Suite("Catalog matching — basic resolution")
struct CatalogMatcherBasicTests {

    @Test("An entry with no match applies to every machine")
    func unrestrictedEntryAppliesEverywhere() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(key: "Tp09", label: "CPU cluster", category: .cpu, confidence: .guess)
            ])
        let anyMachine = HardwareIdentity(modelIdentifier: "MacBookAir10,1", chipFamily: "M1")

        let decoration = catalog.decoration(forKey: "Tp09", on: anyMachine)

        #expect(decoration?.label == "CPU cluster")
        #expect(decoration?.key == "Tp09")
    }

    @Test("An exact model identifier match resolves")
    func exactModelIdentifierMatchResolves() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(modelIdentifier: ["Mac16,5"]),
                    label: "CPU cluster (Mac16,5)", category: .cpu, confidence: .verified)
            ])
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        let decoration = catalog.decoration(forKey: "Tp09", on: thisMachine)

        #expect(decoration?.label == "CPU cluster (Mac16,5)")
    }

    @Test("A chip-family match resolves when the model identifier is not named")
    func chipFamilyMatchResolves() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: ["M4 Max"]),
                    label: "CPU cluster (M4 Max)", category: .cpu, confidence: .community)
            ])
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        let decoration = catalog.decoration(forKey: "Tp09", on: thisMachine)

        #expect(decoration?.label == "CPU cluster (M4 Max)")
    }

    @Test("A sensor with no matching entry resolves to nil, not an error state")
    func noMatchingEntryResolvesToNil() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(modelIdentifier: ["MacBookPro18,3"]),
                    label: "CPU cluster (someone else's Mac)", category: .cpu,
                    confidence: .community)
            ])
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        #expect(catalog.decoration(forKey: "Tp09", on: thisMachine) == nil)
        // A completely unknown key on an empty catalog is the same normal state.
        #expect(SensorCatalog.empty.decoration(forKey: "Tp09", on: thisMachine) == nil)
    }

    @Test(
        "An entry naming a restriction that does not hold does not fall back to matching everywhere"
    )
    func nonMatchingRestrictedEntryIsExcludedEntirely() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: ["M1"]),
                    label: "CPU cluster (M1)", category: .cpu, confidence: .community)
            ])
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        #expect(catalog.decoration(forKey: "Tp09", on: thisMachine) == nil)
    }

    @Test("A key with no reading in the catalog at all is unaffected by entries for other keys")
    func unrelatedKeysDoNotInterfere() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(key: "Tg0P", label: "GPU", category: .gpu, confidence: .guess)
            ])
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        #expect(catalog.decoration(forKey: "Tp09", on: thisMachine) == nil)
    }
}

@Suite("Catalog matching — specificity ordering")
struct CatalogMatcherSpecificityTests {

    /// The headline rule: model identifier beats chip family beats unrestricted, tested
    /// with all three tiers present for the same key so nothing is left to array order.
    @Test("modelIdentifier beats chipFamily beats an unrestricted entry")
    func modelIdentifierBeatsChipFamilyBeatsUnrestricted() {
        let unrestricted = CatalogEntry(
            key: "Tp09", label: "Unrestricted guess", category: .cpu, confidence: .guess)
        let chipFamilyScoped = CatalogEntry(
            key: "Tp09", match: CatalogMatch(chipFamily: ["M4 Max"]),
            label: "M4 Max family guess", category: .cpu, confidence: .community)
        let modelScoped = CatalogEntry(
            key: "Tp09", match: CatalogMatch(modelIdentifier: ["Mac16,5"]),
            label: "Mac16,5 verified", category: .cpu, confidence: .verified)
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        // Order in the array deliberately does not favour the expected winner, to prove
        // the result is not just "first in the list".
        let catalog = SensorCatalog(
            schemaVersion: 1, entries: [unrestricted, chipFamilyScoped, modelScoped])

        #expect(catalog.decoration(forKey: "Tp09", on: thisMachine)?.label == "Mac16,5 verified")

        // Same three entries, different array order: the winner must not depend on it.
        let reordered = SensorCatalog(
            schemaVersion: 1, entries: [modelScoped, unrestricted, chipFamilyScoped])
        #expect(
            catalog.decoration(forKey: "Tp09", on: thisMachine)
                == reordered.decoration(forKey: "Tp09", on: thisMachine))
    }

    @Test("chipFamily beats an unrestricted entry when no modelIdentifier entry is present")
    func chipFamilyBeatsUnrestricted() {
        let unrestricted = CatalogEntry(
            key: "Tp09", label: "Unrestricted guess", category: .cpu, confidence: .guess)
        let chipFamilyScoped = CatalogEntry(
            key: "Tp09", match: CatalogMatch(chipFamily: ["M4 Max"]),
            label: "M4 Max family guess", category: .cpu, confidence: .community)
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        let catalog = SensorCatalog(schemaVersion: 1, entries: [unrestricted, chipFamilyScoped])

        #expect(catalog.decoration(forKey: "Tp09", on: thisMachine)?.label == "M4 Max family guess")
    }

    @Test("A chip-family entry for a different chip loses to an unrestricted entry, not to nothing")
    func nonMatchingChipFamilyFallsBackToUnrestricted() {
        let unrestricted = CatalogEntry(
            key: "Tp09", label: "Unrestricted guess", category: .cpu, confidence: .guess)
        let otherChipFamily = CatalogEntry(
            key: "Tp09", match: CatalogMatch(chipFamily: ["M1"]),
            label: "M1 family guess", category: .cpu, confidence: .community)
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        let catalog = SensorCatalog(schemaVersion: 1, entries: [otherChipFamily, unrestricted])

        #expect(catalog.decoration(forKey: "Tp09", on: thisMachine)?.label == "Unrestricted guess")
    }

    @Test("Two entries at the same tier resolve deterministically: the first in catalog order wins")
    func tiedSpecificityResolvesToFirstInOrder() {
        let first = CatalogEntry(
            key: "Tp09", match: CatalogMatch(modelIdentifier: ["Mac16,5"]),
            label: "First (should win)", category: .cpu, confidence: .verified)
        let second = CatalogEntry(
            key: "Tp09", match: CatalogMatch(modelIdentifier: ["Mac16,5"]),
            label: "Second (should lose)", category: .cpu, confidence: .verified)
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        let catalog = SensorCatalog(schemaVersion: 1, entries: [first, second])

        #expect(catalog.decoration(forKey: "Tp09", on: thisMachine)?.label == "First (should win)")
    }

    /// This is exactly the shape `CatalogLoader.merge` produces: an override entry ahead
    /// of the bundled entry it did not literally replace (different match, same key). The
    /// matcher's first-match tie-break means the user's override is what actually wins on
    /// their machine, not just what displays first in some other listing.
    @Test(
        "A user override entry ahead of a same-tier bundled entry wins, matching merge's ordering")
    func overrideOrderingWinsAtSameTier() {
        let bundledGuess = CatalogEntry(
            key: "Tp09", match: CatalogMatch(modelIdentifier: ["Mac16,5"]),
            label: "Bundled guess", category: .cpu, confidence: .guess)
        let userOverride = CatalogEntry(
            key: "Tp09", match: CatalogMatch(modelIdentifier: ["Mac16,5"]),
            label: "My verified label", category: .cpu, confidence: .verified, source: "manual")
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        // CatalogLoader.merge always lists override entries first; simulate that ordering
        // directly rather than depending on CatalogLoader here.
        let catalog = SensorCatalog(schemaVersion: 1, entries: [userOverride, bundledGuess])

        #expect(catalog.decoration(forKey: "Tp09", on: thisMachine)?.label == "My verified label")
    }
}

@Suite("Catalog matching — normalization")
struct CatalogMatcherNormalizationTests {

    @Test(
        "Case differences between the catalog and the machine's chip family do not defeat a match")
    func chipFamilyCaseDifferenceStillMatches() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: ["m4 max"]),
                    label: "CPU cluster", category: .cpu, confidence: .community)
            ])
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        #expect(catalog.decoration(forKey: "Tp09", on: thisMachine)?.label == "CPU cluster")
    }

    @Test("A model identifier case difference between catalog and machine does not defeat a match")
    func modelIdentifierCaseDifferenceStillMatches() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(modelIdentifier: ["mac16,5"]),
                    label: "CPU cluster", category: .cpu, confidence: .verified)
            ])
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        #expect(catalog.decoration(forKey: "Tp09", on: thisMachine)?.label == "CPU cluster")
    }

    @Test("Array order within a match's chipFamily list does not affect whether it matches")
    func chipFamilyArrayOrderDoesNotMatter() {
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")
        let forward = CatalogEntry(
            key: "Tp09", match: CatalogMatch(chipFamily: ["M4", "M4 Max"]),
            label: "CPU cluster", category: .cpu, confidence: .community)
        let reversed = CatalogEntry(
            key: "Tp09", match: CatalogMatch(chipFamily: ["M4 Max", "M4"]),
            label: "CPU cluster", category: .cpu, confidence: .community)

        let forwardCatalog = SensorCatalog(schemaVersion: 1, entries: [forward])
        let reversedCatalog = SensorCatalog(schemaVersion: 1, entries: [reversed])

        #expect(forwardCatalog.decoration(forKey: "Tp09", on: thisMachine) != nil)
        #expect(reversedCatalog.decoration(forKey: "Tp09", on: thisMachine) != nil)
    }

    @Test("An explicit empty match object behaves exactly like no match at all")
    func emptyMatchObjectIsUnrestricted() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: nil, modelIdentifier: nil),
                    label: "CPU cluster", category: .cpu, confidence: .guess)
            ])
        let anyMachine = HardwareIdentity(modelIdentifier: "MacBookAir10,1", chipFamily: "M1")

        #expect(catalog.decoration(forKey: "Tp09", on: anyMachine)?.label == "CPU cluster")
        #expect(CatalogMatcher.specificity(of: CatalogMatch(), on: anyMachine) == .unrestricted)
        #expect(CatalogMatcher.specificity(of: nil, on: anyMachine) == .unrestricted)
    }

    /// The fourth of the four `nil`/`{}`/`[]`/populated forms `match`'s two fields can
    /// take — `catalog.schema.json`'s `minItems: 1` (added alongside this test) keeps a
    /// contributor from *authoring* `"chipFamily": []` in the bundled or an override
    /// catalog, but nothing stops it at the Swift level: `CatalogEntry`'s initializer takes
    /// any `[String]?`. This pins down what happens if one reaches `CatalogMatcher`
    /// anyway — explicit empty arrays for both fields normalize to the empty set exactly
    /// like `nil` does, so the entry is unrestricted, not unmatchable.
    @Test("Explicit empty arrays for both match fields are unrestricted, not unmatchable")
    func explicitEmptyArraysAreUnrestricted() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: [], modelIdentifier: []),
                    label: "CPU cluster", category: .cpu, confidence: .guess)
            ])
        let anyMachine = HardwareIdentity(modelIdentifier: "MacBookAir10,1", chipFamily: "M1")

        #expect(catalog.decoration(forKey: "Tp09", on: anyMachine)?.label == "CPU cluster")
        #expect(
            CatalogMatcher.specificity(
                of: CatalogMatch(chipFamily: [], modelIdentifier: []), on: anyMachine)
                == .unrestricted)
    }

    @Test("An unreadable model identifier (nil) matches no modelIdentifier restriction")
    func nilModelIdentifierMatchesNothing() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(modelIdentifier: ["Mac16,5"]),
                    label: "CPU cluster", category: .cpu, confidence: .verified)
            ])
        let unknownMachine = HardwareIdentity(modelIdentifier: nil, chipFamily: nil)

        #expect(catalog.decoration(forKey: "Tp09", on: unknownMachine) == nil)
    }
}

@Suite("Catalog matching — entries scoped by both axes")
struct CatalogMatcherBothAxesTests {

    @Test("An entry declaring both chipFamily and modelIdentifier applies only when both hold")
    func bothAxesMustHoldToMatch() {
        let entry = CatalogEntry(
            key: "Tp09",
            match: CatalogMatch(chipFamily: ["M4 Max"], modelIdentifier: ["Mac16,5"]),
            label: "CPU cluster", category: .cpu, confidence: .verified)
        let catalog = SensorCatalog(schemaVersion: 1, entries: [entry])

        let matchingMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")
        #expect(catalog.decoration(forKey: "Tp09", on: matchingMachine)?.label == "CPU cluster")

        // Right model, wrong chip family named in the same entry: contradictory data, so
        // the entry does not apply rather than partially applying.
        let modelOnlyMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M1")
        #expect(catalog.decoration(forKey: "Tp09", on: modelOnlyMachine) == nil)

        // Right chip family, wrong model.
        let chipFamilyOnlyMachine = HardwareIdentity(
            modelIdentifier: "MacBookPro18,3", chipFamily: "M4 Max")
        #expect(catalog.decoration(forKey: "Tp09", on: chipFamilyOnlyMachine) == nil)
    }

    @Test("An entry declaring both axes ranks at the modelIdentifier tier")
    func bothAxesRankAtModelIdentifierTier() {
        let bothAxes = CatalogEntry(
            key: "Tp09",
            match: CatalogMatch(chipFamily: ["M4 Max"], modelIdentifier: ["Mac16,5"]),
            label: "Both axes", category: .cpu, confidence: .verified)
        let chipFamilyOnly = CatalogEntry(
            key: "Tp09", match: CatalogMatch(chipFamily: ["M4 Max"]),
            label: "Chip family only", category: .cpu, confidence: .community)
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        let catalog = SensorCatalog(schemaVersion: 1, entries: [chipFamilyOnly, bothAxes])

        #expect(catalog.decoration(forKey: "Tp09", on: thisMachine)?.label == "Both axes")
    }
}

@Suite("Catalog matching — no API selects by label")
struct CatalogMatcherLabelSafetyTests {

    /// This is a design assertion as much as a behavioural one: `CatalogDecoration` and
    /// `CatalogMatcher` expose no lookup from a label back to a key, and every decoration
    /// this suite produces always carries the key it was resolved for. There is no code
    /// path a caller could use to select a sensor "by label" even by accident.
    @Test("A resolved decoration always carries the raw key it was resolved for")
    func decorationAlwaysCarriesItsKey() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", label: "CPU cluster", category: .cpu, confidence: .verified)
            ])
        let machine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

        let decoration = catalog.decoration(forKey: "Tp09", on: machine)

        #expect(decoration?.key == "Tp09")
    }
}
