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
}

/// A test that calls the daemon's entry point composes the daemon's graph, write channel and all
/// (ADR 0014's B1 seam amendment, "What remains"). Nothing under `Tests/` or `Tools/` names it.
@Suite("Rule zero: no test or tool runs the daemon's entry point")
struct DaemonEntryPointTripwireTests {

    static let entryPoint = #"(?<![A-Za-z0-9_])AeolusHelperMain\s*\.\s*main(?![A-Za-z0-9_])"#
    static let extending = #"(?<![A-Za-z0-9_])extension\s+AeolusHelperMain(?![A-Za-z0-9_])"#

    /// **Mutation:** call `AeolusHelperMain.main()` from a test file. Run: red.
    @Test("No file under Tests or Tools names AeolusHelperMain.main or extends AeolusHelperMain")
    func nothingRunsTheDaemon() throws {
        var naming: [String] = []
        var read = 0
        for directory in ["Tests", "Tools"] {
            for file in try RuleZeroScan.files(under: directory) {
                read += 1
                let found =
                    try RuleZeroScan.count(Self.entryPoint, in: file.code)
                    + RuleZeroScan.count(Self.extending, in: file.code)
                if found > 0 { naming.append(file.path) }
            }
        }
        #expect(naming.isEmpty, "\(naming) name the daemon's entry point")
        #expect(read > 100, "the scan read \(read) files, which is not the tree")
    }
}
