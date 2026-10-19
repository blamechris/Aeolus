import Foundation
import Testing

/// Nothing but a test target reaches the helper (#445).
///
/// **Rule zero: no test may write to this Mac's SMC.** `NotBuiltRequireTripwireTests` holds every
/// real composition a test builds to a `let` whose first use is
/// `try #require(!….holdsWriteChannel)`, and it reads `Tests/` only. So the graph can be built out
/// of its sight by a target that is not a test:
///
/// ```swift
/// .target(name: "X", dependencies: ["AeolusHelper"], path: "Sources/X")
/// ```
///
/// whose one file does `@testable import AeolusHelper` and builds
/// `HelperComposition.production(log:)`. It builds, every test stays green, and any test target
/// can depend on it. Once the plane can write, that is a test that writes to this Mac.
///
/// Two layers close it, each failing closed:
/// 1. **The manifest.** Only a test target lists `AeolusHelper` among its dependencies, in any
///    spelling `ManifestScan` can read, and the set that does is pinned. A dependency list it
///    cannot read is a finding for every target.
/// 2. **The source.** No file under `Sources/` outside `Sources/AeolusHelper/`, and none under
///    `Tools/`, imports the module. The manifest cannot be the only layer, because on Swift 6.4 a
///    declaration is not what lets the import through: a target that declares no dependency on
///    `AeolusHelper` still compiles `@testable import AeolusHelper` in a tree where the helper's
///    module is already built, with a warning ("'X' is missing a dependency on 'AeolusHelper'"),
///    and so does one that declares it, since the helper is an executable target. A clean build
///    refuses the undeclared one only for want of the module (`unable to resolve module
///    dependency: 'AeolusHelper'`), and builds the declared one. The source is read twice: as code,
///    with comments, strings and backticks removed by the scanner every rule-zero tripwire
///    shares, and as raw text, with no lexer at all, against a pinned list of the files that name
///    the module even in prose.
/// 3. **What neither layer reads.** The source layer skips `Sources/AeolusHelper/` and reads only
///    the files under `Sources/` outside it and under `Tools/`; the manifest layer reads each
///    target's constructor `dependencies:`. Three more rules hold what those do not, and each
///    refuses only what it reads:
///    - `ManifestScan.reachProblem` reads a target's constructor arguments, and the file system
///      for one rule. It refuses a target whose `path:` resolves on disk to the helper's
///      directory or inside it (the text is resolved first, as SwiftPM resolves it, and then
///      compared as a real path, so another case, a folded letter, a `..` or a link before a `..`
///      does not hide it, and a directory that cannot be located is refused), a helper that takes
///      `exclude:` or `sources:`, and a plugin (a `.plugin` target or a `plugins:` argument),
///      whose generated source no scan reads. It does not read anything done to a target after
///      its constructor.
///    - `ManifestScan.shapeProblem` reads the top level of a manifest and refuses anything but
///      `import PackageDescription` and one `let package = Package(…)`. A manifest of that shape
///      has no statement after the constructor to change a target or the package, and no
///      top-level declaration for the constructor to read from. It does not read inside the
///      constructor.
///    - `ManifestScan.packageDependencies` reads the root `Package(...)`'s `dependencies:` as
///      constructed, and `pinnedPackages` pins it. A file from another package, local
///      (`.package(path: "ZZLocal")`) or remote, is not under `Sources/` outside the helper or
///      under `Tools/`, which is what the import census reads; the pin refuses the package
///      instead. The pinned package's own sources are read by nothing.
///
///    A `.macro` target needs `import CompilerPluginSupport`, where `Target.macro` is declared,
///    and the shape rule refuses that import. Observed on Swift 6.4: without the import `.macro`
///    is not a member of `Target`; with it, and with no swift-syntax dependency, a macro target
///    built and the suite stayed green (MACRO). So the shape rule closes the `.macro` route, and
///    the pin does not.
///
/// These scans catch accidents, and every spelling met so far; a deliberate author can evade a
/// lexical reading. ADR 0014's compiler seam (the B1 seam amendment) is the control, as everywhere
/// in this directory. They do not see an Xcode target (`project.yml` is not read for dependencies).
@Suite("Only a test target depends on, or imports, the helper")
struct HelperDependentsTests {

    // MARK: - The manifest

    /// Each target that lists the helper, as `<manifest>: <target>`. One: the helper's own tests.
    static let pinnedDependents = ["Package.swift: AeolusHelperTests"]

    /// Each package the root `Package(...)` lists, as `<manifest>: <label>: <value>`. One.
    static let pinnedPackages = [
        "Package.swift: url: https://github.com/apple/swift-argument-parser.git"
    ]

