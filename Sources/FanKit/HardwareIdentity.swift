import Foundation

/// This machine's identity for catalog-matching purposes: the exact model, and the chip
/// family it belongs to. See `CatalogMatcher` for what this is used for.
///
/// - Important: `modelIdentifier` is read from `hw.model` via `sysctlbyname`, **never**
///   from `uname -m`. `uname -m` reports the *running process's* architecture, not the
///   machine's model — under Rosetta it reports `x86_64` on an Apple Silicon Mac, which
///   would silently apply Intel-scoped catalog entries (or fail to apply Apple Silicon
///   ones) to a machine that is neither. `hw.model` is the SMC's own declared hardware
///   identity, unaffected by process translation — the same principle `CLAUDE.md` states
///   for keying on the SMC's declared type rather than `uname -m`, applied here to
///   identifying the machine itself. See `Tests/SMCCoreTests/DevelopmentMachine.swift` for
///   the test-only precedent this generalises from.
public struct HardwareIdentity: Sendable, Hashable {
    /// e.g. `"Mac16,5"`, read from `hw.model`. `nil` if the sysctl could not be read, for
    /// any reason — `CatalogMatcher` treats that the same as "matches no
    /// `modelIdentifier` restriction" rather than crashing: an unreadable sysctl must
    /// degrade to unlabelled sensors, not a crash in a library `AeolusHelper` also links.
    public let modelIdentifier: String?

    /// e.g. `"M4 Max"`, derived from `machdep.cpu.brand_string` with the `"Apple "`
    /// marketing prefix stripped — see `chipFamily(fromBrandString:)`. `nil` under the
    /// same conditions as `modelIdentifier`.
    public let chipFamily: String?

    public init(modelIdentifier: String?, chipFamily: String?) {
        self.modelIdentifier = modelIdentifier
        self.chipFamily = chipFamily
    }

    /// Reads this machine's real identity from the running system.
    ///
    /// This is the only non-pure entry point in this file. Everything else here, and all
    /// of `CatalogMatcher`, is a pure function of whatever `HardwareIdentity` a caller
    /// supplies — deliberately, so matching stays fully unit-testable without needing real
    /// hardware or a live sysctl to run the suite.
    public static func current() -> HardwareIdentity {
        HardwareIdentity(
            modelIdentifier: sysctlString("hw.model"),
            chipFamily: chipFamily(fromBrandString: sysctlString("machdep.cpu.brand_string"))
        )
    }

    /// Strips the `"Apple "` marketing prefix macOS reports in `machdep.cpu.brand_string`
    /// on Apple Silicon (`"Apple M4 Max"` → `"M4 Max"`), matching how the catalog schema's
    /// own examples spell chip families (`["M1", "M1 Pro", "M1 Max"]` — see
    /// `docs/DESIGN.md` §6 and `Resources/catalog/catalog.schema.json`).
    ///
    /// Left untouched otherwise: on Intel, `machdep.cpu.brand_string` is the CPU's own
    /// marketing name (e.g. `"Intel(R) Core(TM) i7-..."`), and this project has not
    /// verified a chip-family convention for Intel catalog entries — see `CLAUDE.md`'s
    /// rule against claiming untested hardware support. A future Intel-scoped entry would
    /// need to match on exactly what this returns there, once someone has actually
    /// checked.
    ///
    /// `internal`, not `private`, so `Tests/FanKitTests` can exercise this pure mapping
    /// directly without needing to run on Apple Silicon or Intel to prove it.
    static func chipFamily(fromBrandString brandString: String?) -> String? {
        guard let brandString else { return nil }
        let applePrefix = "Apple "
        guard brandString.hasPrefix(applePrefix) else { return brandString }
        return String(brandString.dropFirst(applePrefix.count))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

extension HardwareIdentity {
    /// Whether `modelIdentifier` (compared case-insensitively) is a member of
    /// `identifiers`. `false` when `modelIdentifier` is `nil` — an unreadable model
    /// identifier matches nothing, rather than matching every entry that also happens to
    /// declare no restriction at all.
    func matchesModelIdentifier(in identifiers: Set<String>) -> Bool {
        guard let modelIdentifier else { return false }
        return identifiers.contains(modelIdentifier.lowercased())
    }

    /// Same as `matchesModelIdentifier(in:)`, for `chipFamily`.
    func matchesChipFamily(in families: Set<String>) -> Bool {
        guard let chipFamily else { return false }
        return families.contains(chipFamily.lowercased())
    }
}
