import Foundation
import Testing

/// What the manifest scan refuses beyond a dependency on the helper (#445's review). Three
/// different things, and the difference is the point:
/// - **Constructor arguments, refused outright:** a `.plugin` target or a `plugins:` argument, a
///   target whose `path:` resolves on disk to the helper's directory or inside it, and an
///   `exclude:` or `sources:` on the helper. Each is read from the arguments a constructor was
///   written with, and none is used today. A `path`, `exclude`, `sources` or `plugins` set on a
///   let-bound target after construction is not a constructor argument, and is not seen.
/// - **A tripwire that catches by accident:** `mutationProblem` matches two raw-text spellings of a
///   change after the package is constructed. It does not catch, for example, a subscript
///   assignment, `replaceSubrange`, an inout pass such as `zzAdd(&zzSupport.dependencies)`, a
///   backticked ``.`dependencies` ``, a key-path write, or a rebinding of `package`. The list is
///   not exhaustive.
/// - **A pin:** the root `Package(...)`'s package-level `dependencies:` are pinned in
///   `HelperDependentsTests`. The import census reads the files under `Sources/` outside the
///   helper and under `Tools/`; a file from another package is refused by the pin, not read by the
///   census, and the pinned package's own sources are read by nothing.
///
/// These scans catch accidents. ADR 0014's compiler seam is the real control.
///
/// A manifest is a string. The nested-path rule asks the file system where a directory is, so its
/// fixtures run against a temporary repository-shaped directory, built per test and removed after.
@Suite("The manifest scan's refusal of what could hide source from the scans")
struct ManifestScanReachTests {

    /// A root for a fixture whose rule never asks the file system.
    private static let unused = URL(fileURLWithPath: "/")

    private static func problem(_ source: String, in root: URL = unused) throws -> String? {
        ManifestScan.reachProblem(with: try ManifestScanTests.target(source), under: root)
    }

