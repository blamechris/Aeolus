import Foundation
import Testing

/// A composition over the real SMC is required `.notBuilt` immediately before anything that would
/// write once the plane can — bring-up, a teardown, `apply`, or a plane's own write verb.
///
/// The population is every test file that can reach an openable connection (`RuleZeroScan`'s
/// reach), and every hardware-gated one. In it, each `bringUp()`, `prepareWritePath()`,
/// `reconcileFans()`, `signalTeardown.run(…)` and `authority.apply(…)` on a composition, and each
/// `restoreToAutomatic`, `engageManualControl`, `commandTarget` and
/// `prepareWritePath(enumerating:)` on a plane, must have
/// `#require(<plane>.writeCapability == .notBuilt …)` as the statement just before it.
///
/// **One exemption:** outside a hardware-gated file, a receiver bound in the same file to a
/// composition that builds nothing real — `HelperWatchdogCompositionTests`' scripted graphs —
/// needs none, since there is no SMC under it to write to.
///
/// This is the second layer. The first is `production`'s default, which withholds the channel; the
/// require is what fails the test, before it drives anything, if that default is ever changed.
/// A tripwire and not a proof: a composition built in another file and handed in as a parameter
/// is required here like any other (an unbound receiver is never exempt), and one built behind
/// two levels of helper in a file that is not hardware-gated would be read as a fake.
@Suite("Rule zero: a real composition is required .notBuilt before it is driven")
struct NotBuiltRequireTripwireTests {

    /// The files the scan must read as the population, or it is not reading the tree.
    static let knownPopulation: Set<String> = [
        "Tests/AeolusHelperTests/HelperHardwareTests.swift",
        "Tests/AeolusHelperTests/HelperHardwareSightingTests.swift",
        "Tests/AeolusHelperTests/WatchdogHardwareTests.swift",
        "Tests/AeolusHelperTests/HelperWatchdogCompositionTests.swift",
        "Tests/AeolusHelperTests/HelperCompositionTests.swift",
        "Tests/AeolusHelperTests/ProductionWritePathTests.swift",
    ]

    /// The three calls over the real SMC the audit found: each must be found, and guarded.
    static let knownDriven: Set<String> = [
        "Tests/AeolusHelperTests/HelperHardwareTests.swift: helper.bringUp",
        "Tests/AeolusHelperTests/HelperHardwareTests.swift: helper.signalTeardown.run",
        "Tests/AeolusHelperTests/WatchdogHardwareTests.swift: helper.bringUp",
    ]

    /// The scripted graphs the exemption must recognise, or it is exempting nothing it was written
    /// for.
    static let knownExempt: Set<String> = [
        "Tests/AeolusHelperTests/HelperWatchdogCompositionTests.swift: helper.bringUp",
        "Tests/AeolusHelperTests/HelperWatchdogCompositionTests.swift: helper.signalTeardown.run",
    ]

    @Test("Every driven composition over the real SMC is required .notBuilt just before")
    func everyDrivenRealCompositionIsRequiredNotBuilt() throws {
        let files = try RuleZeroScan.files(under: "Tests")
        let gated = try RuleZeroScan.hardwareGated(files)
        var population: Set<String> = []
        var driven: Set<String> = []
        var exempt: Set<String> = []

        for file in files {
            let isGated = gated.contains(file.path)
            guard try isGated || RuleZeroScan.reaches(file.code) else { continue }
            population.insert(file.path)

            let code = RuleZeroScan.tightened(file.code)
            for call in try RuleZeroScan.drivenCalls(in: code) {
                let site = "\(file.path): \(call.call)"
                if try !isGated && RuleZeroScan.isBoundToAFake(call, in: code) {
                    exempt.insert(site)
                    continue
                }
                driven.insert(site)
                #expect(
                    RuleZeroScan.isGuarded(call, in: code),
                    """
                    \(site) is not immediately preceded by \
                    #require(\(call.guardPath).writeCapability == .notBuilt). It can reach a real \
                    SMC, and once the plane can write this call writes to this Mac — rule zero.
                    """)
            }
        }

        #expect(
            population.isSuperset(of: Self.knownPopulation),
            "the scan read \(population.sorted()), not all of \(Self.knownPopulation.sorted())"
        )
        #expect(
            driven.isSuperset(of: Self.knownDriven),
            "the scan found \(driven.sorted()), not every one of \(Self.knownDriven.sorted())")
        #expect(
            exempt.isSuperset(of: Self.knownExempt),
            "the scan exempted \(exempt.sorted()), not every one of \(Self.knownExempt.sorted())")
    }
}

/// No test file that can reach an openable connection names the write channel, passes a
/// `channel:`, or passes a `writePath:` — nor names a test function, callable from another file,
/// that takes a channel. `WriteSeamTestIsolationTests`' rule, generalised.
///
/// `@testable import AeolusHelper` makes `SMCWriteChannel`'s `write` requirement callable through
/// the existential with no SPI opt-in, so that suite's rule — the files that opt in never open a
/// connection — no longer bounds who can write. This bounds it the other way: the files that can
/// open one never hold the channel. A `FirmwareSMC` is therefore the only channel a test can pass,
/// since a file that names no real connection has none to pass.
///
/// What it cannot see: a real connection made in one file and handed, by type inference, to a
/// channel in another; and a test type whose initialiser takes a channel under another label.
@Suite("Rule zero: a file that can reach a real connection never names the write channel")
struct WriteChannelReachTripwireTests {

