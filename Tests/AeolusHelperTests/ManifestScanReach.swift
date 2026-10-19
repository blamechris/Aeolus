import Foundation

/// What the manifest scan refuses beyond a dependency on the helper (#445's review), beside
/// `ManifestScan` and not in it: that enum is at its length ceilings, and `SeamScannerComments` is
/// the precedent for a sibling file holding more of the same type.
extension ManifestScan {

    /// The helper's directory, as components. Nothing but the helper takes its sources from it.
    static let helperDirectory = ["Sources", "AeolusHelper"]

    /// Whether `parts`, a resolved path, is inside the helper's directory. The components compare
    /// without case, as `manifestNames` compares names: this volume is case-insensitive, where
    /// `Sources/aeolushelper/Sub` is the helper's directory, and SwiftPM did not take the two for
    /// an overlap (#445's review).
    static func isInsideHelperDirectory(_ parts: [String]) -> Bool {
        parts.map { $0.lowercased() }.starts(with: helperDirectory.map { $0.lowercased() })
    }

    /// Why the arguments `target` was constructed with could put source in front of the compiler
    /// that the scans here do not read, or `nil` when they cannot (#445). Each is a refusal of a
    /// construct this package does not use, **read from the constructor's arguments and from
    /// nothing else**: a `path`, `exclude`, `sources` or `plugins` set on a let-bound target after
    /// construction is not seen. The refused arguments are:
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
            isInsideHelperDirectory(parts)
        else { return nil }
        return
            "\(called) takes its sources from \(path), inside Sources/AeolusHelper/. The scans of "
            + "the helper's sources skip that directory wholesale, so a target there can import "
            + "the helper and build its real graph where nothing looks"
    }

    /// Why `manifest`, read as raw text, matches one of two spellings of a change made after the
    /// package is constructed, or `nil` when it matches neither (#445). **A tripwire that catches
    /// by accident, not a rule.** The dependency rule reads only the constructor's `dependencies:`,
    /// so `target.dependencies.append("AeolusHelper")` placed after `Package(...)` would pass it;
    /// this matches that, `+=`, `=` and `.insert` on `.dependencies`, and any use of
    /// `package.targets`. It therefore also refuses the ordinary `package.dependencies +=
    /// [.package(…)]`, and keeps refusing it (fail closed).
    ///
    /// It does **not** catch a subscript assignment (`target.dependencies[0] = …`),
    /// `replaceSubrange`, a rebinding of `package`, or a `path`, `exclude`, `sources` or `plugins`
    /// set on a let-bound target after construction, which also gets past `reachProblem`. For a
    /// file outside `Sources/AeolusHelper/` the control is the import census, whatever the
    /// manifest says. Raw text, comments included, as `flags(in:)` reads: prose naming one of the
    /// two spellings is a line to reword.
    static func mutationProblem(in manifest: String) -> String? {
        let spellings: [(pattern: String, found: String)] = [
            (#"\.dependencies\s*(?:\+?=|\.\s*(?:append|insert))"#, "changes a dependency list"),
            (#"(?<![A-Za-z0-9_])package\s*\.\s*targets(?![A-Za-z0-9_])"#, "uses package.targets"),
        ]
        for (pattern, found) in spellings
        where manifest.range(of: pattern, options: .regularExpression) != nil {
            return "the manifest \(found) after the package is constructed (\(pattern)), which "
                + "the dependency rule does not read"
        }
        return nil
    }
}
