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

    /// Every name in `names` that appears in `code`, as a prefix of an identifier: a watchdog
    /// that named `SMCConnectionRecycling` is as far into the connection's world as one that
    /// named `SMCConnection`.
    static func mentions(of names: [String], in code: String) throws -> [String] {
        try names.filter { name in
            let pattern = try NSRegularExpression(pattern: #"(?<![\w.])"# + name)
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
    /// a longer identifier that begins with a forbidden name is found, and a member access
    /// that merely ends in one is not.
    ///
    /// **Mutation:** drop the `(?<![\w.])` prefix from `mentions(of:in:)`. Run: red — the
    /// member-access fixture is found.
    /// **Mutation:** make `mentions(of:in:)` return an empty array. Run: red — a name written
    /// in code goes unseen.
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
    }

    // MARK: - No Duration on the initialiser

    /// The `(…)` of every `init` in `code`, parsed to its closing parenthesis rather than
    /// matched up to the first `)`: a default value such as `log: WatchdogLog = WatchdogLog()`
    /// has parentheses of its own.
    static func initializerParameters(in code: String) throws -> [String] {
        let opener = try NSRegularExpression(pattern: #"\binit\s*[?!]?\s*\("#)
        let characters = Array(code)
        var parameters: [String] = []
        let openings = opener.matches(
            in: code, range: NSRange(code.startIndex..<code.endIndex, in: code))
        for match in openings {
            guard let range = Range(match.range, in: code) else { continue }
            var index = code.distance(from: code.startIndex, to: range.upperBound)
            var depth = 1
            let start = index
            while index < characters.count, depth > 0 {
                if characters[index] == "(" { depth += 1 }
                if characters[index] == ")" { depth -= 1 }
                index += 1
            }
            parameters.append(String(characters[start..<max(start, index - 1)]))
        }
        return parameters
    }

    /// I8: no `Duration` is a parameter of the watchdog's initialiser. There is nothing to
    /// lengthen — D, D_cycle, D_bringUp and the tick are `static let` on `WatchdogLimits`.
    ///
    /// **Mutation:** add a `Duration` parameter to `LivenessWatchdog.init`. Run: red.
    @Test("The watchdog's initialiser takes no Duration")
    func theWatchdogInitTakesNoDuration() throws {
        let initializers = try Self.initializerParameters(
            in: try lifecycleSource("LivenessWatchdog.swift"))
        #expect(!initializers.isEmpty, "the scan found no initialiser at all")
        for parameters in initializers {
            #expect(
                !parameters.contains("Duration"),
                "a Duration parameter would make a bound configurable: \(parameters)")
        }
    }

    @Test("The initialiser scan reads a parameter list to its closing parenthesis")
    func theInitScanParsesParameterLists() throws {
        func parameters(_ source: String) throws -> [String] {
            try Self.initializerParameters(in: source)
        }
        #expect(try parameters("init(a: Duration)").first?.contains("Duration") == true)
        #expect(
            try parameters("init(\n    roundTrips: X,\n    log: L = L(),\n    d: Duration\n) {}")
                .first?.contains("Duration") == true)
        #expect(try parameters("init (a: Duration) {}").first?.contains("Duration") == true)
        #expect(try parameters("init?(a: Duration) {}").first?.contains("Duration") == true)
        #expect(
            try parameters("init(roundTrips: X, log: L = L()) { self.d = Duration() }").first?
                .contains("Duration") == false)
        #expect(try parameters("func initialise(a: Duration)").isEmpty)
    }

    /// I8, from the other side: the bounds are `static let`. A stored `static var` in
    /// `WatchdogLimits` would be a bound assignable from anywhere in the module at runtime.
    ///
    /// **Mutation:** write `static var roundTrip: Duration = .seconds(5)`. Run: red.
    @Test("The bounds are constants, not assignable variables")
    func theBoundsAreStaticLets() throws {
        let code = try lifecycleSource("WatchdogLimits.swift")
        let storedVar = try NSRegularExpression(
            pattern: #"\bstatic\s+var\s+\w+\s*(:[^={\n]*)?="#)
        let found = storedVar.numberOfMatches(
            in: code, range: NSRange(code.startIndex..<code.endIndex, in: code))
        #expect(found == 0, "WatchdogLimits has a stored static var: a bound that can change")
        #expect(code.contains("static let roundTrip"), "the scan no longer finds D")
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