    /// A temporary directory shaped like the repository: `Sources/AeolusHelper`, `Tests` and
    /// `Tools`, and every directory `paths` names, resolved. A fixture that spells a directory
    /// another way than it is stored (case, `.`, `..`) names the stored one here.
    private static func withTree<T>(
        containing paths: [String] = [], _ body: (URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aeolus-reach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories =
            ["Sources/AeolusHelper", "Tests", "Tools"]
            + paths.compactMap { ManifestScan.resolved($0)?.joined(separator: "/") }
        for directory in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        return try body(root)
    }

    // MARK: - A target inside the helper's directory

    /// The helper-only scans skip `Sources/AeolusHelper/`, so a target nested there imports the
    /// helper unseen. The target's directory and the helper's are both resolved by the file system
    /// and compared as real paths.
    ///
    /// **Mutations:** in `reachProblem`, resolve the helper's directory to another directory (red
    /// at the first fixture); compare the written path rather than the resolved one (red at the
    /// `./` and `..` fixtures); compare as a string prefix (red at `Sources/AeolusHelperKit`, in
    /// the neighbours test).
    @Test("A target other than the helper that takes its sources from inside the helper is refused")
    func aNestedTargetIsRefused() throws {
        let paths = [
            "Sources/AeolusHelper/ZZSub", "Sources/AeolusHelper", "Sources/AeolusHelper/",
            "Sources/./AeolusHelper/ZZ", "Tests/../Sources/AeolusHelper/ZZ/Deep",
            "Sources//AeolusHelper/ZZ",
        ]
        try Self.withTree(containing: paths) { root in
            for path in paths {
                for kind in ["target", "executableTarget"] {
                    let found = try Self.problem(
                        #".\#(kind)(name: "ZZSupport", path: "\#(path)")"#, in: root)
                    #expect(
                        found?.contains("inside Sources/AeolusHelper/") == true,
                        "\(kind) at \(path): \(found ?? "nil")")
                }
            }
            // No name to compare is not the helper.
            let unnamed = try Self.problem(
                #".target(name: zz, path: "Sources/AeolusHelper/ZZ")"#, in: root)
            #expect(
                unnamed?.contains("inside Sources/AeolusHelper/") == true, "\(unnamed ?? "nil")")
            // …nor is a default directory that is the helper's under another case.
            let defaulted = try Self.problem(#".target(name: "aeolushelper")"#, in: root)
            #expect(defaulted != nil, "\(defaulted ?? "nil")")
        }
    }

    /// The same directory under a spelling the volume treats as equal: other case, and a letter
    /// APFS folds to another (`ſ`, U+017F, folds to `s`). Compared as written, SwiftPM took none of
    /// them for an overlap with the helper and the suite stayed green (#445's review, P3b-case
    /// and FOLD). Resolved by the file system, each is the helper's directory where the volume
    /// folds, and a directory that does not resolve where it does not: refused either way.
    ///
    /// **Mutation:** compare the written path rather than the resolved one (red at all four).
    @Test("A directory the volume treats as the helper's under another spelling is refused")
    func aRespelledNestedDirectoryIsRefused() throws {
        let spellings = [
            "Sources/aeolushelper/ZZSub", "sources/AeolusHelper/ZZ", "SOURCES/AEOLUSHELPER",
            "Sources/AeoluſHelper/ZZSub",
        ]
        let stored = ["Sources/AeolusHelper/ZZSub", "Sources/AeolusHelper/ZZ"]
        try Self.withTree(containing: stored) { root in
            for path in spellings {
                let found = try Self.problem(
                    #".target(name: "ZZSupport", path: "\#(path)")"#, in: root)
                #expect(found != nil, "\(path): \(found ?? "nil")")
            }
        }
    }

    /// The helper's own directory is the helper's, and so are lookalikes of it that are not inside.
    ///
    /// **Mutations:** in `reachProblem`, stop recognising the helper by name (red at the
    /// explicit-path fixtures, which the nested rule then refuses, and at the real manifest);
    /// compare as a string prefix (red at `AeolusHelperKit`).
    @Test("The helper in its own directory, and a neighbour that only shares its prefix, are not")
    func theHelperAndItsNeighboursAreNotNested() throws {
        let sources = [
            #".executableTarget(name: "AeolusHelper", dependencies: ["SMCCore"])"#,
            #".executableTarget(name: "AeolusHelper", path: "Sources/AeolusHelper")"#,
            #".executableTarget(name: "AeolusHelper", path: "Sources/AeolusHelper/")"#,
            #".target(name: "AeolusHelperKit", path: "Sources/AeolusHelperKit")"#,
            #".target(name: "Other", path: "Sources/Other")"#,
            #".target(name: "AeolusUI", path: "Sources/Aeolus")"#,
            #".testTarget(name: "AeolusHelperTests", path: "Tests/AeolusHelperTests")"#,
            #".executableTarget(name: "tool", path: "Tools/Tool", exclude: ["README.md"])"#,
        ]
        let directories = [
            "Sources/AeolusHelperKit", "Sources/Other", "Sources/Aeolus", "Tests/AeolusHelperTests",
            "Tools/Tool",
        ]
        try Self.withTree(containing: directories) { root in
            for source in sources {
                let found = try Self.problem(source, in: root)
                #expect(found == nil, "\(source): \(found ?? "")")
            }
        }
    }

    /// A directory that does not resolve cannot be told from the helper's, so it is refused: a
    /// path that is not there, one that is absolute, one that climbs out of the repository, one
    /// that is computed.
    ///
    /// **Mutation:** in `reachProblem`, accept a directory that does not resolve (red at all
    /// four).
    @Test("A target whose directory does not resolve is refused, not passed")
    func aDirectoryThatDoesNotResolveIsRefused() throws {
        try Self.withTree { root in
            for source in [
                #".target(name: "Ghost", path: "Sources/Ghost")"#,
                #".target(name: "Absolute", path: "/etc")"#,
                #".target(name: "Climbing", path: "../Elsewhere")"#,
                #".target(name: "Computed", path: probePath)"#,
            ] {
                let found = try Self.problem(source, in: root)
                #expect(
                    found?.contains("does not resolve on disk") == true,
                    "\(source): \(found ?? "nil")")
            }
        }
    }

    // MARK: - A helper that excludes or adds sources

    /// **Mutations:** in `reachProblem`, drop `exclude` from the helper's refused labels; drop
    /// `sources`; refuse `exclude:` on every target and not the helper alone (red at the
    /// `tool` fixture, and at the real manifest, whose tools exclude their READMEs).
    @Test("A helper that takes exclude: or sources: is refused")
    func aHelperThatSharesItsDirectoryIsRefused() throws {
        for label in ["exclude", "sources"] {
            let found = try Self.problem(
                #".executableTarget(name: "AeolusHelper", dependencies: [], \#(label): ["ZZSub"])"#
            )
            #expect(
                found?.contains("takes an \(label): argument") == true,
                "\(label): \(found ?? "nil")")
        }
    }

    // MARK: - A plugin

    /// Source a build-tool plugin generates is read by no scan. A `.plugin` target and any
    /// `plugins:` argument are refused; a `.plugin(name:package:)` used inside `plugins:` is
    /// the argument's, and is not a target of its own.
    ///
    /// **Mutations:** in `reachProblem`, drop the `.plugin` kind (red at the first fixture); drop
    /// the `plugins:` label (red at the rest).
    @Test("A plugin target, or a target that applies a plugin, is refused")
    func aPluginIsRefused() throws {
        let kind = try Self.problem(
            #".plugin(name: "ZZGen", capability: .buildTool(), path: "Sources/ZZGen")"#)
        #expect(kind?.contains("is or uses a plugin") == true, "\(kind ?? "nil")")
        for source in [
            #".testTarget(name: "AeolusHelperTests", dependencies: [], plugins: ["ZZGen"])"#,
            #".target(name: "X", plugins: [.plugin(name: "Tool", package: "P")])"#,
            #".executableTarget(name: "AeolusHelper", plugins: ["ZZGen"])"#,
        ] {
            let found = try Self.problem(source)
            #expect(found?.contains("is or uses a plugin") == true, "\(source): \(found ?? "nil")")
        }
        // A plugin used inside `plugins:` declares nothing of its own.
        let targets = try ManifestScan.targets(
            in: #".target(name: "X", plugins: [.plugin(name: "Tool", package: "P")])"#)
        #expect(targets.map(\.kind) == ["target"])
        #expect(targets.first?.labels == ["name", "plugins"])
    }

    // MARK: - A change after construction

    /// The constructor's `dependencies:` is all the dependency rule reads, so a dependency added
    /// afterwards passes it. The raw text is refused, comments included, as the flags are.
    ///
    /// This is a tripwire that matches two spellings, by accident, and the fixtures say no more
    /// than that. The package-level `package.dependencies +=` is refused too, because the first
    /// pattern cannot tell it from a target's.
    ///
    /// **Mutations:** in `mutationProblem`, drop the first pattern (red at the fixtures that name
    /// only `.dependencies`, the package-level one included); drop the second (red at the ones
    /// that name only `package.targets`).
    @Test("A manifest that matches either spelling of a change after construction is refused")
    func aChangeAfterConstructionIsRefused() throws {
        for source in [
            #"for target in everyTarget { target.dependencies.append("AeolusHelper") }"#,
            #"target.dependencies += ["AeolusHelper"]"#,
            #"target.dependencies = ["AeolusHelper"]"#,
            #"target.dependencies . insert("AeolusHelper", at: 0)"#,
            #"package.dependencies += [.package(url: "https://example.com/x.git", from: "1.0.0")]"#,
            "let all = package.targets",
            "package . targets.removeAll()",
            #"package.targets[3].dependencies.append("AeolusHelper")"#,
            #"// package.targets is read here"#,
        ] {
            #expect(ManifestScan.mutationProblem(in: source) != nil, "\(source)")
        }
        for source in [
            #".target(name: "A", dependencies: ["B"]),"#,
            "let package = Package(name: \"Aeolus\", targets: [])",
            "let mypackage = 1; mypackage.targets",
            "package.targetsCount",
            #"dependencies: [.package(url: "https://example.com/x.git", from: "1.0.0")],"#,
            "// the dependencies are listed in the constructor",
        ] {
            #expect(ManifestScan.mutationProblem(in: source) == nil, "\(source)")
        }
    }

    /// The message says which spelling matched. The first pattern matches a package's own
    /// dependency list as well as a target's, and the message used to say it "changes a target".
    ///
    /// **Mutations:** in `mutationProblem`, say "changes a target" for the first pattern (red at
    /// the first fixture); say it for the second (red at the second).
    @Test("The refusal of a change after construction says what it matched")
    func theRefusalSaysWhatItMatched() throws {
        let package = try #require(
            ManifestScan.mutationProblem(
                in:
                    #"package.dependencies += [.package(url: "https://example.com/x.git", from: "1.0.0")]"#
            ))
        #expect(package.contains("changes a dependency list after the package is constructed"))
        #expect(!package.contains("changes a target"), "\(package)")
        let targets = try #require(ManifestScan.mutationProblem(in: "let all = package.targets"))
        #expect(targets.contains("uses package.targets after the package is constructed"))
        #expect(!targets.contains("changes a target"), "\(targets)")
    }
}
