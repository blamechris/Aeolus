import Foundation
import Testing

/// What the manifest scan refuses beyond a dependency on the helper (#445's review). Two different
/// things, and the difference is the point:
/// - **Constructor arguments, refused outright:** a `.plugin` target or a `plugins:` argument, a
///   target whose `path:` is inside the helper's directory, and an `exclude:` or `sources:` on the
///   helper. Each is read from the arguments a constructor was written with, and none is used
///   today. A `path`, `exclude`, `sources` or `plugins` set on a let-bound target after
///   construction is not a constructor argument, and is not seen.
/// - **A tripwire that catches by accident:** `mutationProblem` matches two raw-text spellings of a
///   change after the package is constructed. It does not catch a subscript assignment,
///   `replaceSubrange`, or a rebinding of `package`. For a file outside `Sources/AeolusHelper/`
///   the control is the import census, whatever the manifest says.
///
/// A manifest is a string.
@Suite("The manifest scan's refusal of what could hide source from the scans")
struct ManifestScanReachTests {

    private static func problem(_ source: String) throws -> String? {
        ManifestScan.reachProblem(with: try ManifestScanTests.target(source))
    }

    // MARK: - A target inside the helper's directory

    /// The helper-only scans skip `Sources/AeolusHelper/`, so a target nested there imports the
    /// helper unseen. The path is resolved before it is compared, and compared by component and
    /// without case: this volume is case-insensitive, where `Sources/aeolushelper/ZZSub` is inside.
    ///
    /// **Mutations:** in `reachProblem`, drop the nested-path rule (red at the first fixture);
    /// compare the written path rather than the resolved one (red at the `./` and `..` fixtures);
    /// compare as a string prefix (red at `Sources/AeolusHelperKit`, which is not inside); compare
    /// with case (red at the three differently-cased fixtures).
    @Test("A target other than the helper that takes its sources from inside the helper is refused")
    func aNestedTargetIsRefused() throws {
        for path in [
            "Sources/AeolusHelper/ZZSub", "Sources/AeolusHelper", "Sources/AeolusHelper/",
            "Sources/./AeolusHelper/ZZ", "Tests/../Sources/AeolusHelper/ZZ/Deep",
            "Sources//AeolusHelper/ZZ", "Sources/aeolushelper/ZZSub", "sources/AeolusHelper/ZZ",
            "SOURCES/AEOLUSHELPER",
        ] {
            for kind in ["target", "executableTarget"] {
                let found = try Self.problem(#".\#(kind)(name: "ZZSupport", path: "\#(path)")"#)
                #expect(
                    found?.contains("inside Sources/AeolusHelper/") == true,
                    "\(kind) at \(path): \(found ?? "nil")")
            }
        }
        // No name to compare is not the helper.
        let unnamed = try Self.problem(#".target(name: zz, path: "Sources/AeolusHelper/ZZ")"#)
        #expect(unnamed?.contains("inside Sources/AeolusHelper/") == true, "\(unnamed ?? "nil")")
    }

    /// The helper's own directory is the helper's, and so are lookalikes of it that are not inside.
    ///
    /// **Mutations:** in `reachProblem`, stop recognising the helper by name (red at the
    /// explicit-path fixtures, which the nested rule then refuses, and at the real manifest);
    /// compare as a string prefix (red at `AeolusHelperKit`).
    @Test("The helper in its own directory, and a neighbour that only shares its prefix, are not")
    func theHelperAndItsNeighboursAreNotNested() throws {
        for source in [
            #".executableTarget(name: "AeolusHelper", dependencies: ["SMCCore"])"#,
            #".executableTarget(name: "AeolusHelper", path: "Sources/AeolusHelper")"#,
            #".executableTarget(name: "AeolusHelper", path: "Sources/AeolusHelper/")"#,
            #".target(name: "AeolusHelperKit", path: "Sources/AeolusHelperKit")"#,
            #".target(name: "Other", path: "Sources/Other")"#,
            #".target(name: "AeolusUI", path: "Sources/Aeolus")"#,
            #".testTarget(name: "AeolusHelperTests", path: "Tests/AeolusHelperTests")"#,
            #".executableTarget(name: "tool", path: "Tools/Tool", exclude: ["README.md"])"#,
        ] {
            #expect(try Self.problem(source) == nil, "\(source)")
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
