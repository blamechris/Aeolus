import Foundation

/// What the manifest scan refuses beyond a dependency on the helper (#445's review), beside
/// `ManifestScan` and not in it: that enum is at its length ceilings, and `SeamScannerComments` is
/// the precedent for a sibling file holding more of the same type.
///
/// These scans catch accidents. ADR 0014's compiler seam is the real control.
extension ManifestScan {

    // MARK: - A target inside the helper's directory

    /// The helper's directory, from the repository root.
    static let helperDirectory = "Sources/AeolusHelper"

    /// `path` as the file system resolves it: symbolic links followed, `.` and `..` gone, and on a
    /// case-insensitive volume the case the directory is stored with. `nil` when it does not
    /// resolve. A written path cannot be compared by its spelling: this volume is case-insensitive,
    /// where `Sources/aeolushelper/Sub` and `Sources/AeoluſHelper/Sub` (U+017F, which APFS folds to
    /// `s`) both name the helper's directory, and SwiftPM took neither for an overlap with it
    /// (#445's review).
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The directory `target` takes its sources from as written, or `nil` when it cannot be read:
    /// the `path:` literal, or the default SwiftPM takes when there is none.
    static func declaredDirectory(of target: Target) -> String? {
        switch target.path {
        case .literal(let path):
            return path
        case .absent:
            return target.name.map { (target.kind == "testTarget" ? "Tests/" : "Sources/") + $0 }
        case .computed:
            return nil
        }
    }

    /// Why the arguments `target` was constructed with could put source in front of the compiler
    /// that the scans here do not read, or `nil` when they cannot (#445). Each is a refusal of a
    /// construct this package does not use, **read from the constructor's arguments and from
    /// nothing else**: a `path`, `exclude`, `sources` or `plugins` set on a let-bound target after
    /// construction is not seen. `root` is the repository root, which the nested-path rule needs
    /// to ask the file system where a directory is. The refused arguments are:
    /// - **A plugin**, a `.plugin` target or a `plugins:` argument. A build-tool plugin generates
    ///   source into the target it is applied to, and no scan here reads generated source: not rule
    ///   zero, not the SPI censuses, not the import census.
    /// - **A target inside the helper's directory.** The helper-only scans skip
    ///   `Sources/AeolusHelper/` wholesale, so a `.target` at `Sources/AeolusHelper/Sub`, with the
    ///   helper `exclude:`-ing `Sub`, imports the helper and builds its real graph where nothing
    ///   looks. The target's directory and the helper's are both resolved by the file system and
    ///   compared as real paths; a directory that does not resolve is refused (fail closed).
    /// - **A helper that excludes or adds sources.** `exclude:` and `sources:` are how the helper
    ///   would hand part of its directory to another target, or take files from elsewhere; it has
    ///   neither.
    static func reachProblem(with target: Target, under root: URL) -> String? {
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
        guard let declared = declaredDirectory(of: target), resolved(declared) != nil,
            let real = realPath(root.path + "/" + declared),
            let helper = realPath(root.path + "/" + helperDirectory)
        else {
            return
                "\(called) takes its sources from a directory that does not resolve on disk "
                + "(\(declaredDirectory(of: target) ?? "a path that cannot be read")), so whether "
                + "it is inside Sources/AeolusHelper/ cannot be told"
        }
        guard real == helper || real.hasPrefix(helper + "/") else { return nil }
        return
            "\(called) takes its sources from \(declared), inside Sources/AeolusHelper/. The scans "
            + "of the helper's sources skip that directory wholesale, so a target there can import "
            + "the helper and build its real graph where nothing looks"
    }

    // MARK: - A change after the package is constructed

