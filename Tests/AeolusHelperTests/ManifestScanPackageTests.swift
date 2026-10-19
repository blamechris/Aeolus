import Foundation
import Testing

/// The part of the manifest scan that reads the root package's own `dependencies:` (#445's
/// review), on synthetic text. A package that is not this one, local or remote, compiles Swift the
/// scans here do not read, so `HelperDependentsTests` pins the list; this holds the reading that
/// pin stands on to the spellings it must see and the ones it must refuse. A list it cannot read is
/// `.unreadable`, never an empty list.
///
/// These scans catch accidents. ADR 0014's compiler seam is the real control.
@Suite("The manifest scan's reading of the package-level dependencies")
struct ManifestScanPackageTests {

    private static func manifest(dependencies: String?) -> String {
        let argument = dependencies.map { "    dependencies: \($0),\n" } ?? ""
        return """
            let package = Package(
                name: "Aeolus",
                targets: [.target(name: "A", dependencies: ["B"])],
            \(argument))
            """
    }

    private static func read(_ dependencies: String?) throws -> ManifestScan.PackageDependencies {
        try ManifestScan.packageDependencies(in: manifest(dependencies: dependencies))
    }

    /// Every way a package names a package that this reads, and the case of none at all. The
    /// target's own `dependencies: ["B"]` beside the package's is not the package's.
    ///
    /// **Mutations:** in `packageIdentity`, stop reading `url:`; stop reading `path:`; stop
    /// reading `id:`; in `packageDependencies`, read a missing `dependencies:` as an empty list.
    /// Run: red here, at that spelling.
    @Test(
        "A package dependency is read by url, path or id, and no argument is told from an empty one"
    )
    func packagesAreRead() throws {
        let url =
            #".package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")"#
        let spellings: [(written: String, listed: [String])] = [
            ("[\(url)]", ["url: https://github.com/apple/swift-argument-parser.git"]),
            (
                #"[.package(url: "https://example.com/x.git", exact: "1.0.0")]"#,
                ["url: https://example.com/x.git"]
            ),
            (#"[.package(path: "ZZLocal")]"#, ["path: ZZLocal"]),
            (#"[.package(id: "scope.name", from: "1.0.0")]"#, ["id: scope.name"]),
            (#"[. package ( path : "../Other" ) ,]"#, ["path: ../Other"]),
            (
                "[\n    \(url),\n    .package(path: \"ZZLocal\"),\n]",
                ["url: https://github.com/apple/swift-argument-parser.git", "path: ZZLocal"]
            ),
            ("[]", []),
        ]
        for (written, listed) in spellings {
            #expect(try Self.read(written) == .listed(listed), "\(written)")
        }
        #expect(try Self.read(nil) == .absent)
    }

    /// A list this cannot read is `.unreadable`, never an empty or a partial list: it could name a
    /// package. The first group is not one array literal; the second is an array with an element
    /// that is not a package this reads; the third is a manifest with no single `Package(...)`.
    ///
    /// **Mutations:** in `packageDependencies`, answer `.listed([])` for what is not an array
    /// literal; skip an element that cannot be read; accept a manifest with several `Package(`.
    /// Run: red here, at the first fixture of each group.
    @Test("A package-level dependency list that is not readable is refused, never read as empty")
    func anUnreadableListIsRefused() throws {
        for written in [
            "deps", "Self.deps", "base + [.package(path: \"ZZLocal\")]",
            #"[.package(path: "ZZLocal")] + extra"#,
        ] {
            guard case .unreadable = try Self.read(written) else {
                Issue.record("\(written) was read as \(try Self.read(written))")
                continue
            }
        }
        for written in [
            "[dependency]", "[.package(url: address, from: \"1.0.0\")]",
            #"[.package(path: "ZZLocal"), dependency]"#, #"[.package(name: "x")]"#,
            #"[.package(url: "https://example.com/x.git", from: "1.0.0").self]"#,
            #"[.packages(path: "ZZLocal")]"#, #"[Package.Dependency.package(path: "ZZLocal")]"#,
            ##"[.package(path: #"ZZLocal"#)]"##, #"["ZZLocal"]"#,
        ] {
            guard case .unreadable = try Self.read(written) else {
                Issue.record("\(written) was read as \(try Self.read(written))")
                continue
            }
        }
        for source in [
            "let package = 1",
            Self.manifest(dependencies: "[]") + "\n" + Self.manifest(dependencies: "[]"),
            "let package = Package(name: \"A\"",
        ] {
            guard case .unreadable = try ManifestScan.packageDependencies(in: source) else {
                Issue.record("\(source) was read")
                continue
            }
        }
    }

    /// Comments hold no package, and a name that merely ends in `Package(` is not the constructor.
    ///
    /// **Mutation:** in `packageDependencies`, read the text with its comments in it. Run: red
    /// here.
    @Test("A comment that shows a Package( or a .package( is not a constructor or a dependency")
    func commentsHoldNoPackage() throws {
        let source = """
            // let package = Package(name: "Old", dependencies: [.package(path: "ZZLocal")])
            /* .package(path: "ZZLocal") */
            let package = Package(
                name: "Aeolus",  // not a LocalPackage(…)
                dependencies: [.package(path: "Real")]
            )
            """
        #expect(try ManifestScan.packageDependencies(in: source) == .listed(["path: Real"]))
    }
}
