import FanKit
import Testing

@testable import fanctl

/// Exercises the real `SensorCatalogLookup` implementation — the seam #56 wires in place
/// of `NoSensorCatalog` — entirely against synthetic `SensorCatalog`/`HardwareIdentity`
/// fixtures, never real hardware or the filesystem. `CatalogLoaderTests` (`FanKitTests`)
/// and `CatalogMatcherTests` already cover loading and matching in depth; these tests
/// only prove the fanctl-side adapter wires those two correctly and never regresses the
/// constraints #43 built the matcher to enforce.
@Suite("CatalogSensorLookup — wiring over CatalogLoader + CatalogMatcher")
struct CatalogSensorLookupTests {

    private static let thisMachine = HardwareIdentity(
        modelIdentifier: "Mac16,5", chipFamily: "M4 Max")

    @Test("A matching entry decorates the key with label, category, and confidence")
    func matchingEntryDecoratesKey() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", label: "CPU Efficiency Cluster", category: .cpu,
                    confidence: .community, source: "#44")
            ])
        let lookup = CatalogSensorLookup(catalog: catalog, hardware: Self.thisMachine)

        let label = lookup.label(for: "Tp09")

        #expect(label?.text == "CPU Efficiency Cluster")
        #expect(label?.category == .cpu)
        #expect(label?.confidence == .community)
    }

    @Test("A key with no catalog entry resolves to nil — unmatched, not degraded")
    func unmatchedKeyResolvesToNil() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(key: "Tp09", label: "CPU cluster", category: .cpu, confidence: .guess)
            ])
        let lookup = CatalogSensorLookup(catalog: catalog, hardware: Self.thisMachine)

        #expect(lookup.label(for: "F0Ac") == nil)
    }

    @Test("An empty catalog labels nothing, on any machine")
    func emptyCatalogLabelsNothing() {
        let lookup = CatalogSensorLookup(catalog: .empty, hardware: Self.thisMachine)

        #expect(lookup.label(for: "Tp09") == nil)
    }

    @Test("An entry scoped to a different model does not apply here — a hardware mismatch")
    func hardwareMismatchDoesNotApply() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(modelIdentifier: ["MacBookAir10,1"]),
                    label: "CPU cluster (M1 Air)", category: .cpu, confidence: .verified)
            ])

        let lookup = CatalogSensorLookup(catalog: catalog, hardware: Self.thisMachine)

        // Never lets an M1-scoped entry leak onto an M4 Max — see CatalogMatcher's and
        // CLAUDE.md's rule against keying on anything but the machine's declared
        // identity.
        #expect(lookup.label(for: "Tp09") == nil)
    }

    @Test("A model-scoped entry beats a chip-family-scoped entry for the same key")
    func modelIdentifierBeatsChipFamily() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(chipFamily: ["M4 Max"]),
                    label: "CPU cluster (M4 Max family guess)", category: .cpu,
                    confidence: .guess),
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(modelIdentifier: ["Mac16,5"]),
                    label: "CPU Efficiency Cluster (Mac16,5, verified)", category: .cpu,
                    confidence: .verified),
            ])

        let lookup = CatalogSensorLookup(catalog: catalog, hardware: Self.thisMachine)

        let label = lookup.label(for: "Tp09")
        #expect(label?.text == "CPU Efficiency Cluster (Mac16,5, verified)")
        #expect(label?.confidence == .verified)
    }

    @Test("Two distinct keys resolve independently, without cross-contamination")
    func distinctKeysResolveIndependently() {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(key: "Tp09", label: "CPU cluster", category: .cpu, confidence: .guess),
                CatalogEntry(
                    key: "F0Ac", label: "System Fan", category: .fan, confidence: .verified),
            ])
        let lookup = CatalogSensorLookup(catalog: catalog, hardware: Self.thisMachine)

        #expect(lookup.label(for: "Tp09")?.text == "CPU cluster")
        #expect(lookup.label(for: "F0Ac")?.text == "System Fan")
        #expect(lookup.label(for: "PC0C") == nil)
    }

    @Test("warnings pass through unchanged — never consulted to decide what to label")
    func warningsPassThroughUnchanged() {
        let warnings: [CatalogLoadWarning] = [
            .bundledCatalogUnavailable(reason: "test fixture")
        ]
        let lookup = CatalogSensorLookup(
            catalog: .empty, hardware: Self.thisMachine, warnings: warnings)

        #expect(lookup.warnings == warnings)
        // A warning is never a reason to withhold a label that would otherwise resolve.
        #expect(lookup.label(for: "Tp09") == nil)  // .empty catalog: no entries either way.
    }

    @Test("An unreadable HardwareIdentity (nil fields) matches only unrestricted entries")
    func unreadableHardwareMatchesOnlyUnrestrictedEntries() {
        let unknownMachine = HardwareIdentity(modelIdentifier: nil, chipFamily: nil)
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(modelIdentifier: ["Mac16,5"]),
                    label: "CPU cluster (Mac16,5)", category: .cpu, confidence: .verified),
                CatalogEntry(key: "F0Ac", label: "System Fan", category: .fan, confidence: .guess),
            ])

        let lookup = CatalogSensorLookup(catalog: catalog, hardware: unknownMachine)

        #expect(lookup.label(for: "Tp09") == nil)
        #expect(lookup.label(for: "F0Ac")?.text == "System Fan")
    }
}

