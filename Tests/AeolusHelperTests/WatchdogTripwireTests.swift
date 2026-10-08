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
    static func mentions(
        of names: [String], in code: String, qualifiers: [String] = moduleQualifiers
    ) throws -> [String] {
        let qualifier = "(?:(?:" + qualifiers.joined(separator: "|") + #")\s*\.\s*)?"#
        // Backticks quote an identifier without changing it: `SMCCore`.SMCConnection is the
        // same type, and compiles.
        let text = code.replacingOccurrences(of: "`", with: "")
        return try names.filter { name in
            let pattern = try NSRegularExpression(pattern: #"(?<![\w.])"# + qualifier + name)
            return pattern.firstMatch(
                in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
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
    /// **Mutation:** stop dropping backticks in `mentions(of:in:)`. Run: red.
    /// **Mutation:** write `` `SMCCore`.SMCConnection `` into `LivenessWatchdog.swift`. Run:
    /// red, in `theWatchdogNamesNoConnection`.
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
        // Quoted in backticks, which changes nothing about what is named.
        #expect(try found("typealias H = `SMCCore`.SMCConnection") == ["SMCConnection"])
        #expect(try found("let c: `SMCConnection`") == ["SMCConnection"])
        #expect(try found("let c: `SMCCore`.`SMCConnection`") == ["SMCConnection"])
        // A qualifier that is not a module is a member access, as before.
        #expect(try found("let c: connections.SMCConnection").isEmpty)
        #expect(try found("let c = SMCCore.SomethingElse()").isEmpty)
    }

    // MARK: - The gate monitor

    /// Everything that parks, holds, resumes or drops a continuation. The scheduler's gate is
    /// **not cancellable** — a queued turn is resumed by the scheduler and by nothing else — and
    /// the gate monitor is called from inside the scheduler's own isolation. A monitor that held
    /// a continuation could be the second owner of a turn, or make a waiter vanish between being
    /// chosen and being resumed, which is the hole the gate's non-cancellability exists to keep
    /// shut. It needs no continuation: it records, and it answers from a copy.
    static let continuationNames = [
        "CheckedContinuation", "UnsafeContinuation", "withCheckedContinuation",
        "withCheckedThrowingContinuation", "withUnsafeContinuation",
        "withUnsafeThrowingContinuation",
    ]

    /// The modules the concurrency types are named through, which `moduleQualifiers` (the
    /// package's own and IOKit's) does not list: `Swift.CheckedContinuation` is the same type.
    static let concurrencyQualifiers = ["Swift", "_Concurrency"]

    /// **Mutation:** write `private var parked: [CheckedContinuation<Void, Never>] = []` into
    /// `GateWaitMonitor.swift`. Run: red. The same for `withCheckedContinuation`, and for
    /// `Swift.CheckedContinuation` (the qualified spelling).
    /// **Mutation:** write `SMCConnection` into `GateWaitMonitor.swift`, however it is spelled
    /// (`SMCCore.SMCConnection`, `` `SMCCore`.`SMCConnection` ``). Run: red.
    @Test("The gate monitor holds no continuation and names nothing that can queue behind a wedge")
    func theGateMonitorHoldsNoContinuationAndNamesNoConnection() throws {
        let code = try lifecycleSource("GateWaitMonitor.swift")
        #expect(code.contains("final class GateWaitMonitor"), "the scan lost the monitor")

        let continuations = try Self.mentions(
            of: Self.continuationNames, in: code,
            qualifiers: Self.moduleQualifiers + Self.concurrencyQualifiers)
        #expect(
            continuations.isEmpty,
            """
            GateWaitMonitor.swift names \(continuations). The gate is not cancellable and the \
            monitor is called from inside the scheduler's isolation: it records parked waiters \
            and never holds, resumes or drops one.
            """)

        let queuing = try Self.mentions(of: Self.forbiddenInTheWatchdog, in: code)
        #expect(
            queuing.isEmpty,
            """
            GateWaitMonitor.swift names \(queuing). It reads nothing through the connection, the \
            plane or the scheduler: it is told what the scheduler did and answers from a copy.
            """)
    }

    /// The continuation scan, over fixtures: every spelling of a continuation is found, the
    /// module-qualified ones included, and prose and longer identifiers are not.
    ///
    /// **Mutation:** make the continuation scan return an empty array. Run: red.
    /// **Mutation:** drop `concurrencyQualifiers` from the scan's qualifiers. Run: red — the
    /// `Swift.` and `_Concurrency.` fixtures go unseen.
    @Test("The continuation scan sees every spelling of one")
    func theContinuationScanSeesWhatItShould() throws {
        func found(_ source: String) throws -> [String] {
            try Self.mentions(
                of: Self.continuationNames, in: SeamScanner.strippingComments(source),
                qualifiers: Self.moduleQualifiers + Self.concurrencyQualifiers)
        }
        #expect(try found("var c: CheckedContinuation<Void, Never>?") == ["CheckedContinuation"])
        #expect(try found("var c: UnsafeContinuation<Void, Never>?") == ["UnsafeContinuation"])
        #expect(
            try found("await withCheckedContinuation { c in c.resume() }")
                == ["withCheckedContinuation"])
        #expect(
            try found("try await withCheckedThrowingContinuation { c in }")
                == ["withCheckedThrowingContinuation"])
        #expect(
            try found("await withUnsafeContinuation { c in }") == ["withUnsafeContinuation"])
        #expect(
            try found("var c: Swift.CheckedContinuation<Void, Never>?") == ["CheckedContinuation"])
        #expect(
            try found("var c: _Concurrency.CheckedContinuation<Void, Never>?")
                == ["CheckedContinuation"])
        #expect(try found("var c: `CheckedContinuation`<Void, Never>?") == ["CheckedContinuation"])
        #expect(try found("var c: Swift . CheckedContinuation<Void, Never>?").count == 1)

        #expect(try found("/// holds no CheckedContinuation\nlet x = 1").isEmpty)
        #expect(try found("let continuations = 0").isEmpty)
        #expect(try found("let myCheckedContinuation = 1").isEmpty)
        #expect(try found("let c = box.CheckedContinuation").isEmpty)
    }

    // MARK: - Nothing in the daemon stops the timer

    /// The three timer types in `LivenessWatchdog.swift`, which are the only place `cancel` and
    /// the concrete tick source may be named: the protocol a timer is driven through, its
    /// `DispatchSourceTimer` adapter, and the actor that owns one.
    static let timerTypeHeaders = [
        "protocol WatchdogTimer", "struct SystemWatchdogTimer", "actor DispatchWatchdogTicks",
    ]

    /// `code` with the declaration and the body of each type in `headers` taken out. A header
    /// that is not there is left alone: the test that calls this asserts the real file has all
    /// of them.
    static func removing(typesDeclaredBy headers: [String], from code: String) -> String {
        var text = code
        for header in headers {
            guard let declaration = text.range(of: header),
                let open = text[declaration.upperBound...].firstIndex(of: "{")
            else { continue }
            var depth = 0
            var index = open
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                index = text.index(after: index)
            }
            guard index < text.endIndex else { continue }
            text.removeSubrange(declaration.lowerBound...index)
        }
        return text
    }

    /// What `code` says about stopping the timer or naming the concrete tick source **outside**
    /// the timer types: the word `cancel` (any receiver, any cast to reach one) and the name
    /// `DispatchWatchdogTicks`. Read on the normalised text, so `as?  X`, a line break after
    /// `as?`, `if case let real as X = ticks` and a backtick-quoted name are the same thing as
    /// the plain spelling.
    static func timerExposure(in code: String) -> [String] {
        let text = removing(
            typesDeclaredBy: timerTypeHeaders,
            from: WatchdogConfigurationTripwireTests.normalised(code))
        var found: [String] = []
        if text.range(of: #"\bcancel\b"#, options: .regularExpression) != nil {
            found.append("cancel")
        }
        if text.contains("DispatchWatchdogTicks") { found.append("DispatchWatchdogTicks") }
        return found
    }

    /// `DispatchWatchdogTicks.cancel()` exists so that a test which ran the real timer can stop
    /// it. The daemon's watchdog is not stopped by anything: the handler's hold on the watchdog
    /// is what keeps it alive, and a cancelled timer is a watchdog that stopped without saying
    /// so (a `disarm()` that cancelled it, and an `arm()` that then returned early because
    /// `isArmed` was still set, is the failure). `cancel()` is not on the `WatchdogTicking`
    /// protocol, so a caller has to name the concrete type to reach it — and that is named in
    /// exactly two places: where it is declared, and the default argument of `production(…)`.
    ///
    /// Two halves. `LivenessWatchdog.swift`, outside its three timer types, says neither
    /// `cancel` nor the concrete type's name, however it is spelled; and no other file names
    /// the type but `HelperComposition`, once. The behavioural half — a watchdog armed over the
    /// real timer does end the process on its own — is `DispatchWatchdogTicksTests`.
    ///
    /// **Mutation:** `if case let real as DispatchWatchdogTicks = ticks { await real.cancel() }`
    /// in `LivenessWatchdog.arm()`. Run: red here and in the behavioural test.
    /// **Mutation:** `(ticks as?  DispatchWatchdogTicks)?.cancel()` (two spaces). Run: red.
    /// **Mutation:** name `DispatchWatchdogTicks` in any other file under `Sources`. Run: red.
    /// **Mutation:** name it a second time in `HelperComposition.swift`. Run: red.
    @Test("Nothing in the daemon can stop the watchdog's timer")
    func nothingInTheDaemonCancelsTheTimer() throws {
        var naming: [String: Int] = [:]
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let code = WatchdogConfigurationTripwireTests.normalised(
                SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8)))
            let count = code.components(separatedBy: "DispatchWatchdogTicks").count - 1
            if count > 0 { naming[file.lastPathComponent] = count }
        }

        #expect(
            naming.keys.sorted() == ["HelperComposition.swift", "LivenessWatchdog.swift"],
            """
            DispatchWatchdogTicks is named in \(naming.keys.sorted()). The tick source's \
            cancel() is for tests; the files that may name the concrete type are the one that \
            declares it and the one that gives `production` its default.
            """)
        #expect(
            naming["HelperComposition.swift"] == 1,
            "HelperComposition names DispatchWatchdogTicks more than once: only the default")

        let watchdog = try lifecycleSource("LivenessWatchdog.swift")
        for header in Self.timerTypeHeaders {
            #expect(watchdog.contains(header), "\(header) is no longer declared in the file")
        }
        let remaining = Self.removing(
            typesDeclaredBy: Self.timerTypeHeaders,
            from: WatchdogConfigurationTripwireTests.normalised(watchdog))
        #expect(remaining.contains("final class LivenessWatchdog"), "the scan lost the watchdog")
        #expect(
            Self.timerExposure(in: watchdog).isEmpty,
            """
            LivenessWatchdog.swift says \(Self.timerExposure(in: watchdog)) outside its timer \
            types. The watchdog never stops its timer and never names the concrete tick source; \
            a path that cancels it leaves a daemon that logged "armed" and never looks.
            """)
    }

    /// The scan above, over fixtures: every spelling of reaching `cancel` through the concrete
    /// type is found, and the three exempt types are not.
    ///
    /// **Mutation:** make `timerExposure(in:)` return an empty array. Run: red.
    /// **Mutation:** stop removing the timer types in `timerExposure(in:)`. Run: red — the
    /// clean fixture is flagged.
    @Test("The timer scan sees every spelling of reaching cancel")
    func theTimerScanSeesWhatItShould() {
        let exposed = [
            "class W { func f() { if case let r as DispatchWatchdogTicks = t { r.cancel() } } }",
            "class W { func f() async { await (ticks as?  DispatchWatchdogTicks)?.cancel() } }",
            "class W { func f() async { await (ticks as?\n    DispatchWatchdogTicks)?.cancel() } }",
            "class W { func f() async { await (ticks as! `DispatchWatchdogTicks`).cancel() } }",
            "class W { func f() async { await ticks.cancel() } }",
            "class W { func f() { timer . cancel () } }",
            "class W { func f() { timer.`cancel`() } }",
        ]
        for fixture in exposed {
            #expect(!Self.timerExposure(in: fixture).isEmpty, "not seen: \(fixture)")
        }
        let clean = """
            protocol WatchdogTimer { func cancel() }
            struct SystemWatchdogTimer: WatchdogTimer { func cancel() { source.cancel() } }
            actor DispatchWatchdogTicks { func cancel() { timer?.cancel(); timer = nil } }
            final class LivenessWatchdog { func arm() async { await ticks.start { } } }
            """
        #expect(Self.timerExposure(in: clean).isEmpty)
        #expect(Self.timerExposure(in: "class W { let isCancelled = false }").isEmpty)
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
