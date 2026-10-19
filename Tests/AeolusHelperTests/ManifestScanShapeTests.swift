import Foundation
import Testing

/// The top-level shape rule (#445's review), on synthetic text. It reads the top level of a
/// manifest, comments removed, and refuses anything but `import PackageDescription` followed by one
/// `let package = Package(…)`. Inside the constructor it reads nothing: those arguments are read by
/// the rules that read arguments. What it leaves a manifest with is no statement after the
/// constructor to change a target or the package, no declaration before it for the constructor to
/// read from, and no `import CompilerPluginSupport`, which a `.macro` target needs. A manifest is
/// a string.
///
/// These scans catch accidents; a deliberate author can evade a lexical reading. ADR 0014's
/// compiler seam is the control.
@Suite("The manifest scan's reading of the top level")
struct ManifestScanShapeTests {

    private static let good =
        #"let package = Package(name: "Aeolus", targets: [.target(name: "A")])"#

    /// The shapes that are exactly `import PackageDescription` and one `let package = Package(…)`,
    /// however the comments and whitespace fall, and a constructor with strings and brackets of its
    /// own.
    ///
    /// **Mutation:** in `shapeProblem`, read the text with its comments in it. Run: red here, at
    /// the second and third fixtures.
    @Test("The shape the package has is accepted, with comments and whitespace anywhere")
    func theShapeIsAccepted() {
        let accepted = [
            "import PackageDescription\n\(Self.good)",
            "// swift-tools-version: 6.0\nimport PackageDescription\n\n// the package\n"
                + "\(Self.good)\n// end\n",
            "/* header */ import PackageDescription /* x */ \(Self.good) /* y */",
            """
            import PackageDescription

            let package = Package(
                name: "Aeolus (a)",
                targets: [.target(name: "A", dependencies: ["B"], path: "Sources/A (1)")]
            )
            """,
        ]
        for source in accepted {
            #expect(ManifestScan.shapeProblem(in: source) == nil, "\(source)")
        }
    }

    /// A statement, declaration or expression before the constructor. A top-level `let` is what a
    /// constructor argument could read a dependency list from (DVAR); an import other than
    /// `PackageDescription` is what `.macro` needs.
    ///
    /// **Mutations:** in `shapeProblem`, accept any import (red at the three fixtures that add
    /// one); accept something between the import and the constructor, by not anchoring `let
    /// package` (red at the seven that put one there); accept a `let` or `var` of any name or type
    /// (red at the last three).
    @Test("A statement or another import before the constructor is refused")
    func aStatementBeforeTheConstructorIsRefused() {
        let before: [(source: String, message: String)] = [
            ("import Foundation\nimport PackageDescription\n\(Self.good)", "does not begin"),
            ("import PackageDescription\nimport Foundation\n\(Self.good)", "is not followed"),
            (
                "import PackageDescription\nimport CompilerPluginSupport\n\(Self.good)",
                "is not followed"
            ),
            ("import PackageDescription\nlet zz = 1\n\(Self.good)", "is not followed"),
            ("import PackageDescription\nvar zz = 1\n\(Self.good)", "is not followed"),
            ("import PackageDescription\nfunc zzAdd() {}\n\(Self.good)", "is not followed"),
            (
                "import PackageDescription\nlet zzDeps: [Target.Dependency] = []\n\(Self.good)",
                "is not followed"
            ),
            ("import PackageDescription\n#if DEBUG\n#endif\n\(Self.good)", "is not followed"),
            ("let zz = 1\nimport PackageDescription\n\(Self.good)", "does not begin"),
            (Self.good, "does not begin"),
            (#"import PackageDescription\#nlet pkg = Package(name: "A")"#, "is not followed"),
            (#"import PackageDescription\#nvar package = Package(name: "A")"#, "is not followed"),
            (
                #"import PackageDescription\#nlet package: Package = Package(name: "A")"#,
                "is not followed"
            ),
        ]
        for (source, message) in before {
            let found = ManifestScan.shapeProblem(in: source)
            #expect(found?.contains(message) == true, "\(source): \(found ?? "nil")")
        }
    }

    /// A statement or expression after the constructor: the changes the earlier rules could not
    /// see. A subscript assignment (P3c-after), a range assignment (DPOST), an inout pass
    /// (S3-INOUT), a second package, a declaration, a conditional.
    ///
    /// **Mutation:** in `shapeProblem`, accept what follows the constructor. Run: red here, at
    /// every fixture.
    @Test("A statement or expression after the constructor is refused")
    func aStatementAfterTheConstructorIsRefused() {
        let after = [
            #"zzSupport.dependencies[0] = "AeolusHelper""#,
            #"package.dependencies[0..<0] = [.package(path: "ZZLocal")]"#,
            "zzAdd(&zzSupport.dependencies)", "let zz = 1", "func zzAdd() {}", ";",
            #"let other = Package(name: "B")"#, "#if DEBUG\n#endif", ".self",
        ]
        for statement in after {
            let found = ManifestScan.shapeProblem(
                in: "import PackageDescription\n\(Self.good)\n\(statement)")
            #expect(
                found?.contains("something follows Package(…)") == true,
                "\(statement): \(found ?? "nil")")
        }
    }

    /// A constructor that never closes cannot be told from one with something after it.
    ///
    /// **Mutation:** in `shapeProblem`, accept a constructor that never closes. Run: red here.
    @Test("A constructor that never closes is refused")
    func anUnterminatedConstructorIsRefused() {
        let found = ManifestScan.shapeProblem(
            in: #"import PackageDescription\#nlet package = Package(name: "A""#)
        #expect(found?.contains("never closes") == true, "\(found ?? "nil")")
    }

    /// This package's own manifests are exactly that shape.
    @Test("The root manifests are exactly import PackageDescription and one let package")
    func theRootManifestsHaveTheShape() throws {
        let manifests = ManifestScan.manifestNames(among: try SeamBuildSettingTests.rootEntries())
        #expect(manifests.contains("Package.swift"), "the root manifest was not found")
        for name in manifests {
            let found = ManifestScan.shapeProblem(in: try SeamBuildSettingTests.text(name))
            #expect(found == nil, "\(name): \(found ?? "")")
        }
    }
}