    static let forbidden: [(name: String, pattern: String)] = [
        ("SMCWriteChannel", #"(?<![A-Za-z0-9_])SMCWriteChannel(?![A-Za-z0-9_])"#),
        ("channel:", #"(?<![A-Za-z0-9_])channel\s*:"#),
        ("writePath:", #"(?<![A-Za-z0-9_])writePath\s*:"#),
    ]

    /// Files the reach must find, or it is not reading the tree — SMCCore's write tests among them,
    /// because the rule is not the helper's alone.
    static let knownReaching: Set<String> = [
        "Tests/AeolusHelperTests/HelperHardwareTests.swift",
        "Tests/AeolusHelperTests/HelperHardwareSightingTests.swift",
        "Tests/AeolusHelperTests/WatchdogHardwareTests.swift",
        "Tests/AeolusHelperTests/HelperWatchdogCompositionTests.swift",
        "Tests/AeolusHelperTests/HelperCompositionTests.swift",
        "Tests/AeolusHelperTests/ProductionWritePathTests.swift",
        "Tests/AeolusHelperTests/RawFanModeReading.swift",
        "Tests/SMCCoreTests/SMCConnectionTests.swift",
        "Tests/SMCCoreTests/SMCConnectionWriteTests.swift",
    ]

    /// Functions taking a channel that the declaration scan must find, private or not.
    static let knownTakers: Set<String> = [
        "Tests/AeolusHelperTests/SMCWriteTurnTests.swift: runsOneWriteJob",
        "Tests/AeolusHelperTests/PlaneWriteChannelTests.swift: plane",
    ]

    /// **Mutation:** pass `channel: connection` to the plane in `HelperHardwareTests`. Run: red.
    @Test("No test file that can reach a real connection names the channel, channel: or writePath:")
    func noReachingFileNamesTheChannel() throws {
        let files = try RuleZeroScan.files(under: "Tests")
        let takers = try files.flatMap(RuleZeroScan.channelTakers(in:))
        let callable = takers.filter { !$0.isPrivate }.map {
            (name: $0.name, pattern: #"(?<![A-Za-z0-9_])"# + $0.name + #"(?![A-Za-z0-9_])"#)
        }

        var reaching: Set<String> = []
        for file in files where try RuleZeroScan.reaches(file.code) {
            reaching.insert(file.path)
            let named = try (Self.forbidden + callable).filter {
                try RuleZeroScan.count($0.pattern, in: file.code) > 0
            }
            #expect(
                named.isEmpty,
                """
                \(file.path) can reach an openable connection and names \(named.map(\.name)). A \
                channel there can be the real connection, and a write through it writes to this \
                Mac — rule zero. Use FirmwareSMC, in a file that names no real connection.
                """)
        }

        #expect(
            reaching.isSuperset(of: Self.knownReaching),
            "the reach found \(reaching.sorted()), not every one of \(Self.knownReaching.sorted())")
        let found = Set(takers.map { "\($0.path): \($0.name)" })
        #expect(
            found.isSuperset(of: Self.knownTakers),
            "the declaration scan found \(found.sorted()), not \(Self.knownTakers.sorted())")
    }
}

/// The write path is passed as the connection in exactly one place, `AeolusHelperMain`, and nowhere
/// else under `Sources`, `Tests` or `Tools`.
///
/// Whitespace is removed before matching, so `writePath:\n    .connection` is the spelling, and the
/// type may be written out. The needle is built from pieces inside a string, which the scan strips,
/// so this file cannot match itself.
@Suite("Rule zero: only the daemon passes the connection as the write path")
struct ProductionWritePathTripwireTests {

    static let daemon = "Sources/AeolusHelper/AeolusHelperMain.swift"

    static let needle =
        "write" + "Path:" + "(?:Production" + "WritePath)?" + #"\.connection(?![A-Za-z0-9_])"#

    /// **Mutation:** pass the connection as the write path in a test file. Run: red.
    @Test("The connection is passed as the write path by AeolusHelperMain alone")
    func onlyTheDaemonPassesTheConnection() throws {
        var found: [String: Int] = [:]
        for directory in ["Sources", "Tests", "Tools"] {
            for file in try RuleZeroScan.files(under: directory) {
                let count = try RuleZeroScan.count(
                    Self.needle, in: file.code.filter { !$0.isWhitespace })
                if count > 0 { found[file.path] = count }
            }
        }

        let elsewhere = found.keys.filter { $0 != Self.daemon }.sorted()
        #expect(
            elsewhere.isEmpty,
            """
            \(elsewhere) pass the connection as the production graph's write path. Only \
            \(Self.daemon) may: anything else composing the real SMC with a channel writes to it \
            once the plane can — rule zero.
            """)
        #expect(
            found[Self.daemon] == 1,
            "the scan did not find the daemon's one write path in \(Self.daemon): \(found)")
    }
}