    /// **Mutations**, each in `Package.swift` and restored: (D04) add `.target(name: "ZZSupport",
    /// dependencies: ["AeolusHelper"], path: "Sources/ZZSupport")` and a file there that does
    /// `@testable import AeolusHelper` and builds `HelperComposition.production(log:)`; (D04c) the
    /// same at `Tools/ZZSupport`. Run: red here, at the target. (D04b) the same with no
    /// `dependencies:` is not red here, and is red at `theHelperIsImportedByNoSourceOrTool`.
    @Test("No target but AeolusHelperTests lists the helper in its constructor")
    func onlyAHelperTestTargetListsTheHelper() throws {
        let manifests = ManifestScan.manifestNames(among: try SeamBuildSettingTests.rootEntries())
        #expect(manifests.contains("Package.swift"), "the root manifest was not found")
        var dependents: [String] = []
        var declared = 0
        for name in manifests {
            for target in try ManifestScan.targets(in: try SeamBuildSettingTests.text(name)) {
                declared += 1
                let problem = ManifestScan.dependencyProblem(with: target)
                #expect(problem == nil, "\(name): \(problem ?? "")")
                if ManifestScan.dependsOnHelper(target) {
                    dependents.append("\(name): \(target.name ?? "?")")
                }
            }
        }
        #expect(
            dependents.sorted() == Self.pinnedDependents,
            """
            The targets that list AeolusHelper are \(dependents.sorted()), not \
            \(Self.pinnedDependents). A target that links the helper can build its real graph \
            outside rule zero's sight (#445); put what it needs in a test target under Tests/.
            """)
        #expect(declared >= 15, "the manifests declare \(declared) targets, not this package's")
    }

    /// The package's own dependencies, as constructed, are pinned, because a file from another
    /// package is under neither `Sources/` nor `Tools/` and the import census never reads it
    /// (#445's review). This reads the constructor only; the top level is
    /// `ManifestScanShapeTests`'. A
    /// local package whose source does `@testable import AeolusHelper` and refers to
    /// `production(log:)`, added to the root `dependencies:` and to `AeolusHelperTests`, built
    /// incrementally and left the suite green; a clean build fails to resolve it. A list that
    /// cannot be read is a finding. The reading is `ManifestScanPackageTests`'.
    ///
    /// **Mutation**, in `Package.swift` and restored: (LOCALPKG) add `.package(path: "ZZLocal")`
    /// to the root `dependencies:`, `.product(name: "ZZ", package: "ZZLocal")` to
    /// `AeolusHelperTests`, and `ZZLocal/Sources/ZZ/ZZ.swift` doing `@testable import
    /// AeolusHelper`. Run: red here.
    @Test("The root package depends on swift-argument-parser and on no other package")
    func theRootPackageDependsOnNoOtherPackage() throws {
        var found: [String] = []
        for name in ManifestScan.manifestNames(among: try SeamBuildSettingTests.rootEntries()) {
            switch try ManifestScan.packageDependencies(in: try SeamBuildSettingTests.text(name)) {
            case .listed(let identities):
                found += identities.map { "\(name): \($0)" }
            case .absent:
                found.append("\(name): (no package-level dependencies:)")
            case .unreadable(let text):
                found.append("\(name): (unreadable: \(text))")
            }
        }
        #expect(
            found.sorted() == Self.pinnedPackages,
            """
            The packages the manifests list are \(found.sorted()), not \(Self.pinnedPackages). \
            A package that is not this one compiles Swift no scan here reads, and can import the \
            helper (#445); put what it needs under Tests/.
            """)
    }

    /// What a target's constructor arguments refuse (#445's review). None of it is used today, so
    /// the real manifests must be clean: no plugin, no target whose `path:` resolves to or inside
    /// `Sources/AeolusHelper/`, no `exclude:` or `sources:` on the helper. It reads constructor
    /// arguments only; the top level is `ManifestScanShapeTests`'.
    ///
    /// **Mutations**, each in `Package.swift` and restored: (P3b) a `.target` at
    /// `Sources/AeolusHelper/ZZSub` with no declared dependency, the helper `exclude:`-ing
    /// `ZZSub`, and a file there that does `@testable import AeolusHelper`; (P3b-case, FOLD) the
    /// same target with its path spelled `Sources/aeolushelper/ZZSub` or
    /// `Sources/AeoluſHelper/ZZSub`;
    /// (SYMDOT2) a path `ZZA/../Sources/aeolushelper/ZZSym` with `ZZA` a link into a decoy; (P4) a
    /// `.plugin` at `Sources/ZZGen` applied to `AeolusHelperTests`, generating a file that
    /// references `production()`. Run: red here, each.
    @Test("No manifest nests a target in the helper or applies a plugin")
    func noManifestHidesSourceFromTheScans() throws {
        var read = 0
        for name in ManifestScan.manifestNames(among: try SeamBuildSettingTests.rootEntries()) {
            let text = try SeamBuildSettingTests.text(name)
            read += 1
            for target in try ManifestScan.targets(in: text) {
                let problem = ManifestScan.reachProblem(
                    with: target, under: RuleZeroScan.repositoryRoot)
                #expect(problem == nil, "\(name): \(problem ?? "")")
            }
        }
        #expect(read >= 1, "no manifest was read")
    }

    // MARK: - The source

    /// An `import` of the helper in any spelling. The scan reads code (`RuleZeroScan.code`), so the
    /// attributes, the access level and the comment, string or backtick around it are not this
    /// pattern's business, only the two words: `import`, then an optional kind, then the module.
    /// `\s+` is whitespace and newlines, a block comment having become one space.
    ///
    /// The module is matched whole, so `AeolusHelperKit` and `import struct Other.AeolusHelper` are
    /// not it, and a path under it (`import struct AeolusHelper.HelperComposition`) is.
    static let importOfTheHelper =
        #"(?<![A-Za-z0-9_])import\s+(?:(?:class|struct|enum|protocol|typealias|func|var|let)\s+)?"#
        + #"AeolusHelper(?![A-Za-z0-9_])"#

    static func importsTheHelper(_ source: String) throws -> Bool {
        try RuleZeroScan.count(importOfTheHelper, in: RuleZeroScan.code(of: source)) > 0
    }

    /// Every file under `Sources/` outside the helper, and under `Tools/`, that imports it.
    private static func importers() throws -> (importing: [String], read: Int) {
        var importing: [String] = []
        var read = 0
        for directory in ["Sources", "Tools"] {
            for file in try RuleZeroScan.files(under: directory)
            where !file.path.hasPrefix("Sources/AeolusHelper/") {
                read += 1
                if try RuleZeroScan.count(Self.importOfTheHelper, in: file.code) > 0 {
                    importing.append(file.path)
                }
            }
        }
        return (importing, read)
    }

    /// **Mutations:** (D04) and (D04b) as above; (D04c) the file under `Tools/`; (D04d) `@testable
    /// import struct AeolusHelper.HelperComposition` instead of the whole-module import. Run: red
    /// here, each.
    @Test("No file under Sources outside the helper, and none under Tools, imports the helper")
    func theHelperIsImportedByNoSourceOrTool() throws {
        let (importing, read) = try Self.importers()
        #expect(
            importing.isEmpty,
            """
            \(importing) import AeolusHelper. SwiftPM compiles that with or without a declared \
            dependency, and rule zero reads only Tests/: a file here that builds \
            HelperComposition.production(log:) builds the real graph out of its sight.
            """)
        #expect(read > 100, "the scan read \(read) files, which is not the tree")
    }

    /// The pattern on the code it exists for. Without this the tree scan above would be green on a
    /// pattern that had stopped matching the way the helper's own tests import it.
    ///
    /// **Mutation:** rename the module in `importOfTheHelper`. Run: red here.
    @Test("The import pattern finds the imports the helper's own tests write")
    func theImportPatternFindsTheTestsImports() throws {
        var importing = 0
        for file in try RuleZeroScan.files(under: "Tests")
        where file.path.hasPrefix("Tests/AeolusHelperTests/") {
            if try RuleZeroScan.count(Self.importOfTheHelper, in: file.code) > 0 { importing += 1 }
        }
        #expect(importing > 100, "\(importing) of the helper's tests import it")
    }

    /// Every spelling of an import of the helper, and the lookalikes that are not one. Each source
    /// holds exactly one import, so a spelling that stopped matching is red at its own line.
    ///
    /// **Mutations**, each restored, and each red here at the spellings that depend on it:
    /// - in `importOfTheHelper`: cut the kind list to `struct`, and to `class`; make `\s+` one
    ///   literal space; drop the trailing `(?![A-Za-z0-9_])`, and the leading one; widen `import`
    ///   to `canImport(`; match any module name, a prefix before it, or a path before it; let
    ///   anything stand between `import` and the module; rename the module, which reddens every
    ///   spelling;
    /// - in the scanners: read the source raw, or with strings as code; stop removing backticks;
    ///   stop replacing a block comment with a space; stop nesting block comments; stop removing a
    ///   trailing `//` comment.
    @Test("An import of the helper is found in every spelling, and a lookalike is not one")
    func importsAreFoundInEverySpelling() throws {
        let attributes = [
            "import AeolusHelper", "@testable import AeolusHelper",
            "@_spi(FanWrite) import AeolusHelper", "@_implementationOnly import AeolusHelper",
            "@_exported import AeolusHelper", "@preconcurrency @testable import AeolusHelper",
            "@testable @_spi(FanWrite) @preconcurrency import AeolusHelper",
        ]
        let levels = ["public", "package", "internal", "fileprivate", "private"].flatMap {
            ["\($0) import AeolusHelper", "@testable \($0) import AeolusHelper"]
        }
        let kinds = ["class", "struct", "enum", "protocol", "typealias", "func", "var", "let"].map {
            "import \($0) AeolusHelper.HelperComposition"
        }
        let layout = [
            "import AeolusHelper.HelperComposition", "import `AeolusHelper`",
            "import struct `AeolusHelper`.HelperComposition",
            "import /* the daemon */ AeolusHelper",
            "import // the daemon\n    AeolusHelper", "import/**/AeolusHelper",
            "import struct /* x */ AeolusHelper.HelperComposition", "import\n    AeolusHelper",
            "import\tAeolusHelper", "@testable\nimport\nAeolusHelper",
            "import struct\n    AeolusHelper.HelperComposition",
            "@testable import\n    AeolusHelper  // the daemon's graph",
            "import Foundation; import AeolusHelper", "import AeolusHelper; import Foundation",
            "#if DEBUG\n@testable import AeolusHelper\n#endif",
            "/* import Foundation */ import AeolusHelper",
            "let a = 1 /* x */ ; import AeolusHelper",
            "import /* one */ struct /* two */ AeolusHelper . HelperComposition",
        ]
        for source in attributes + levels + kinds + layout {
            #expect(try Self.importsTheHelper(source), "\(source)")
        }

        let lookalikes = [
            "import AeolusHelperKit", "import AeolusHelperTests", "import MyAeolusHelper",
            "import struct Other.AeolusHelper", "import SMCCore // import AeolusHelper",
            "import Foundation\nlet AeolusHelper = 1", "@testable import SMCCore",
            "reimport AeolusHelper", "// import AeolusHelper", "/// @testable import AeolusHelper",
            "/* import AeolusHelper */", "/* a /* nested */ import AeolusHelper */",
            "let s = \"import AeolusHelper\"", "let s = #\"@testable import AeolusHelper\"#",
            "let s = \"\"\"\nimport AeolusHelper\n\"\"\"", "#if canImport(AeolusHelper)\n#endif",
        ]
        for source in lookalikes {
            #expect(try !Self.importsTheHelper(source), "\(source)")
        }
    }

    /// The word, wherever it is written — code, comment or string — in the raw text, with no lexer
    /// between an import and this: the files outside the helper that name the module. They are
    /// prose, every one; a new one is a file to justify here, and a hidden import is a new one.
    /// Rule 4 of `WriteSeamTestIsolationTests` does the same for `_spi`.
    static let helperMentioners: Set<String> = [
        "Sources/Aeolus/Helper/HelperBundleLayout.swift",
        "Sources/AeolusXPC/ClientAuthorisation/ClientAuthorisation.swift",
        "Sources/AeolusXPC/ClientAuthorisation/HelperRequirementText.swift",
        "Sources/AeolusXPCClient/HelperClientDeadlines.swift",
        "Sources/FanKit/CatalogBundleLoading.swift",
        "Sources/FanKit/FanControlEnvelope.swift",
        "Sources/FanKit/HardwareIdentity.swift",
        "Sources/FanKit/ManualControlAvailability+Recovery.swift",
        "Sources/FanKit/RampGovernor.swift",
        "Sources/SMCCore/SMCConnection.swift",
        "Sources/SMCCore/SMCValue.swift",
        "Tools/PowerObserver/PowerObserverCore.swift",
        "Tools/PowerObserver/PowerObserverMain.swift",
        "Tools/SMCSampler/SMCSamplerCore.swift",
        "Tools/SMCSampler/SMCSamplerMain.swift",
    ]

    /// The second read, and it fails closed: the raw text is matched for the module's name, with no
    /// comment, string or backtick removed, so no lexer stands between an import and this list. It
    /// catches the accident and every spelling met so far; the first read says which spelling.
    ///
    /// **Mutations:** (D04), (D04b) and (D04c) as above, which this reads as a new file; a comment
    /// that says "AeolusHelper" in a new `Sources/` file, which it alone refuses. Run: red here,
    /// each.
    @Test("The raw text under Sources and Tools names the helper only in the known files")
    func everyMentionOfTheHelperIsKnown() throws {
        let mentioning = try WriteSeamTestIsolationTests.rawMentioners(
            of: #"(?<![A-Za-z0-9_])AeolusHelper(?![A-Za-z0-9_])"#, under: ["Sources", "Tools"]
        )
        .filter { !$0.hasPrefix("Sources/AeolusHelper/") }
        #expect(
            mentioning == Self.helperMentioners,
            """
            New: \(mentioning.subtracting(Self.helperMentioners).sorted()). Gone: \
            \(Self.helperMentioners.subtracting(mentioning).sorted()). A file outside the helper \
            that names it may import it; justify a new mention here, or remove it.
            """)
    }
}
