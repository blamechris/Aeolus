import Foundation

/// What the manifest scan refuses beyond a dependency on the helper (#445's review), beside
/// `ManifestScan` and not in it: that enum is at its length ceilings, and `SeamScannerComments` is
/// the precedent for a sibling file holding more of the same type.
extension ManifestScan {

    /// The helper's directory, as components. Nothing but the helper takes its sources from it.
    static let helperDirectory = ["Sources", "AeolusHelper"]

    /// Why `target` could put source in front of the compiler that the scans here do not read, or
    /// `nil` when it cannot (#445). Each is a refusal of a construct this package does not use:
    /// - **A plugin**, a `.plugin` target or a `plugins:` argument. A build-tool plugin generates
    ///   source into the target it is applied to, and no scan here reads generated source: not rule
    ///   zero, not the SPI censuses, not the import census.
    /// - **A target inside the helper's directory.** The helper-only scans skip
    ///   `Sources/AeolusHelper/` wholesale, so a `.target` at `Sources/AeolusHelper/Sub`, with the
    ///   helper `exclude:`-ing `Sub`, imports the helper and builds its real graph where nothing
    ///   looks.
    /// - **A helper that excludes or adds sources.** `exclude:` and `sources:` are how the helper
    ///   would hand part of its directory to another target, or take files from elsewhere; it has
    ///   neither.
    static func reachProblem(with target: Target) -> String? {
        let called = ".\(target.kind)(\(target.name ?? "?"))"
        if target.kind == "plugin" || target.labels.contains("plugins") {
            return
                "\(called) is or uses a plugin. A build-tool plugin generates source that no scan "
                + "here reads, so it could build the real graph out of rule zero's sight"
        }
        if target.name == helperModule {
            guard let label = target.labels.first(where: { ["exclude", "sources"].contains($0) })
            else { return nil }
            return
                "\(called) takes an \(label): argument. That is how its directory would be shared "
                + "with another target or filled from elsewhere, and the scans of the helper's "
                + "sources skip Sources/AeolusHelper/ wholesale"
        }
        guard case .literal(let path) = target.path, let parts = resolved(path),
            parts.starts(with: helperDirectory)
        else { return nil }
        return
            "\(called) takes its sources from \(path), inside Sources/AeolusHelper/. The scans of "
            + "the helper's sources skip that directory wholesale, so a target there can import "
            + "the helper and build its real graph where nothing looks"
    }

    /// Why `manifest`, read as raw text, changes a target after the package is constructed, or
    /// `nil` when it does not (#445). The dependency rule reads only the constructor's
    /// `dependencies:`, so `package.targets[3].dependencies.append("AeolusHelper")` would pass it.
    /// Raw text, comments included, as `flags(in:)` reads: prose naming one is a line to reword.
    static func mutationProblem(in manifest: String) -> String? {
        let mutations = [
            #"\.dependencies\s*(?:\+?=|\.\s*(?:append|insert))"#,
            #"(?<![A-Za-z0-9_])package\s*\.\s*targets(?![A-Za-z0-9_])"#,
        ]
        for pattern in mutations
        where manifest.range(of: pattern, options: .regularExpression) != nil {
            return "the manifest changes a target after the package is constructed (\(pattern)), "
                + "which the dependency rule does not read"
        }
        return nil
    }
}
