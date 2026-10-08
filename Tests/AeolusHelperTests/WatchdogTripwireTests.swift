import Foundation
import Testing

@testable import AeolusHelper

/// The claims about the liveness watchdog that have **nothing to observe at runtime**,
/// asserted at the source — and, because a tripwire is itself a guard, each scan is run over
/// fixtures first, so that a scan which has quietly stopped seeing anything cannot pass for a
/// tree that is clean.
///
/// Source is normalised before it is matched: whole-line comments are dropped (`///` prose
/// explaining a rule is not the rule being broken), and every pattern tolerates the whitespace
/// Swift allows between a name and its parenthesis, because `foo (` compiles.
@Suite("What the liveness watchdog's source must and must not contain")
struct WatchdogTripwireTests {

    private func lifecycleSource(_ file: String) throws -> String {
        try source("AeolusHelper/Lifecycle/\(file)")
    }

    private func source(_ path: String) throws -> String {
        let url = SeamScanner.sourcesRoot.appendingPathComponent(path)
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - Names the watchdog may not mention

    /// The modules a type of this package can be named through. `SMCCore.SMCConnection` is the
    /// same type as `SMCConnection`, and a scan that only saw the bare spelling would be
    /// evaded by the one qualifier the compiler accepts for it. The exit scan
    /// (`SignalTeardownTripwireTests.exitCallPattern`) allows its module spellings the same
    /// way, and for the same reason. A member access on anything that is **not** a module
    /// (`connections.SMCConnection`) is still not a mention.
    static let moduleQualifiers = [
        "SMCCore", "FanKit", "AeolusXPC", "AeolusXPCClient", "AeolusHelper", "IOKit", "Darwin",
        "Foundation",
    ]

    /// Every name in `names` that appears in `code`, as a prefix of an identifier: a watchdog
    /// that named `SMCConnectionRecycling` is as far into the connection's world as one that
    /// named `SMCConnection`. Optionally qualified by the module that exports it, with
    /// whatever whitespace Swift allows around the dot.
    static func mentions(of names: [String], in code: String) throws -> [String] {
        let qualifier = "(?:(?:" + moduleQualifiers.joined(separator: "|") + #")\s*\.\s*)?"#
        return try names.filter { name in
            let pattern = try NSRegularExpression(pattern: #"(?<![\w.])"# + qualifier + name)
            return pattern.firstMatch(
                in: code, range: NSRange(code.startIndex..<code.endIndex, in: code)) != nil
        }
    }

    /// What the watchdog and the claim it ends the process through may not name: the
    /// connection, the plane, the scheduler, the provider, the things that queue behind a
    /// wedge, the teardown, and any IOKit call. The watchdog reads a lock-guarded stamp and a
    /// lock-guarded progress object and nothing else; a name from this list in its files is
    /// the first step of reading through something that can be held.
    static let forbiddenInTheWatchdog = [
        "SMCConnection", "SMCFanControlPlane", "FanControlPlane", "SMCReadScheduler",
        "SMCSensorProvider", "SensorProvider", "ConnectionHealth", "SignalTeardown",
        "ControlMessageGate", "LeaseAuthority", "occupyForTesting", "IOConnect", "IOService",
        "IOKit",
    ]

    /// **Mutation:** write `SMCConnection` into `LivenessWatchdog.swift` (a stored property of
    /// that type, a parameter, a `typealias`). Run: red. The same for any other name listed.
    @Test("The watchdog's files name nothing that can queue behind a wedged connection")
    func theWatchdogNamesNoConnection() throws {
        for file in ["LivenessWatchdog.swift", "ProcessTermination.swift"] {
            let found = try Self.mentions(
                of: Self.forbiddenInTheWatchdog, in: try lifecycleSource(file))
            #expect(
                found.isEmpty,
                """
                \(file) names \(found). The watchdog reads a stamp under a lock and never \
                enters the connection (ADR 0012 I2): a reference to the connection, the plane \
                or the scheduler is a route to a read that queues behind the wedge it exists \
                to see.
                """)
        }
        let progress = try source("AeolusHelper/Safety/ThermalCycleProgress.swift")
        #expect(
            try Self.mentions(of: Self.forbiddenInTheWatchdog, in: progress).isEmpty,
            "ThermalCycleProgress.swift names something that can be held")
    }