@Suite("SensorLabelConfidence / SensorCategoryLabel — FanKit conversions")
struct CatalogConversionTests {

    @Test("Every FanKit.CatalogConfidence maps to a fanctl SensorLabelConfidence")
    func confidenceMapsForEveryKnownCase() {
        #expect(SensorLabelConfidence(catalogConfidence: .verified) == .verified)
        #expect(SensorLabelConfidence(catalogConfidence: .community) == .community)
        #expect(SensorLabelConfidence(catalogConfidence: .guess) == .guess)
    }

    @Test("An unrecognised confidence string is never hidden — it renders as a guess")
    func unknownConfidenceRendersAsGuess() {
        #expect(SensorLabelConfidence(catalogConfidence: .unknown("future-value")) == .guess)
    }

    @Test("Every FanKit.SensorCategory maps to a fanctl SensorCategoryLabel")
    func categoryMapsForEveryKnownCase() {
        #expect(SensorCategoryLabel(catalogCategory: .cpu) == .cpu)
        #expect(SensorCategoryLabel(catalogCategory: .gpu) == .gpu)
        #expect(SensorCategoryLabel(catalogCategory: .memory) == .memory)
        #expect(SensorCategoryLabel(catalogCategory: .storage) == .storage)
        #expect(SensorCategoryLabel(catalogCategory: .battery) == .battery)
        #expect(SensorCategoryLabel(catalogCategory: .power) == .power)
        #expect(SensorCategoryLabel(catalogCategory: .ambient) == .ambient)
        #expect(SensorCategoryLabel(catalogCategory: .display) == .display)
        #expect(SensorCategoryLabel(catalogCategory: .fan) == .fan)
        #expect(SensorCategoryLabel(catalogCategory: .other) == .other)
    }

    @Test("An unrecognised category string is never dropped — it renders as other")
    func unknownCategoryRendersAsOther() {
        #expect(SensorCategoryLabel(catalogCategory: .unknown("future-value")) == .other)
    }
}

@Suite("CatalogLoadWarning.readableDescription — fanctl stderr rendering")
struct CatalogLoadWarningDescriptionTests {

    @Test("Every warning case renders a non-empty, human-readable description")
    func everyWarningCaseRenders() {
        let warnings: [CatalogLoadWarning] = [
            .bundledCatalogUnavailable(reason: "missing resource"),
            .overrideUnreadable(path: "/tmp/catalog.json", reason: "permission denied"),
            .overrideMalformed(path: "/tmp/catalog.json", reason: "invalid JSON"),
        ]
        for warning in warnings {
            #expect(!warning.readableDescription.isEmpty)
        }
    }
}
