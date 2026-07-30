import Foundation
import Testing

@testable import FanKit

/// `CatalogLoader.merge` and `CatalogMatcher` are tested in isolation elsewhere
/// (`CatalogMergeTests.swift`, `CatalogMatcherTests.swift`), but the property that
/// actually matters to a user — that a hand-written override beats a bundled guess on
/// their own machine — only exists because of how those two functions compose. This file
/// exercises that composition directly, calling `CatalogLoader.merge` and then
/// `decoration(forKey:on:)` on its result, rather than simulating `merge`'s ordering by
/// hand the way earlier matcher coverage does.
@Suite("Catalog override precedence — end to end through CatalogMatcher")
struct CatalogMergeResolutionTests {

    /// The coupling `CatalogLoader.merge`'s doc comment names and `CatalogMatcher`'s tie
    /// break exists to serve: a bundled multi-model entry narrowed by a user override for
    /// one of those models. `["Mac16,5", "Mac16,6"]` and `["Mac16,5"]` are different
    /// `OverrideSlot`s (different normalized sets), so `merge` treats this as additive, not
    /// a replacement — both entries survive into the merged catalog. On a Mac16,5, both
    /// match at the same `.modelIdentifier` tier, so the override winning depends entirely
    /// on `merge` having emitted it first. Earlier coverage of this exercised the tie-break
    /// by hand-building a `SensorCatalog` in override-first order (see
    /// `CatalogMatcherSpecificityTests.overrideOrderingWinsAtSameTier`); this instead calls
    /// `CatalogLoader.merge` itself, so a change to merge's emission order would fail this
    /// test rather than only the tests that assume it.
    @Test(
        "A narrowing override wins on the narrowed machine only because merge lists it first"
    )
    func narrowedOverrideWinsThroughMergeAndMatcher() {
        let bundled = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09",
                    match: CatalogMatch(modelIdentifier: ["Mac16,5", "Mac16,6"]),
                    label: "Bundled guess (Mac16,5 or Mac16,6)", category: .cpu,
                    confidence: .guess)
            ])
        let override = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09",
                    match: CatalogMatch(modelIdentifier: ["Mac16,5"]),
                    label: "My verified label", category: .cpu, confidence: .verified,
                    source: "manual")
            ])

        let merged = CatalogLoader.merge(bundled: bundled, override: override)

        // Different scopes, so merge is additive: both entries are present.
        #expect(merged.entries.count == 2)

        let mac165 = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")
        #expect(merged.decoration(forKey: "Tp09", on: mac165)?.label == "My verified label")

        // On the model the override never named, only the bundled entry applies.
        let mac166 = HardwareIdentity(modelIdentifier: "Mac16,6", chipFamily: "M4 Pro")
        #expect(
            merged.decoration(forKey: "Tp09", on: mac166)?.label
                == "Bundled guess (Mac16,5 or Mac16,6)")
    }
}
