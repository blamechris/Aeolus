import FanKit
import Foundation

/// The production `SensorCatalogLookup`: decorates raw SMC keys using `FanKit`'s
/// `CatalogLoader` (the bundled catalog plus any user override) and `CatalogMatcher`
/// (hardware-scoped resolution), wired in by `Fanctl.Sensors.run()` in place of
/// `NoSensorCatalog`.
///
/// ## Resolved once per machine, not once per reading
///
/// `fanctl sensors` decorates every reading `SensorProvider.readAll()` returns — on
/// `Mac16,5` that's on the order of 2900 keys per invocation (see
/// `SensorsCommand.JSONOutput`'s doc comment). `CatalogMatcher.decoration(forKey:in:on:)`
/// is a pure function, but it walks the *entire* catalog to find the entries for one key;
/// calling it once per reading would make labelling an O(entries × readings) sweep — cheap
/// today against the empty committed catalog, quadratic once #44 seeds real entries.
///
/// `init(catalog:hardware:)` avoids that by resolving every key the catalog *could*
/// decorate on this machine exactly once, at construction, into `decorationsByKey`.
/// `label(for:)` afterwards is a single dictionary lookup — the "resolve once per machine,
/// then look up by key" the seam is required to do. This still delegates every hardware
/// decision to `CatalogMatcher` itself (via `SensorCatalog.decoration(forKey:on:)`); it
/// never inspects `catalog.entries` to decide what to show — only to know which keys are
/// worth asking the matcher about.
struct CatalogSensorLookup: SensorCatalogLookup {
    private let decorationsByKey: [String: CatalogDecoration]

    /// Anything that went sideways while loading the catalog this lookup was built from —
    /// a missing bundled resource, an unreadable or malformed user override. Never a
    /// reason to distrust `label(for:)`: per `CatalogLoader.CatalogLoadOutcome`'s
    /// contract, `catalog` is always a complete, usable `SensorCatalog` by the time it
    /// reaches here (falling back to `.empty` in the worst case), so a lookup built from a
    /// catalog with warnings behaves identically to one with none — it just has fewer, or
    /// no, entries to resolve. `Fanctl.Sensors.run()` surfaces these on stderr; nothing in
    /// this type ever lets them empty the sensor list `SensorsCommand.fetch` returns.
    let warnings: [CatalogLoadWarning]

    /// Resolves every key `catalog` can decorate on `hardware`, once, up front.
    init(catalog: SensorCatalog, hardware: HardwareIdentity, warnings: [CatalogLoadWarning] = []) {
        // Only the *set* of keys the catalog mentions is walked here — one
        // `decoration(forKey:on:)` call per unique key, not per reading. That is the
        // property that matters: the ~2900 readings a machine exposes never multiply the
        // catalog, and `label(for:)` afterwards is a single dictionary lookup.
        //
        // Be precise about what this does *not* claim. `CatalogMatcher.decoration` filters
        // `catalog.entries` by key on each call rather than indexing by key, so this loop
        // is O(uniqueKeys × entries) in the catalog's size — not linear. That is tens of
        // milliseconds once #44 seeds a few thousand entries, against `readAll()`'s ~4.5 s,
        // so it is not worth optimising here. It *would* be worth fixing inside
        // `CatalogMatcher`, where a keyed index would serve every caller; doing it here
        // instead would move hardware scoping out of the matcher, which is the one thing
        // this adapter must not do.
        var resolved: [String: CatalogDecoration] = [:]
        for key in Set(catalog.entries.map(\.key)) {
            guard let decoration = catalog.decoration(forKey: key, on: hardware) else { continue }
            resolved[key] = decoration
        }
        self.decorationsByKey = resolved
        self.warnings = warnings
    }

    func label(for key: String) -> SensorCatalogLabel? {
        decorationsByKey[key].map(SensorCatalogLabel.init(decoration:))
    }
}

extension CatalogSensorLookup {
    /// Loads the effective catalog (bundled resource plus any user override at
    /// `~/Library/Application Support/Aeolus/catalog.json`) for `hardware` and wraps it as
    /// a ready-to-use lookup. The entry point `Fanctl.Sensors.run()` uses in place of
    /// `NoSensorCatalog`.
    static func loadDefault(hardware: HardwareIdentity = .current()) -> CatalogSensorLookup {
        let outcome = CatalogLoader.load()
        return CatalogSensorLookup(
            catalog: outcome.catalog, hardware: hardware, warnings: outcome.warnings)
    }
}

extension CatalogLoadWarning {
    /// A human-readable rendering for `fanctl`'s stderr warning output — never parsed,
    /// same contract as `SensorReadFailure.readableDescription` in `SMCCore`'s
    /// `SensorProvider.swift`.
    var readableDescription: String {
        switch self {
        case .bundledCatalogUnavailable(let reason):
            return "bundled sensor catalog unavailable (\(reason)) — sensors will show unlabelled"
        case .overrideUnreadable(let path, let reason):
            return "sensor catalog override at \(path) could not be read: \(reason)"
        case .overrideMalformed(let path, let reason):
            return "sensor catalog override at \(path) is not valid, and was ignored: \(reason)"
        }
    }
}
