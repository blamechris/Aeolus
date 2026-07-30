import FanKit
import Foundation

/// Decorates a raw SMC key with a catalog label, if the sensor catalog (E6) has one for
/// this machine. Optional and injectable by design.
///
/// E6 (#10 / the catalog epic) is nearly complete but this layer must work fully without
/// it wired in — an unlabelled sensor is a normal, fully-functional result, not a
/// degraded one. `PollingViewModel` defaults to `NoSensorLabels()`; a caller that has a
/// loaded catalog supplies `CatalogSensorLabelSource` instead. Every `SensorPollingReading`
/// carries its raw `key` regardless of which source produced its `decoration`, so a wrong
/// label can never stand in for the key it came from — see `FanKit.CatalogDecoration`'s
/// own documentation of that rule.
public protocol SensorLabelSource: Sendable {
    /// Returns a decoration for `key`, or `nil` if this source has no opinion.
    func decoration(for key: String) -> CatalogDecoration?
}

/// The default source: labels nothing. Used whenever no catalog has been loaded.
public struct NoSensorLabels: SensorLabelSource {
    public init() {}
    public func decoration(for key: String) -> CatalogDecoration? { nil }
}

/// The production source: `FanKit.CatalogLoader`'s bundled-plus-override catalog, resolved
/// once per machine at construction into a plain dictionary lookup.
///
/// Same shape and rationale as `fanctl`'s `CatalogSensorLookup`
/// (`Sources/fanctl/CatalogSensorLookup.swift`), reimplemented here rather than imported:
/// `AeolusUI` cannot depend on the `fanctl` executable target, and each unprivileged
/// client owning its own thin adapter over `FanKit.CatalogMatcher` is the same
/// architectural split this project already makes between `fanctl` and the app for every
/// other piece of `SensorProvider`-reading logic (see `FanPoller`/`SensorPoller`'s
/// identical relationship to `ListCommand`/`SensorsCommand`).
///
/// Resolving every key up front, rather than calling `CatalogMatcher.decoration(forKey:
/// in:on:)` per reading per refresh tick, is what keeps a live 1 Hz poll cheap:
/// `decoration(forKey:in:on:)` walks the whole catalog per call, so doing that once per
/// unique key at construction — not once per reading per tick — is what makes
/// `decoration(for:)` afterwards a single dictionary lookup on the refresh hot path.
public struct CatalogSensorLabelSource: SensorLabelSource {
    private let decorationsByKey: [String: CatalogDecoration]

    /// Anything that went sideways while loading the catalog this source was built from.
    /// Never a reason to distrust `decoration(for:)` — see `CatalogLoader
    /// .CatalogLoadOutcome`'s contract: `catalog` is always complete and usable by the
    /// time it reaches here.
    public let warnings: [CatalogLoadWarning]

    /// Resolves every key `catalog` can decorate on `hardware`, once, up front.
    public init(
        catalog: SensorCatalog, hardware: HardwareIdentity, warnings: [CatalogLoadWarning] = []
    ) {
        var resolved: [String: CatalogDecoration] = [:]
        for key in Set(catalog.entries.map(\.key)) {
            guard let decoration = catalog.decoration(forKey: key, on: hardware) else { continue }
            resolved[key] = decoration
        }
        self.decorationsByKey = resolved
        self.warnings = warnings
    }

    public func decoration(for key: String) -> CatalogDecoration? {
        decorationsByKey[key]
    }
}

extension CatalogSensorLabelSource {
    /// Loads the effective catalog (bundled resource plus any user override) for
    /// `hardware` and wraps it as a ready-to-use source. The entry point
    /// `PollingViewModel` uses in place of `NoSensorLabels` once a caller opts in.
    public static func loadDefault(
        hardware: HardwareIdentity = .current()
    ) -> CatalogSensorLabelSource {
        let outcome = CatalogLoader.load()
        return CatalogSensorLabelSource(
            catalog: outcome.catalog, hardware: hardware, warnings: outcome.warnings)
    }
}