    /// Why `manifest`, read as raw text, matches one of two spellings of a change made after the
    /// package is constructed, or `nil` when it matches neither (#445). **A tripwire that catches
    /// by accident, not a rule.** The dependency rule reads only the constructor's `dependencies:`,
    /// so `target.dependencies.append("AeolusHelper")` placed after `Package(...)` would pass it;
    /// this matches that, `+=`, `=` and `.insert` on `.dependencies`, and any use of
    /// `package.targets`. It therefore also refuses the ordinary `package.dependencies +=
    /// [.package(…)]`, and keeps refusing it (fail closed).
    ///
    /// It does **not** catch, for example, a subscript assignment (`target.dependencies[0] = …`),
    /// `replaceSubrange`, an inout pass (`zzAdd(&zzSupport.dependencies)`), a backticked
    /// ``.`dependencies` ``, a key-path write, a rebinding of `package`, or a `path`, `exclude`,
    /// `sources` or `plugins` set on a let-bound target after construction, which also gets past
    /// `reachProblem`. The list is not exhaustive. What the import census reads is the files under
    /// `Sources/` outside the helper and under `Tools/`; a file from another package is refused by
    /// the package-level dependency pin below, whatever the target lists. Raw text, comments
    /// included, as `flags(in:)` reads: prose naming one of the two spellings is a line to reword.
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

    // MARK: - The package's own dependencies

    /// What the root `Package(...)` lists in its package-level `dependencies:`.
    enum PackageDependencies: Equatable {
        /// No `dependencies:` argument.
        case absent
        /// One array literal, every element of which was read as `.package(url:…)`,
        /// `.package(path:…)` or `.package(id:…)` with a string literal: `label: value`, in order.
        case listed([String])
        /// Anything else, as written, or the first element that could not be read, or a manifest
        /// that does not hold exactly one `Package(...)`. A finding, never an empty list.
        case unreadable(String)
    }

    /// The package-level dependencies `manifest` declares (#445's review). The target-level rule
    /// pins who may depend on the helper; this pins what else is in the build. A package that is
    /// not this one, local (`.package(path: "ZZLocal")`) or remote, compiles Swift this package's
    /// scans do not read: its sources can `@testable import AeolusHelper`, and under an
    /// incremental build they compile. The import census reads files under `Sources/`
    /// outside the helper and under `Tools/`, and a file from another package is none of those, so
    /// the package list is pinned instead (`HelperDependentsTests.pinnedPackages`). That also
    /// closes the `.macro` route, which needs swift-syntax, a package the pin does not list. The
    /// pinned package's own sources are read by nothing.
    static func packageDependencies(in manifest: String) throws -> PackageDependencies {
        let code = SeamScanner.strippingAllComments(manifest)
        let constructor = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])Package\s*\("#)
        let found = constructor.matches(in: code, range: NSRange(code.startIndex..., in: code))
        guard found.count == 1, let whole = Range(found[0].range, in: code) else {
            return .unreadable("\(found.count) Package(…) constructors")
        }
        let open = code.index(before: whole.upperBound)
        guard let close = SeamScanner.closingParenthesis(in: code, openingAt: open) else {
            return .unreadable("a Package( that never closes")
        }
        let arguments = topLevelArguments(of: code[code.index(after: open)..<close])
        guard let written = arguments.first(where: { $0.label == "dependencies" })?.value else {
            return .absent
        }
        guard written.hasPrefix("["), written.hasSuffix("]") else { return .unreadable(written) }
        var listed: [String] = []
        for element in topLevelArguments(of: written.dropFirst().dropLast()) {
            guard element.label == nil, let identity = packageIdentity(element.value) else {
                return .unreadable(element.value)
            }
            listed.append(identity)
        }
        return .listed(listed)
    }

    /// `label: value` for the first of `url`, `path` and `id` that one `.package(…)` element gives
    /// as a string literal, or `nil` when the element is not that call, has more after it, or
    /// names its package some other way.
    private static func packageIdentity(_ element: String) -> String? {
        guard let head = element.range(of: #"^\.\s*package\s*\("#, options: .regularExpression)
        else { return nil }
        let open = element.index(before: head.upperBound)
        let last = element.index(before: element.endIndex)
        guard SeamScanner.closingParenthesis(in: element, openingAt: open) == last else {
            return nil
        }
        let arguments = topLevelArguments(of: element[element.index(after: open)..<last])
        for label in ["url", "path", "id"] {
            guard let value = arguments.first(where: { $0.label == label })?.value,
                let text = literal(value)
            else { continue }
            return "\(label): \(text)"
        }
        return nil
    }
}
