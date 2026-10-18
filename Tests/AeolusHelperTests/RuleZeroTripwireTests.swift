import Foundation
import Testing

/// A composition or a plane built over the real SMC is required to hold no write channel, once, on
/// its binding's first use (ADR 0014's B1 seam amendment).
///
/// The population is every test file that can reach an openable connection (`RuleZeroScan`'s
/// reach) and every hardware-gated one. In it, every `.production` — called or taken as a value —
/// and every `SMCFanControlPlane(…)` or `supervisorPlane(…)` must be the whole initialiser of a
/// `let`, and the first later mention of that `let` must be `try #require(!<name>.plane
/// .holdsWriteChannel …)` for a composition, or `try #require(!<name>.holdsWriteChannel …)` for a
/// plane, with no `?` or `!` on the `try`.
///
/// **One check covers every later call** because nothing can change the answer: a composition's
/// `plane` is a `let`, a plane's `writeChannel` a `private let`
/// (`CompositionWriteChannelTests.theRequiresPremiseHolds`), and the binding is a `let`. It fails
/// on a build whose capability is constant, which the `writeCapability == .notBuilt` require it
/// replaces could not: that one would have caught a changed default only once the plane could
/// write.
///
/// This is the second layer. The first is `production`'s default, which withholds the channel, and
/// beneath both is that no test can make a real connection a channel at all
/// (`WriteChannelSeamTests.smcConnectionConformsToNoChannel`).
@Suite("Rule zero: a real composition or plane is required to hold no write channel")
struct NotBuiltRequireTripwireTests {

    /// The bindings the audit found, each of which must be found and judged.
    static let knownBindings: Set<String> = [
        "Tests/AeolusHelperTests/HelperHardwareTests.swift: helper",
        "Tests/AeolusHelperTests/HelperHardwareTests.swift: plane",
        "Tests/AeolusHelperTests/HelperHardwareSightingTests.swift: plane",
        "Tests/AeolusHelperTests/WatchdogHardwareTests.swift: helper",
        "Tests/AeolusHelperTests/HelperWatchdogCompositionTests.swift: helper",
        "Tests/AeolusHelperTests/HelperWatchdogCompositionTests.swift: production",
        "Tests/AeolusHelperTests/HelperCompositionTests.swift: helper",
        "Tests/AeolusHelperTests/CompositionWriteChannelTests.swift: helper",
    ]

    /// **Mutations**, each red here: delete a require; `try?` on one; `var helper`;
    /// `let f = HelperComposition.production`; `HelperComposition.production()` passed straight
    /// to a function.
    @Test("Every real composition and plane is a let, required to hold no channel on first use")
    func everyRealConstructionIsRequiredOnFirstUse() throws {
        let files = try RuleZeroScan.files(under: "Tests")
        let gated = try RuleZeroScan.hardwareGated(files)
        var judged: Set<String> = []

        for file in files {
            guard try gated.contains(file.path) || RuleZeroScan.reaches(file.code) else { continue }
            for construction in try RuleZeroScan.constructions(in: file.code) {
                judged.insert("\(file.path): \(construction.binding ?? "(unbound)")")
                #expect(
                    construction.violation == nil,
                    """
                    \(file.path) builds a \(construction.built) over a reachable SMC \
                    (\(construction.binding ?? "unbound")), and \(construction.violation ?? ""). \
                    Bind it with let and make its first use try #require(!…holdsWriteChannel): \
                    once the plane can write, a composition holding a channel writes to this Mac.
                    """)
            }
        }

