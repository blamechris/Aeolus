import Foundation

/// Decides which of a `SensorCatalog`'s entries, if any, describes a given raw key on the
/// machine described by a `HardwareIdentity`. Pure: no IOKit, no sysctl calls of its own —
/// see `HardwareIdentity.current()` for where the machine's own identity is actually read.
///
/// ## Specificity: model identifier beats chip family beats unrestricted
///
/// The schema lets more than one entry share a key, scoped differently (`docs/DESIGN.md`
/// §6) — the same raw key can mean different things on different Macs, and a bundled
/// catalog is expected to eventually carry a family-wide guess alongside an exact-model
/// correction once someone verifies one for a specific machine. When more than one entry
/// matches the same key on this machine, the most specific one wins, in this explicit
/// order — never left to array or dictionary iteration order, which is not something
/// catalog edits should be able to perturb:
///
/// 1. **`modelIdentifier`** — an entry someone wrote for this exact machine.
/// 2. **`chipFamily`** — an entry scoped to a chip shared by several models.
/// 3. **No `match` at all** (or an explicit empty one, `"match": {}`) — applies
///    everywhere.
///
/// An entry that declares a restriction but does not satisfy it (e.g. `modelIdentifier`
/// naming only other machines) does not apply here **at all**, regardless of tier — it is
/// filtered out before ranking begins, never ranked last as a fallback.
///
/// An entry that declares *both* `chipFamily` and `modelIdentifier` is scoped by both: it
/// applies only where every restriction it declares holds, and is ranked at the
/// `modelIdentifier` tier — the more specific of the two restrictions it named. This is
/// the more conservative of the two readings the schema leaves open (matching only when
/// every declared restriction holds, rather than when any one does); the alternative would
/// let a contradictory entry apply somewhere the author only meant to describe with one of
/// the two axes.
///
/// ## Ties
///
/// Two entries at the same specificity tier for the same key is a catalog authoring
/// mistake — nothing in the schema forbids it — but `CatalogMatcher` still resolves it
/// deterministically rather than throwing or returning nothing: **the first matching entry
/// in `catalog.entries` order wins.** This is not an arbitrary tie-break:
/// `CatalogLoader.merge` already places a user's override entries ahead of the bundled
/// entries they did not replace (see that function's doc comment), specifically so a
/// first-match resolver reads the user's explicit intent ahead of the shipped guess.
/// `CatalogMatcher` is that resolver.
public enum CatalogMatcher {

    /// Resolves the single `CatalogDecoration` that applies to `key` on `hardware`, if
    /// any.
    ///
    /// `nil` is not an error and not a degraded result — see `SensorCatalog`'s
    /// documentation: a sensor with no matching entry is a normal, fully-functional state.
    /// Every caller must treat it exactly like any other unlabelled sensor, not as
    /// something to retry, warn about, or hide.
    public static func decoration(
        forKey key: String,
        in catalog: SensorCatalog,
        on hardware: HardwareIdentity
    ) -> CatalogDecoration? {
        var best: (entry: CatalogEntry, specificity: MatchSpecificity)?

        for entry in catalog.entries where entry.key == key {
            guard let specificity = specificity(of: entry.match, on: hardware) else { continue }
            // Strictly greater only: a tie keeps whichever entry was found first, which is
            // exactly the override-first ordering CatalogLoader.merge already produces.
            if let current = best, specificity <= current.specificity { continue }
            best = (entry, specificity)
        }

        guard let best else { return nil }
        return CatalogDecoration(
            key: best.entry.key,
            label: best.entry.label,
            category: best.entry.category,
            confidence: best.entry.confidence,
            source: best.entry.source
        )
    }

    /// How specifically `match` targets `hardware`, or `nil` if `match` declares
    /// restrictions that `hardware` satisfies none of — meaning the entry does not apply
    /// here at all. See `CatalogMatcher`'s documentation for the full ordering and how an
    /// entry naming both axes is scored.
    ///
    /// `internal`, not `private`, so `Tests/FanKitTests` can exercise the specificity rule
    /// directly, independent of `decoration(forKey:in:on:)`'s tie-break behaviour.
    static func specificity(
        of match: CatalogMatch?, on hardware: HardwareIdentity
    ) -> MatchSpecificity? {
        guard let match else { return .unrestricted }

        let modelIdentifiers = match.normalizedModelIdentifier
        let chipFamilies = match.normalizedChipFamily

        if modelIdentifiers.isEmpty && chipFamilies.isEmpty {
            // "match": {} normalizes the same as no match at all.
            return .unrestricted
        }

        if !modelIdentifiers.isEmpty {
            guard hardware.matchesModelIdentifier(in: modelIdentifiers) else { return nil }
            if !chipFamilies.isEmpty {
                guard hardware.matchesChipFamily(in: chipFamilies) else { return nil }
            }
            return .modelIdentifier
        }

        guard hardware.matchesChipFamily(in: chipFamilies) else { return nil }
        return .chipFamily
    }
}

/// How specifically a `CatalogEntry`'s `match` targets the current machine. Raw values
/// define the tie-break order `CatalogMatcher` ranks by — higher wins. Not part of any
/// public-facing rendering; this exists purely to make the ordering explicit and testable
/// rather than left to iteration order.
enum MatchSpecificity: Int, Comparable {
    /// No `match` at all, or an explicitly empty one — applies to every machine.
    case unrestricted = 0
    /// Matched via `chipFamily`.
    case chipFamily = 1
    /// Matched via `modelIdentifier` — the most specific tier: a mapping someone verified
    /// for this exact machine wins over a family-wide guess.
    case modelIdentifier = 2

    static func < (lhs: MatchSpecificity, rhs: MatchSpecificity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension SensorCatalog {
    /// Resolves the catalog match for `key` on `hardware`, if any. See `CatalogMatcher`
    /// for the specificity rule this applies when more than one entry could describe
    /// `key`.
    public func decoration(
        forKey key: String, on hardware: HardwareIdentity
    ) -> CatalogDecoration? {
        CatalogMatcher.decoration(forKey: key, in: self, on: hardware)
    }
}
