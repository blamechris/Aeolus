import Foundation
import Testing

/// The manifest and flag scans behind `SeamBuildSettingTests`, on synthetic text: a scan that has
/// silently stopped reading reports a clean tree, so each is held to the spellings it must see and
/// the ones it must not (#441). Nothing here touches a file; a manifest is a string.
@Suite("The manifest and build-flag scans")
struct ManifestScanTests {

    // MARK: - Which files are manifests

    /// **Mutation:** in `manifestNames`, accept only `Package.swift`. Run: red here (P02).
    @Test("Every root Package*.swift is a manifest, alternates included")
    func alternateManifestsAreFound() {
        let entries = [
            "Package.swift", "Package@swift-6.swift", "Package@swift-5.9.swift",
            "Package@swift-6.0.1.swift", "package@swift-6.swift", "Package.resolved",
            "Packages.md", "Sources", "README.md", "project.yml",
        ]
        #expect(
            ManifestScan.manifestNames(among: entries)
                == [
                    "Package.swift", "Package@swift-5.9.swift", "Package@swift-6.0.1.swift",
                    "Package@swift-6.swift", "package@swift-6.swift",
                ])
        #expect(
            ManifestScan.manifestNames(among: ["Sources", "Tests", "Package.resolved"]).isEmpty)
    }

    // MARK: - Flags

    /// **Mutation:** in `openingFlags`, drop `-enable-private-imports`. Run: red here, at each
    /// fixture that names it.
    @Test("A flag that opens private or SPI members is found wherever it is written")
    func openingFlagsAreFound() {
        let sources: [(text: String, found: [String])] = [
            (
                #".unsafeFlags(["-Xfrontend", "-disable-access-control"])"#,
                ["unsafeFlags", "-disable-access-control"]
            ),
            (
                #"swiftSettings: [.unsafeFlags(["-Xfrontend", "-enable-private-imports"])]"#,
                ["unsafeFlags", "-enable-private-imports"]
            ),
            ("run: swift test -Xswiftc -enable-private-imports", ["-enable-private-imports"]),
            ("swiftc -Xfrontend -disable-access-control main.swift", ["-disable-access-control"]),
            (
                "    OTHER_SWIFT_FLAGS: -Xfrontend -disable-access-control",
                ["-disable-access-control"]
            ),
            ("# swift test -Xswiftc -enable-private-imports", ["-enable-private-imports"]),
        ]
        for (text, found) in sources {
            #expect(ManifestScan.flags(in: text) == found, "\(text)")
        }
    }

    /// CI's release run passes `-enable-testing`, which keeps `@testable import` working and
    /// opens nothing the SPI or `private` closes.
    @Test("CI's -enable-testing is not an opening flag, nor is anything near one")
    func enableTestingIsAllowed() {
        for text in [
            "run: swift test -c release -Xswiftc -enable-testing",
            "swift test -Xswiftc -enable-testing -Xswiftc -warnings-as-errors",
            "-enable-private-import", "-disable-access", "safeFlags",
            "swiftSettings: [.swiftLanguageMode(.v6)]",
        ] {
            #expect(ManifestScan.flags(in: text).isEmpty, "\(text)")
        }
    }

    // MARK: - Targets

    private static func target(
        _ source: String
    ) throws -> ManifestScan.Target {
        let found = try ManifestScan.targets(in: source)
        return try #require(found.first, "no target was read from \(source)")
    }

    @Test("A target's kind, name and path are read, and a missing or odd path is told apart")
    func targetsAreRead() throws {
        let manifest = """
            .target(name: "A"),
            .executableTarget(name: "B", dependencies: ["A"], path: "Tools/B", exclude: ["x"]),
            .testTarget(name: "C", dependencies: [.target(name: "Probe")], path: "Tests/C"),
            .macro(name: "D", path: "Sources/D"),
            .plugin(name: "E", capability: .buildTool(), path: "Sources/E"),
            .systemLibrary(name: "F", path: "Sources/F"),
            .binaryTarget(name: "G", path: "Frameworks/G.xcframework"),
            .target(name: "H", path: "Tests/../Probe"),
            .target(name: "I", path: probePath),
            """
        let targets = try ManifestScan.targets(in: manifest)
        #expect(
            targets.map(\.kind) == [
                "target", "executableTarget", "testTarget", "macro", "plugin", "systemLibrary",
                "binaryTarget", "target", "target",
            ])
        #expect(targets.map(\.name) == ["A", "B", "C", "D", "E", "F", "G", "H", "I"])
        #expect(
            targets.map(\.path) == [
                .absent, .literal("Tools/B"), .literal("Tests/C"), .literal("Sources/D"),
                .literal("Sources/E"), .literal("Sources/F"),
                .literal("Frameworks/G.xcframework"), .literal("Tests/../Probe"),
                .computed("probePath"),
            ])
    }

    /// A constructor used as a dependency or a plugin declares nothing, and a comment is not a
    /// constructor; a `path:` inside a nested call is not the target's. A string that holds a
    /// constructor is read as one, which errs loud.
    ///
    /// **Mutation:** in `targets(in:)`, drop the skip of an enclosed constructor. Run: red here.
    @Test("Only declarations are targets")
    func onlyDeclarationsAreTargets() throws {
        let manifest = """
            // .target(name: "Commented", path: "Probe"),
            /* .testTarget(name: "Blocked", path: "Probe") */
            .target(
                name: "Real", dependencies: [.target(name: "Dep", path: "Probe"), "Other"],
                plugins: [.plugin(name: "Tool", package: "P")],
                resources: [.copy("path: nothing")], path: "Sources/Real"),
            """
        let targets = try ManifestScan.targets(in: manifest)
        #expect(targets == [.init(kind: "target", name: "Real", path: .literal("Sources/Real"))])
    }

    /// **Mutation:** in `topLevelArguments`, split on every comma and ignore strings. Run: red
    /// here, at the name.
    @Test("A literal path with a comma, a parenthesis or a colon is still one literal")
    func punctuationInAStringIsNotStructure() throws {
        let commas = try Self.target(
            #".target(name: "a,b", path: "Sources/a)b:c", exclude: ["x"])"#)
        #expect(commas.name == "a,b")
        #expect(commas.path == .literal("Sources/a)b:c"))
        let trailing = try Self.target(#".target(name: "A", path: "Sources/A",)"#)
        #expect(trailing.path == .literal("Sources/A"))
    }

    /// **P03.** A path SwiftPM would resolve but this cannot read is refused: the old pattern
    /// matched `path: "…"` only, so any of these read as no path at all, which is `Tests/<name>`.
    ///
    /// **Mutation:** in `targets(in:)`, treat a `path:` that is not a literal as absent. Run: red
    /// here, at the variable.
    @Test("A path that is not one string literal is a finding")
    func aComputedPathIsRefused() throws {
        for written in [
            "probePath", #""Te" + "sts/T""#, #""\(root)/T""#, ##"#"Probe"#"##,
            #"flag ? "Tests/T" : "Probe""#, #""Tests/T" + suffix"#, "Self.probe",
            #"String("Probe")"#,
        ] {
            let source = #".testTarget(name: "T", dependencies: [], path: \#(written))"#
            let target = try Self.target(source)
            guard case .computed = target.path else {
                Issue.record("\(source) was read as \(target.path)")
                continue
            }
            let problem = Self.lookingFor(target).problem
            #expect(
                problem?.contains("not a string literal") == true, "\(source): \(problem ?? "")")
        }
    }

    /// **P04.** The old check was `hasPrefix("Tests/")` on the literal, which `Tests/../Probe`
    /// satisfies.
    ///
    /// **Mutation:** in `resolved`, treat `..` as an ordinary component. Run: red here, at the
    /// first path.
    @Test("A path is resolved before it is required to be under a scanned root")
    func dotDotIsResolved() throws {
        let outside = [
            "Tests/../Probe", "Sources/../../Probe", "Tests/./../Tools/../Probe", "../Tests/T",
            "Tests/T/../../..", "/Users/me/Tests/T", "~/Tests/T", ".", "", "./", "Test/T",
            "tests/T", "Sources/../Package.swift/..",
        ]
        for path in outside {
            let target = ManifestScan.Target(kind: "target", name: "T", path: .literal(path))
            let problem = Self.lookingFor(target).problem
            #expect(problem?.contains("not under") == true, "\(path): \(problem ?? "nil")")
        }
        let inside: [(path: String, resolved: String)] = [
            ("Sources/T", "Sources/T"), ("Tests/T/", "Tests/T"), ("./Tests/T", "Tests/T"),
            ("Tests/../Sources/T", "Sources/T"), ("Tools/X/../Y", "Tools/Y"),
            ("Tests//T", "Tests/T"), ("Sources", "Sources"),
        ]
        for (path, resolved) in inside {
            let target = ManifestScan.Target(kind: "target", name: "T", path: .literal(path))
            let (problem, asked) = Self.lookingFor(target)
            #expect(problem == nil, "\(path): \(problem ?? "")")
            #expect(asked == [resolved], "\(path) was looked for at \(asked)")
        }
    }

    /// The problem found in `target` when every directory exists, and the directories asked about.
    private static func lookingFor(
        _ target: ManifestScan.Target, existing: Bool = true
    ) -> (problem: String?, asked: [String]) {
        var asked: [String] = []
        let problem = ManifestScan.problem(with: target) { path in
            asked.append(path)
            return existing
        }
        return (problem, asked)
    }

    /// **P06.** A `.target` whose sources are outside the three roots, linked into a test, is code
    /// no scan reads. Every constructor that declares a target is held to the same rule, and so is
    /// the directory it defaults to when it names no path.
    ///
    /// **Mutation:** in `targetKinds`, drop `target`. Run: red here, at the first kind.
    @Test("Every kind of target is held to the same rule, and a default directory must exist")
    func everyKindIsChecked() throws {
        for kind in ManifestScan.targetKinds {
            let outside = try Self.target(#".\#(kind)(name: "Probe", path: "Probe")"#)
            #expect(outside.kind == kind)
            #expect(Self.lookingFor(outside).problem != nil, "\(kind)")

            let inside = try Self.target(#".\#(kind)(name: "Probe", path: "Sources/Probe")"#)
            #expect(Self.lookingFor(inside).problem == nil, "\(kind)")
        }
        // No `path:`: SwiftPM looks in `Sources/<name>`, or `Tests/<name>` for a test target.
        let regular = try Self.target(#".target(name: "Probe", dependencies: [])"#)
        #expect(Self.lookingFor(regular) == (nil, ["Sources/Probe"]))
        let test = try Self.target(#".testTarget(name: "ProbeTests")"#)
        #expect(Self.lookingFor(test) == (nil, ["Tests/ProbeTests"]))
        let missing = Self.lookingFor(regular, existing: false).problem
        #expect(missing?.contains("not a directory") == true, "\(missing ?? "nil")")

        // A name that is not a literal has no default directory to look in.
        let unnamed = try Self.target(#".target(name: probe, dependencies: [])"#)
        #expect(Self.lookingFor(unnamed).problem?.contains("name:") == true)

        // A constructor that never closes cannot be read.
        let unterminated = try Self.target(#".target(name: "Probe", path: "Sources/Probe""#)
        #expect(Self.lookingFor(unterminated).problem != nil)
    }

    /// The manifests in this repository, as the scan reads them, are the ones it must accept.
    @Test("This package's own targets are accepted")
    func thePackageIsAccepted() throws {
        let manifest = try String(
            contentsOf: RuleZeroScan.repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8)
        let targets = try ManifestScan.targets(in: manifest)
        #expect(targets.count >= 15, "\(targets.count) targets")
        for target in targets {
            #expect(Self.lookingFor(target).problem == nil, "\(target)")
        }
        #expect(targets.contains { $0.name == "AeolusUI" && $0.path == .literal("Sources/Aeolus") })
    }
}
