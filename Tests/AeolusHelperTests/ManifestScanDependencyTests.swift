import Foundation
import Testing

/// The part of the manifest scan that reads what a target depends on (#445), on synthetic text:
/// a scan that has silently stopped reading reports a clean tree, so each spelling it must see and
/// each it must refuse is a fixture. Nothing here touches a file; a manifest is a string. These
/// scans catch accidents; ADR 0014's compiler seam (the B1 seam amendment) is the control.
@Suite("The manifest scan's reading of dependencies")
struct ManifestScanDependencyTests {

    private static func dependencies(
        _ written: String, kind: String = "target"
    ) throws -> ManifestScan.Dependencies {
        try ManifestScanTests.target(
            #".\#(kind)(name: "X", dependencies: \#(written), path: "Sources/X")"#
        )
        .dependencies
    }

    /// Every spelling of a dependency that SwiftPM accepts and this reads: a bare string, and
    /// `.target`, `.byName` and `.product` with a `name:`, with a condition after it, written with
    /// spaces and across lines, with a trailing comma, empty, and left out altogether.
    ///
    /// **Mutations:** in `dependencyName`, stop reading a string literal; stop reading `.target`;
    /// stop reading `.byName`; stop reading `.product`. Run: red here, at that spelling, each.
    @Test("A dependency is read as a string, .target, .byName or .product, with or without more")
    func dependenciesAreReadInEverySpelling() throws {
        let spellings: [(written: String, names: [String])] = [
            (#"["AeolusHelper"]"#, ["AeolusHelper"]),
            (#"[.target(name: "AeolusHelper")]"#, ["AeolusHelper"]),
            (#"[.byName(name: "AeolusHelper")]"#, ["AeolusHelper"]),
            (#"[.product(name: "AeolusHelper", package: "Aeolus")]"#, ["AeolusHelper"]),
            (#"[. target ( name : "AeolusHelper" )]"#, ["AeolusHelper"]),
            (
                #"[.target(name: "AeolusHelper", condition: .when(platforms: [.macOS]))]"#,
                ["AeolusHelper"]
            ),
            (#"[.product(package: "Aeolus", name: "AeolusHelper")]"#, ["AeolusHelper"]),
            (
                "[\n    \"SMCCore\",\n    .target(\n        name: \"AeolusHelper\"),\n]",
                ["SMCCore", "AeolusHelper"]
            ),
            (
                """
                ["A", .target(name: "B"), .byName(name: "C"),
                 .product(name: "D", package: "p")]
                """,
                ["A", "B", "C", "D"]
            ),
            (#"[]"#, []),
        ]
        for (written, names) in spellings {
            #expect(try Self.dependencies(written) == .named(names), "\(written)")
        }
        #expect(
            try ManifestScanTests.target(#".target(name: "X", path: "Sources/X")"#).dependencies
                == .absent)
        let helper = try ManifestScanTests.target(
            #".testTarget(name: "T", dependencies: ["AeolusHelper"])"#)
        #expect(ManifestScan.dependsOnHelper(helper))
        let lookalikes = try ManifestScanTests.target(
            #".target(name: "T", dependencies: ["AeolusHelperTests", "MyAeolusHelper"])"#)
        #expect(!ManifestScan.dependsOnHelper(lookalikes))
    }

    /// A list this cannot read is `.unreadable`, never an empty or a partial list: it could hold
    /// the helper. The first group is not one array literal at all; the second is an array with an
    /// element that is not a name this reads — a variable, a `name:` that is not a plain string
    /// literal, a raw or escaped string, a call this does not know, a call with more after it, and
    /// `Target.Dependency.target` spelled in full.
    ///
    /// **Mutations:** in `dependencies(from:)`, answer `.named([])` for what is not an array
    /// literal; skip an element that cannot be read instead of refusing the list. Run: red here,
    /// at the first fixture of each group.
    @Test("A dependency list that is not readable as names is refused, never read as empty")
    func aDependencyListItCannotReadIsUnreadable() throws {
        let notAnArray = [
            "deps", "Self.deps", "makeDeps()", #"base + ["A"]"#, #"["A"] + extra"#,
            #"["A"] + ["B"]"#, #"["A", "B"] + ["C"]"#, #"["AeolusHelper"].filter { $0 != "" }"#,
            #"flag ? ["A"] : ["B"]"#,
        ]
        let badElement = [
            #"["A", dep]"#, #"["AeolusHelper", dep]"#, #"[.target(name: dep)]"#,
            #"[.target("AeolusHelper")]"#, #"[.product(package: "P")]"#, ##"[#"AeolusHelper"#]"##,
            #"["Aeolus\u{48}elper"]"#, #"["Aeolus" + "Helper"]"#, #"[cond ? "A" : "B"]"#,
            #"[.foo(name: "AeolusHelper")]"#, #"[Self.dep]"#, #"[("AeolusHelper")]"#,
            #"[.target(name: "AeolusHelper").self]"#, #"[.target(name: "AeolusHelper") + dep]"#,
            #"[Target.Dependency.target(name: "AeolusHelper")]"#, #"["A": "B"]"#,
        ]
        for written in notAnArray + badElement {
            let found = try Self.dependencies(written)
            guard case .unreadable = found else {
                Issue.record("\(written) was read as \(found)")
                continue
            }
        }
        // …and a target whose constructor never closes has no list to read.
        let unterminated = try ManifestScanTests.target(#".target(name: "X", dependencies: ["A"]"#)
        #expect(unterminated.dependencies == .unreadable("an unterminated constructor"))
    }

    /// **#445.** The route: a target that is not a test target and lists the helper, in any
    /// spelling and of any kind. A test target may. A list this cannot read is refused for every
    /// kind, a test target's included, because the pin on who depends on the helper cannot be
    /// kept over a list it cannot read.
    ///
    /// **Mutations:** in `dependencyProblem`, accept every kind; refuse every kind; accept a
    /// list that cannot be read. Run: red here, at the first non-test kind, the test target, and
    /// the unreadable list, respectively.
    @Test("Only a test target may list the helper, and a list that cannot be read is refused")
    func onlyATestTargetMayListTheHelper() throws {
        let spellings = [
            #""AeolusHelper""#, #".target(name: "AeolusHelper")"#,
            #".byName(name: "AeolusHelper")"#,
            #".product(name: "AeolusHelper", package: "Aeolus")"#,
        ]
        for kind in ManifestScan.targetKinds {
            for spelling in spellings {
                let written = #"["SMCCore", \#(spelling)]"#
                let target = try ManifestScanTests.target(
                    #".\#(kind)(name: "X", dependencies: \#(written), path: "Sources/X")"#)
                #expect(ManifestScan.dependsOnHelper(target), "\(kind) \(spelling)")
                let problem = ManifestScan.dependencyProblem(with: target)
                if kind == "testTarget" {
                    #expect(problem == nil, "\(kind) \(spelling): \(problem ?? "")")
                } else {
                    #expect(
                        problem?.contains("depends on AeolusHelper and is not a test target")
                            == true,
                        "\(kind) \(spelling): \(problem ?? "nil")")
                }
            }
        }
        for kind in ManifestScan.targetKinds {
            let clean = try ManifestScanTests.target(
                #".\#(kind)(name: "X", dependencies: ["SMCCore", "AeolusHelperTests"])"#)
            #expect(ManifestScan.dependencyProblem(with: clean) == nil, "\(kind)")
            let none = try ManifestScanTests.target(#".\#(kind)(name: "X")"#)
            #expect(ManifestScan.dependencyProblem(with: none) == nil, "\(kind)")
            let unreadable = try ManifestScanTests.target(
                #".\#(kind)(name: "X", dependencies: deps)"#)
            #expect(
                ManifestScan.dependencyProblem(with: unreadable)?.contains("cannot read") == true,
                "\(kind)")
        }
    }

    // MARK: - What a misplaced target is told

    /// **#445, N-3.** A target whose sources are somewhere the scans do not read is told why, and
    /// the reason is the true one: rule zero reads `Tests/`, so a non-test kind is not refused
    /// from there for being unread, and no message puts "a" before `executableTarget`.
    ///
    /// **Mutations:** put the old message back — "the only place the scans here read a \(kind)";
    /// make `problem(with:)` answer `nil` for a path outside the roots. Run: red here, the first
    /// at the first fixture and the second at the `#require` that a misplaced target is refused.
    @Test(
        "A misplaced target is told why, and the reason names no unread Tests/ and no bad article")
    func aMisplacedTargetIsToldTheTrueReason() throws {
        for kind in ManifestScan.targetKinds {
            for path in ["Probe/P", "Tests/P", "Sources/P"] {
                let target = try ManifestScanTests.target(
                    #".\#(kind)(name: "P", path: "\#(path)")"#)
                let belongs = kind == "testTarget" ? path == "Tests/P" : path == "Sources/P"
                let problem = ManifestScanTests.lookingFor(target).problem
                if belongs {
                    #expect(problem == nil, "\(kind) at \(path) was refused: \(problem ?? "")")
                    continue
                }
                let message = try #require(problem, "\(kind) at \(path) was not refused")
                #expect(!message.contains("the only place"), "\(kind) \(path): \(message)")
                #expect(
                    message.range(of: #"\ba [aeiouAEIOU]"#, options: .regularExpression) == nil,
                    "\(kind) \(path): \(message)")
                if kind == "testTarget" {
                    #expect(message.contains("rule zero reads only Tests/"), "\(message)")
                } else {
                    #expect(message.contains("rules for tests"), "\(kind) \(path): \(message)")
                }
            }
        }
        // The pair the wording was wrong about: a non-test kind under Tests/.
        let underTests = try ManifestScanTests.target(
            #".executableTarget(name: "P", path: "Tests/P")"#)
        let message = try #require(ManifestScanTests.lookingFor(underTests).problem)
        #expect(message.contains("not under Sources, Tools"), "\(message)")
        #expect(message.contains("a file under Tests/ is held only to the rules for tests"))
    }
}