        #expect(
            judged.isSuperset(of: Self.knownBindings),
            "the scan judged \(judged.sorted()), not all of \(Self.knownBindings.sorted())")
    }

    static let extendingComposition =
        #"(?<![A-Za-z0-9_])extension\s+(?:AeolusHelper\s*\.\s*)?HelperComposition(?![A-Za-z0-9_])"#
    static let aliasingComposition =
        #"(?<![A-Za-z0-9_])typealias\s+\w+\s*(?:<[^=]*>)?\s*=\s*(?:AeolusHelper\s*\.\s*)?"#
        + #"HelperComposition(?![A-Za-z0-9_])"#

    /// Inside an extension of the composition, `production(` is called bare, a spelling neither
    /// the reach nor the construction pattern reads (#436's delta review, B4); a typealias would
    /// carry the extension past this check. So neither is written under `Tests/` or `Tools/`.
    ///
    /// **Mutation:** add `extension HelperComposition {}` to a test file. Run: red here.
    @Test("No test or tool extends HelperComposition, or aliases it")
    func noTestExtendsTheComposition() throws {
        var found: [String] = []
        var read = 0
        for directory in ["Tests", "Tools"] {
            for file in try RuleZeroScan.files(under: directory) {
                read += 1
                let named =
                    try RuleZeroScan.count(Self.extendingComposition, in: file.code)
                    + RuleZeroScan.count(Self.aliasingComposition, in: file.code)
                if named > 0 { found.append(file.path) }
            }
        }
        #expect(
            found.isEmpty,
            "\(found) extend or alias HelperComposition, where production( can be called bare")
        #expect(read > 100, "the scan read \(read) files, which is not the tree")
    }

    /// **Mutation:** drop `(?:AeolusHelper\s*\.\s*)?` from both patterns. Run: red here.
    @Test("An extension or alias of the composition is found in every spelling")
    func compositionExtensionsAreFound() throws {
        let found = [
            "extension HelperComposition where Plane == SMCFanControlPlane {}",
            "extension AeolusHelper . HelperComposition {}",
            "typealias Graph = HelperComposition<SMCFanControlPlane>",
            "typealias Graph = AeolusHelper.HelperComposition",
        ]
        for source in found {
            let code = RuleZeroScan.code(of: source)
            let named =
                try RuleZeroScan.count(Self.extendingComposition, in: code)
                + RuleZeroScan.count(Self.aliasingComposition, in: code)
            #expect(named == 1, "\(source)")
        }
        let code = RuleZeroScan.code(
            of: "extension HelperCompositionTests {}\nlet c = HelperComposition(plane: p)")
        #expect(try RuleZeroScan.count(Self.extendingComposition, in: code) == 0)
        #expect(try RuleZeroScan.count(Self.aliasingComposition, in: code) == 0)
    }
}

/// The daemon's entry point composes the daemon's graph, gives it the write channel, and runs
/// bring-up before `dispatchMain()`; once the plane can write, a test that ran it would write.
///
/// **The compiler closes it** (ADR 0014's B1 seam amendment, fix round 2). `AeolusHelperMain` is
/// `private`, so no other file names it — not through `@testable import AeolusHelper`, a
/// typealias, `.self.main()` or the bare name (#436's probes, each "cannot find
/// 'AeolusHelperMain' in scope"). The name scan it replaces missed the typealias and `.self`.
/// What this suite holds is that the type stays private, and, as depth, that no code under
/// `Tests/` or `Tools/` holds the token.
@Suite("Rule zero: no test or tool can run the daemon's entry point")
struct DaemonEntryPointTripwireTests {

    /// Every spelling contains the token, so the token is what is refused.
    static let token = #"(?<![A-Za-z0-9_])AeolusHelperMain(?![A-Za-z0-9_])"#

    /// **Mutation:** drop `private` from `@main private enum AeolusHelperMain`. Run: red here.
    @Test("The entry point is a private type")
    func theEntryPointIsPrivate() throws {
        let main = try #require(
            try RuleZeroScan.files(under: "Sources").first {
                $0.path == "Sources/AeolusHelper/AeolusHelperMain.swift"
            })
        #expect(
            try RuleZeroScan.count(
                #"@main\s+private\s+enum\s+AeolusHelperMain\s*\{"#, in: main.code)
                == 1,
            "the daemon's entry point is not a private type: any @testable file can run it")
    }

    /// Depth beneath the compiler. Comments and strings are code-stripped first, so the file
    /// names tests read — `"AeolusHelperMain.swift"` — are not uses; any spelling in code is.
    @Test("No code under Tests or Tools holds the AeolusHelperMain token")
    func nothingNamesTheEntryPoint() throws {
        var naming: [String] = []
        var read = 0
        for directory in ["Tests", "Tools"] {
            for file in try RuleZeroScan.files(under: directory) {
                read += 1
                if try RuleZeroScan.count(Self.token, in: file.code) > 0 {
                    naming.append(file.path)
                }
            }
        }
        #expect(naming.isEmpty, "\(naming) name the daemon's entry point")
        #expect(read > 100, "the scan read \(read) files, which is not the tree")
    }

    /// The token pattern on the spellings the round-1 scan missed. They no longer compile in a
    /// test, so they are fixtures here.
    ///
    /// **Mutation:** make `token` match only `AeolusHelperMain.main`. Run: red here.
    @Test("The token is found in every spelling of the entry point")
    func theTokenIsFoundInEverySpelling() throws {
        let spellings = [
            "typealias Entry = AeolusHelperMain\ntry await Entry.main()",
            "try await AeolusHelperMain.self.main()",
            "try await AeolusHelperMain.main()",
            "extension AeolusHelperMain {}",
            "let entry = AeolusHelperMain.self",
        ]
        for spelling in spellings {
            #expect(try RuleZeroScan.count(Self.token, in: RuleZeroScan.code(of: spelling)) > 0)
        }
        #expect(
            try RuleZeroScan.count(
                Self.token, in: RuleZeroScan.code(of: #"let f = "AeolusHelperMain.swift""#)) == 0)
    }
}
