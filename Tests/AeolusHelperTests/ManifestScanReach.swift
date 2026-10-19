import Foundation

/// What the manifest scan refuses beyond a dependency on the helper (#445's review), beside
/// `ManifestScan` and not in it: that enum is at its length ceilings, and `SeamScannerComments` is
/// the precedent for a sibling file holding more of the same type.
///
/// Three rules live here, and each says what it reads and refuses only that: `reachProblem` reads
/// one target's constructor arguments and the file system; `shapeProblem` reads the top level of
/// a manifest; `packageDependencies` reads the root `Package(...)`'s `dependencies:` as
/// constructed.
///
/// These scans catch accidents; a deliberate author can evade a lexical reading. ADR 0014's
/// compiler seam is the control.
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
    /// that the scans here do not read, or `nil` when they cannot (#445).
    ///
    /// **Reads:** the constructor's `kind`, `name:`, `path:`, `exclude:`, `sources:` and
    /// `plugins:`, and for the nested-path rule the file system under `root`, the repository root.
    /// **Refuses**, of what it reads and nothing else:
    /// - **A plugin**, a `.plugin` target or a `plugins:` argument. A build-tool plugin generates
    ///   source into the target it is applied to, and no scan here reads generated source.
    /// - **A target inside the helper's directory.** The helper-only scans skip
    ///   `Sources/AeolusHelper/` wholesale, so a `.target` at `Sources/AeolusHelper/Sub`, with the
    ///   helper `exclude:`-ing `Sub`, imports the helper where nothing looks. The `path:` is
    ///   resolved as text first, `.` and `..` applied to the components as SwiftPM applies them
    ///   (`resolved(_:)`), and the result is then resolved by the file system and compared, as a
    ///   real path, with the helper's. A `..` after a symbolic link is therefore not followed
    ///   through the link: `realpath` would, and SwiftPM does not. A directory that does not
    ///   resolve, a path that is absolute or climbs out of the repository, and a path that cannot
    ///   be read are each refused (fail closed), each with its own message.
    /// - **A helper that excludes or adds sources.** `exclude:` and `sources:` are how the helper
    ///   would hand part of its directory to another target, or take files from elsewhere; it has
    ///   neither.
    ///
    /// It does not read anything done to a target after its constructor.
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
        guard let declared = declaredDirectory(of: target) else {
            return
                "\(called) takes its sources from a path this cannot read (a computed path, or a "
                + "name that is not a literal), so whether it is inside Sources/AeolusHelper/ "
                + "cannot be told"
        }
        guard let parts = resolved(declared) else {
            return
                "\(called) takes its sources from \(declared), which is absolute or climbs out of "
                + "the repository, so whether it is inside Sources/AeolusHelper/ cannot be told"
        }
        guard let real = realPath(root.path + "/" + parts.joined(separator: "/")),
            let helper = realPath(root.path + "/" + helperDirectory)
        else {
            return
                "\(called) takes its sources from \(declared), which does not resolve on disk, so "
                + "whether it is inside Sources/AeolusHelper/ cannot be told"
        }
        guard real == helper || real.hasPrefix(helper + "/") else { return nil }
        return
            "\(called) takes its sources from \(declared), inside Sources/AeolusHelper/. The scans "
            + "of the helper's sources skip that directory wholesale, so a target there can import "
            + "the helper and build its real graph where nothing looks"
    }

    // MARK: - The top level of the manifest

    /// Why the top level of `manifest` is not exactly `import PackageDescription` followed by one
    /// `let package = Package(…)`, or `nil` when it is (#445's review).
    ///
    /// **Reads:** the manifest with its comments removed, at the top level only: what comes before
    /// the constructor, where the constructor ends, and what comes after it. **Refuses** anything
    /// else there: another import (`import CompilerPluginSupport`, which `.macro` needs), a `let`,
    /// `var`, `func`, `#if` or expression before or after, a package bound to another name or with
    /// a type annotation. That leaves no top-level statement to change a target or the package once
    /// it is constructed, and no top-level declaration for the constructor to read a dependency
    /// list from. Today's manifest is exactly this shape.
    ///
    /// It does not read inside the constructor: an expression there is the constructor's arguments,
    /// which `targets(in:)`, `dependencyProblem`, `reachProblem` and `packageDependencies` read.
    static func shapeProblem(in manifest: String) -> String? {
        let code = SeamScanner.strippingAllComments(manifest)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let importEnd = code.range(
                of: #"^import\s+PackageDescription(?![A-Za-z0-9_])"#, options: .regularExpression)
        else {
            return
                "the manifest does not begin with import PackageDescription and nothing before it"
        }
        let rest = code[importEnd.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let head = rest.range(
                of: #"^let\s+package\s*=\s*Package\s*\("#, options: .regularExpression)
        else {
            return "import PackageDescription is not followed by let package = Package( and "
                + "nothing else: \(rest.prefix(60))"
        }
        let open = rest.index(before: head.upperBound)
        guard let close = SeamScanner.closingParenthesis(in: rest, openingAt: open) else {
            return "the manifest's Package( never closes"
        }
        let after = rest[rest.index(after: close)...].trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard after.isEmpty else {
            return "something follows Package(…) at the top level: \(after.prefix(60))"
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

    /// The package-level dependencies `manifest` declares as constructed (#445's review).
    ///
    /// **Reads:** the root `Package(...)`'s `dependencies:` argument, and nothing after it. The
    /// target-level rule pins who may depend on the helper; this pins what else is in the build. A
    /// package that is not this one, local (`.package(path: "ZZLocal")`) or remote, compiles Swift
    /// no scan here reads: its sources can `@testable import AeolusHelper`, and under an
    /// incremental build they compile. A file from another package is not under `Sources/` outside
    /// the helper or under `Tools/`, which is what the import census reads, so the list is pinned
    /// instead (`HelperDependentsTests.pinnedPackages`). The pinned package's own sources are read
    /// by nothing. Nothing here stops a change to the list after the constructor;
    /// `shapeProblem` refuses a manifest that has anything after it.
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
