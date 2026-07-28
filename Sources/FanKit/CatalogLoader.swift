import Foundation

/// Loads the sensor catalog: the bundled resource, with a discoverable, hand-editable
/// user override layered on top.
///
/// Every entry point in this file follows one rule: **a catalog problem is never an app
/// problem.** The catalog only decorates — see `SensorCatalog` — so nothing here throws.
/// A missing bundled resource, a missing override, or a malformed override all resolve
/// to *some* usable `SensorCatalog` (worst case, `.empty`) plus a trail of
/// `CatalogLoadWarning`s a caller can log or surface, never a thrown error a caller has
/// to recover from just to list sensors.
public enum CatalogLoader {

    /// The newest `schemaVersion` this build understands.
    ///
    /// ## schemaVersion policy: reject, don't guess
    ///
    /// Both the bundled catalog and the user override are held to the same rule: a
    /// `schemaVersion` other than `supportedSchemaVersion` is rejected outright rather
    /// than parsed on a best-effort basis. A version bump exists precisely because the
    /// entry shape changed in a way this build cannot be assumed to understand —
    /// guessing at forward or backward compatibility would risk silently misreading
    /// entries rather than refusing them. Rejection here is cheap: the catalog only
    /// decorates, so "ignore this file and say why" is always a safe fallback, never a
    /// degraded one in the sense that matters (every sensor still reads and every fan
    /// still controls).
    public static let supportedSchemaVersion = SensorCatalog.currentSchemaVersion

    // MARK: - User override

    /// Where the hand-editable override lives: `~/Library/Application
    /// Support/Aeolus/catalog.json`. `nil` only if the platform has no resolvable
    /// Application Support directory, which never happens on macOS in practice.
    public static func defaultOverrideURL(fileManager: FileManager = .default) -> URL? {
        guard
            let appSupport = try? fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
        else {
            return nil
        }
        return
            appSupport
            .appendingPathComponent("Aeolus", isDirectory: true)
            .appendingPathComponent("catalog.json", isDirectory: false)
    }

    // MARK: - Effective catalog