    /// The scan above, run over fixtures: a name in code is found, one in a comment is not,
    /// a longer identifier that begins with a forbidden name is found, **a module-qualified
    /// spelling is found**, and a member access that merely ends in one is not.
    ///
    /// **Mutation:** drop the `(?<![\w.])` prefix from `mentions(of:in:)`. Run: red — the
    /// member-access fixture is found.
    /// **Mutation:** make `mentions(of:in:)` return an empty array. Run: red — a name written
    /// in code goes unseen.
    /// **Mutation:** drop the module qualifier group from `mentions(of:in:)`. Run: red — the
    /// qualified fixtures go unseen. Run against the source instead (write
    /// `SMCCore.SMCConnection` into `LivenessWatchdog.swift`): red, in
    /// `theWatchdogNamesNoConnection`.
    @Test("The name scan sees a name in code and not in prose")
    func theNameScanSeesWhatItShould() throws {
        func found(_ source: String) throws -> [String] {
            try Self.mentions(
                of: ["SMCConnection"], in: SeamScanner.strippingComments(source))
        }
        #expect(try found("let connection: SMCConnection") == ["SMCConnection"])
        #expect(try found("var c: SMCConnectionRecycling") == ["SMCConnection"])
        #expect(try found("let c = SMCConnection ()") == ["SMCConnection"])
        #expect(try found("/// reads no SMCConnection\nlet x = 1").isEmpty)
        #expect(try found("// SMCConnection\nlet x = 1").isEmpty)
        #expect(try found("let x = module.SMCConnection").isEmpty)

        // The same type, named through its module.
        #expect(try found("let c: SMCCore.SMCConnection") == ["SMCConnection"])
        #expect(try found("typealias C = SMCCore . SMCConnection") == ["SMCConnection"])
        #expect(try found("let c = AeolusHelper.SMCConnection()") == ["SMCConnection"])
        #expect(try found("let c: SMCCore\n    .SMCConnection") == ["SMCConnection"])
        // A qualifier that is not a module is a member access, as before.
        #expect(try found("let c: connections.SMCConnection").isEmpty)
        #expect(try found("let c = SMCCore.SomethingElse()").isEmpty)
    }

    // MARK: - The production wiring

    /// `production(…)` hands the watchdog **the monitor of the connection every read goes
    /// through** — the local `connection`, the one the provider and the plane are built on —
    /// and not another connection's. No runtime path can observe this: the plane holds its
    /// connection privately, and `main()` never returns.
    ///
    /// **Mutation:** pass `SMCConnection().roundTrips` for `connection.roundTrips`. Run: red.
    @Test("The daemon's watchdog watches the connection the daemon reads through")
    func theProductionWatchdogWatchesTheDaemonsConnection() throws {
        let code = try source("AeolusHelper/HelperComposition.swift")
        let start = try #require(
            code.range(of: "static func production("), "production(…) is no longer declared")
        let body = String(code[start.lowerBound...])

        #expect(
            body.contains("let connection = SMCConnection()"),
            "the daemon's one connection is no longer named once")
        #expect(body.contains("SMCSensorProvider(connection: connection)"))
        #expect(body.contains("SMCFanControlPlane(scheduler: scheduler, connection: connection)"))
        #expect(
            body.contains("roundTrips: connection.roundTrips"),
            "the watchdog is not given the monitor of the connection the daemon reads through")
        // And no second connection is built anywhere in the daemon's graph.
        #expect(body.components(separatedBy: "SMCConnection(").count == 2)
    }
}
