import Foundation
import Testing

/// What the manifest scan refuses beyond a dependency on the helper (#445's review), and what each
/// rule reads. Saying what a rule reads is the point: "refused" is true of that and of nothing
/// else.
/// - **`reachProblem` reads a target's constructor arguments**, and the file system for one rule:
///   a `.plugin` target or a `plugins:` argument, a target whose `path:` resolves on disk to the
///   helper's directory or inside it, and an `exclude:` or `sources:` on the helper. Anything done
///   to a target after its constructor is not read.
/// - **`shapeProblem` reads the top level of a manifest:** exactly `import PackageDescription` and
///   one `let package = Package(…)`. Nothing after the constructor can then change it, and
///   `.macro`, which needs `import CompilerPluginSupport`, cannot be declared.
/// - **`packageDependencies` reads the package list as constructed**, which `HelperDependentsTests`
///   pins. The import census reads the files under `Sources/` outside the helper and under
///   `Tools/`; a file from another package is neither, and the pinned package's own sources are
///   read by nothing.
///
/// These scans catch accidents; a deliberate author can evade a lexical reading. ADR 0014's
/// compiler seam is the control.
///
/// A manifest is a string. The nested-path rule asks the file system where a directory is, so its
/// fixtures run against a temporary repository-shaped directory, built per test and removed after.
@Suite("The manifest scan's reading of constructor arguments that could hide source")
struct ManifestScanReachTests {

    /// A root for a fixture whose rule never asks the file system.
    private static let unused = URL(fileURLWithPath: "/")

    private static func problem(_ source: String, in root: URL = unused) throws -> String? {
        ManifestScan.reachProblem(with: try ManifestScanTests.target(source), under: root)
    }

    /// A temporary directory shaped like the repository: `Sources/AeolusHelper`, `Tests` and
    /// `Tools`, every directory `paths` names (resolved), and a decoy with a symbolic link to it. A
    /// fixture that spells a directory another way than it is stored (case, `.`, `..`) names the
    /// stored one here.
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
        // A decoy with the helper's directory in it, and a link to a directory inside the decoy:
        // `Link/../Sources/AeolusHelper/ZZ` is the helper's directory as SwiftPM appears to read
        // it (`..` applied to the text first; inferred from SYMDOT2) and the decoy's as `realpath`
        // reads it (the link followed).
        let inner = root.appendingPathComponent("decoy/inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("decoy/Sources/AeolusHelper/ZZ"),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Link"), withDestinationURL: inner)
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

    /// SwiftPM appears to apply `..` to the components of a `path:` as text; `realpath` follows a
    /// symbolic link before it applies `..`. For `Link/../Sources/AeolusHelper/ZZ`, with `Link` a
    /// link into a decoy, SwiftPM compiled the helper's directory and `realpath` of the written
    /// path named the decoy's, so the nested target was not seen and the suite stayed green
    /// (#445's review, SYMDOT2). That SwiftPM resolves the text first is inferred from that
    /// outcome, not read from SwiftPM's source. The path is resolved as text first and only then
    /// by the file system.
    ///
    /// **Mutation:** call `realPath` on the written path rather than on the resolved components.
    /// Run: red here.
    @Test("A symbolic link before a .. does not hide the helper's directory")
    func aLinkBeforeADotDotDoesNotHideTheDirectory() throws {
        try Self.withTree(containing: ["Sources/AeolusHelper/ZZ"]) { root in
            let found = try Self.problem(
                #".target(name: "ZZSupport", path: "Link/../Sources/AeolusHelper/ZZ")"#, in: root)
            #expect(found?.contains("inside Sources/AeolusHelper/") == true, "\(found ?? "nil")")
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

    /// A directory that cannot be located cannot be told from the helper's, so it is refused, and
    /// each cause says its own: a path that is not there, one that is absolute or climbs out of the
    /// repository (the text check refuses these before the file system is asked), one that is
    /// computed.
    ///
    /// **Mutations:** in `reachProblem`, accept a directory that does not resolve (red at the
    /// first fixture); say "does not resolve on disk" for every cause (red at the other three).
    @Test("A target whose directory cannot be located is refused, and each cause says why")
    func aDirectoryThatCannotBeLocatedIsRefused() throws {
        let causes: [(source: String, message: String)] = [
            (#".target(name: "Ghost", path: "Sources/Ghost")"#, "does not resolve on disk"),
            (#".target(name: "Absolute", path: "/etc")"#, "absolute or climbs out"),
            (#".target(name: "Climbing", path: "../Elsewhere")"#, "absolute or climbs out"),
            (#".target(name: "Computed", path: probePath)"#, "a path this cannot read"),
        ]
        try Self.withTree { root in
            for (source, message) in causes {
                let found = try Self.problem(source, in: root)
                #expect(found?.contains(message) == true, "\(source): \(found ?? "nil")")
                if message != "does not resolve on disk" {
                    #expect(
                        found?.contains("does not resolve") != true, "\(source): \(found ?? "")")
                }
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
}