    /// Loads the effective catalog: the bundled resource, with the user override layered
    /// on top when one exists at `overrideURL` (or the default location, when
    /// `overrideURL` is left unspecified).
    ///
    /// - Parameters:
    ///   - overrideURL: The override file to check. Pass `nil` (the default) to resolve
    ///     `defaultOverrideURL(fileManager:)`; pass a URL known not to exist to force the
    ///     "no override present" path regardless of the real filesystem.
    ///   - fileManager: Used to resolve the default override location and to check
    ///     whether the override file exists.
    /// - Returns: The merged catalog plus any warnings from loading the bundled resource
    ///   or the override. `catalog` is always usable; warnings never invalidate it.
    public static func load(
        overrideURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> CatalogLoadOutcome {
        load(bundled: loadBundled(), overrideURL: overrideURL, fileManager: fileManager)
    }

    /// Same as `load(overrideURL:fileManager:)`, with the bundled-resource bundle
    /// injectable so tests can exercise a missing/broken bundled catalog without a real
    /// broken build, alongside a real or fake override location.
    static func load(
        bundle: Bundle,
        overrideURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> CatalogLoadOutcome {
        load(
            bundled: loadBundled(bundle: bundle), overrideURL: overrideURL,
            fileManager: fileManager)
    }

    private static func load(
        bundled: CatalogLoadOutcome,
        overrideURL: URL?,
        fileManager: FileManager
    ) -> CatalogLoadOutcome {
        let resolvedOverrideURL = overrideURL ?? defaultOverrideURL(fileManager: fileManager)

        guard let resolvedOverrideURL, fileManager.fileExists(atPath: resolvedOverrideURL.path)
        else {
            // Absent override: not an error, not even worth a warning. This is the
            // common case — most machines never have one.
            return bundled
        }

        let data: Data
        do {
            data = try Data(contentsOf: resolvedOverrideURL)
        } catch {
            return CatalogLoadOutcome(
                catalog: bundled.catalog,
                warnings: bundled.warnings
                    + [
                        .overrideUnreadable(
                            path: resolvedOverrideURL.path, reason: describe(error))
                    ])
        }

        switch decode(data) {
        case .success(let overrideCatalog):
            let merged = merge(bundled: bundled.catalog, override: overrideCatalog)
            return CatalogLoadOutcome(catalog: merged, warnings: bundled.warnings)
        case .failure(let error):
            // A malformed override is never allowed to empty the sensor list: fall back
            // to the bundled catalog exactly as if no override existed, and say why.
            return CatalogLoadOutcome(
                catalog: bundled.catalog,
                warnings: bundled.warnings
                    + [
                        .overrideMalformed(
                            path: resolvedOverrideURL.path, reason: error.description)
                    ])
        }
    }

    // MARK: - Merging

    /// Combines a bundled catalog with an override, entry by entry.
    ///
    /// ## Override precedence
    ///
    /// An entry's identity for override purposes is its `(key, match)` pair, not `key`
    /// alone. An override entry replaces a bundled entry only when both the key **and**
    /// the hardware scope match exactly; the override wins that slot.
    ///
    /// This matters because the schema allows several entries to share a key,
    /// differentiated by `match` — the same raw key can mean different things on
    /// different chips. A key-only precedence rule would let one machine-scoped override
    /// silently delete every bundled entry for that key, including ones that describe
    /// hardware the override was never meant to touch. Scoping the identity to
    /// `(key, match)` means:
    ///
    /// - An override with the same key and the same match (or lack of one) as a bundled
    ///   entry replaces exactly that entry.
    /// - An override with the same key but a *different* match is additive: it sits
    ///   alongside the bundled entries for that key rather than replacing any of them.
    /// - An override with a key the bundled catalog never mentions is simply added.
    ///
    /// The merged catalog's `schemaVersion` is the bundled catalog's — the override has
    /// already been validated against `supportedSchemaVersion` by the time entries reach
    /// this function, so the two necessarily agree.
    public static func merge(bundled: SensorCatalog, override: SensorCatalog) -> SensorCatalog {
        let overriddenSlots = Set(override.entries.map(OverrideSlot.init))
        let survivingBundledEntries = bundled.entries.filter {
            !overriddenSlots.contains(OverrideSlot(entry: $0))
        }
        return SensorCatalog(
            schemaVersion: bundled.schemaVersion,
            entries: survivingBundledEntries + override.entries
        )
    }

    /// The `(key, match)` identity that determines whether an override entry replaces a
    /// bundled one. Not part of `CatalogEntry`'s public surface — it exists only to
    /// drive `merge`.
    private struct OverrideSlot: Hashable {
        let key: String
        let match: CatalogMatch?

        init(entry: CatalogEntry) {
            self.key = entry.key
            self.match = entry.match
        }
    }

    // MARK: - Decoding

    /// Decodes catalog JSON, translating structural problems and an unsupported
    /// `schemaVersion` into a typed, loggable error rather than letting a raw
    /// `DecodingError` leak out to callers that only know how to display a message.
    static func decode(_ data: Data) -> Result<SensorCatalog, CatalogDecodeError> {
        struct SchemaVersionProbe: Decodable {
            let schemaVersion: Int
        }

        let decoder = JSONDecoder()

        do {
            let probe = try decoder.decode(SchemaVersionProbe.self, from: data)
            guard probe.schemaVersion == supportedSchemaVersion else {
                return .failure(
                    .unsupportedSchemaVersion(
                        found: probe.schemaVersion, supported: supportedSchemaVersion))
            }
        } catch {
            return .failure(.invalidJSON(describe(error)))
        }

        do {
            return .success(try decoder.decode(SensorCatalog.self, from: data))
        } catch {
            return .failure(.invalidJSON(describe(error)))
        }
    }

    /// Renders an `Error` as a loggable string. `internal`, not `private`: also used by
    /// `CatalogBundleLoading.swift`, which needs to report an `Error` it catches while
    /// reading the bundled resource without duplicating this one-liner.
    static func describe(_ error: Error) -> String {
        String(describing: error)
    }
}

/// What went wrong while decoding catalog JSON, as data a caller can log or display
/// without needing to know `DecodingError`'s shape.
public enum CatalogDecodeError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The bytes were not valid catalog JSON: unparsable, missing a required field, or a
    /// field with the wrong type.
    case invalidJSON(String)
    /// The `schemaVersion` declared is not one this build knows how to read. See
    /// `CatalogLoader.supportedSchemaVersion`'s doc comment for the reject-don't-guess
    /// policy.
    case unsupportedSchemaVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .invalidJSON(let reason):
            "not valid catalog JSON: \(reason)"
        case .unsupportedSchemaVersion(let found, let supported):
            "schemaVersion \(found) is not supported by this build (supports \(supported))"
        }
    }
}

/// Why a bundled or override catalog file was not used as-is. Never fatal on its own —
/// see `CatalogLoader`'s doc comment — but always worth logging, and worth surfacing in
/// the UI for the override case specifically: a contributor hand-editing JSON needs to
/// know their edit was ignored, and why, rather than silently seeing unlabelled sensors
/// and assuming the catalog itself is empty.
public enum CatalogLoadWarning: Sendable, Hashable {
    /// The bundled resource could not be found or decoded. This indicates a broken
    /// build, not a user mistake.
    case bundledCatalogUnavailable(reason: String)
    /// An override file exists at `path` but could not be read (permissions, a
    /// filesystem error, and so on).
    case overrideUnreadable(path: String, reason: String)
    /// An override file at `path` was read but was not valid catalog JSON, including an
    /// unsupported `schemaVersion`.
    case overrideMalformed(path: String, reason: String)
}

/// The result of a catalog load: what's actually usable, plus everything that went
/// sideways while producing it.
///
/// `warnings` is never a reason to distrust `catalog` — `catalog` is always a complete,
/// safe-to-use `SensorCatalog` (falling back to the bundled entries, or to `.empty`) by
/// the time this is returned. Warnings exist for logging and for telling a user their
/// override was rejected, not for callers to branch on before using the catalog.
public struct CatalogLoadOutcome: Sendable, Hashable {
    public let catalog: SensorCatalog
    public let warnings: [CatalogLoadWarning]

    public init(catalog: SensorCatalog, warnings: [CatalogLoadWarning] = []) {
        self.catalog = catalog
        self.warnings = warnings
    }
}
