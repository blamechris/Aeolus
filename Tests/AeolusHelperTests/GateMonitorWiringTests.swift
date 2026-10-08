import Foundation
import Testing

@testable import AeolusHelper

/// The gate monitor's wiring, kept out of `HelperCompositionTests.swift` because that file is at
/// SwiftLint's `file_length` ceiling and its suite at `type_body_length`'s. An extension of the
/// same suite, so that it reads the composition's source through the same helpers
/// (`compositionSource()`, `strippingWhitespace(_:)`, `strippingComments(_:)`), which are
/// internal for the purpose: a second copy of them would be a second scanner.
extension HelperCompositionTests {

    /// The gate monitor the scheduler reports to is the one the watchdog reads.
    ///
    /// The same hazard as the connection health observer's, one level over, and it has the same
    /// shape: a monitor that is constructed, held, handed to the watchdog and **told nothing**
    /// reads an empty queue for ever, and the third trigger watches nothing while looking
    /// exactly like one that does. `main()` never returns and the scheduler holds its observer
    /// privately, so the scheduler's half is a source tripwire; the watchdog's half is
    /// behavioural, in `HelperWatchdogCompositionTests`.
    ///
    /// One local, named once, in both places: the fan-out the scheduler is built with and the
    /// `gateMonitor:` argument the composition is built with.
    ///
    /// The third check counts constructions however they are spelled (see
    /// `gateMonitorConstructions(in:)`).
    ///
    /// **Mutation A:** drop `gateMonitor` from the scheduler's observers. Run: red on the first.
    /// **Mutation B:** hand the composition `gateMonitor: GateWaitMonitor()` instead of the
    /// local. Run: red on the second.
    /// **Mutation C:** build a second monitor anywhere in `Sources/AeolusHelper` but the
    /// composition's default and `production` — `GateWaitMonitor()`, `GateWaitMonitor ()`, or
    /// `let m: GateWaitMonitor = .init()`. Run: red on the third, for each spelling.
    @Test("The scheduler reports to the gate monitor the watchdog reads")
    func theGateMonitorIsWiredToTheSchedulerAndTheWatchdog() throws {
        let source = Self.strippingWhitespace(try Self.compositionSource())

        let schedulerReportsToIt = source.contains(
            "observer:SchedulerObservers([connectionHealth,gateMonitor])")
        #expect(
            schedulerReportsToIt,
            """
            the scheduler no longer reports to the gate monitor, so the watchdog's gate \
            trigger reads an empty queue for ever.
            """)

        // Inside `production`, not anywhere in the file: the initialiser also says
        // `gateMonitor: gateMonitor` when it hands the monitor to the watchdog, and that is the
        // other half of the wiring, not this one.
        let production = try #require(
            source.range(of: "staticfuncproduction("), "production(…) is no longer declared")
        let watchdogReadsIt = source[production.lowerBound...].contains("gateMonitor:gateMonitor,")
        #expect(
            watchdogReadsIt,
            "production no longer hands the composition the monitor the scheduler reports to")

        var constructions: [String] = []
        for file in try SeamScanner.swiftFiles()
        where file.pathComponents.contains("AeolusHelper") {
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            let count = try Self.gateMonitorConstructions(in: code)
            if count > 0 { constructions.append("\(file.lastPathComponent) x\(count)") }
        }
        #expect(
            constructions == ["HelperComposition.swift x2"],
            """
            the helper builds gate monitors at \(constructions). The composition's default and \
            `production` are the two: a third is a monitor nothing is told anything.
            """)
    }

    /// How many times `code` builds a `GateWaitMonitor`, **however it is spelled**: on the text
    /// normalised the way the watchdog's tripwires normalise it (backticks dropped, whitespace
    /// collapsed, none either side of a parenthesis), a call to the type (`GateWaitMonitor()`,
    /// `GateWaitMonitor ()`, `GateWaitMonitor.init()`, module-qualified or not), an inferred
    /// initialiser (`let m: GateWaitMonitor = .init()`), and a `typealias` of the type, which is a
    /// route to one. A name that merely ends in the type's (`MyGateWaitMonitor()`) is not.
    static func gateMonitorConstructions(in code: String) throws -> Int {
        let text = WatchdogConfigurationTripwireTests.normalised(code)
        let patterns = [
            #"(?<![\w])GateWaitMonitor(?:\s*\.\s*init)?\s*\("#,
            #"(?<![\w])GateWaitMonitor\s*=\s*\.\s*init\s*\("#,
            #"typealias\s+\w+\s*=\s*(?:\w+\s*\.\s*)?GateWaitMonitor(?![\w])"#,
        ]
        return try patterns.reduce(0) { total, pattern in
            total
                + (try NSRegularExpression(pattern: pattern)
                    .numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)))
        }
    }

    /// The scan above, over fixtures: every spelling of building the type is found once, and prose,
    /// a bare mention and a longer name are not.
    ///
    /// **Mutation:** drop the whitespace normalisation (`GateWaitMonitor ()` goes unseen). Run:
    /// red.
    /// **Mutation:** drop the `.init` alternatives. Run: red.
    /// **Mutation:** make the scan return zero. Run: red.
    @Test("The construction scan sees every spelling of building a gate monitor")
    func theConstructionScanSeesWhatItShould() throws {
        func found(_ source: String) throws -> Int {
            try Self.gateMonitorConstructions(in: Self.strippingComments(source))
        }
        let built = [
            "let m = GateWaitMonitor()",
            "let m = GateWaitMonitor ()",
            "let m = GateWaitMonitor\n    ()",
            "let m = GateWaitMonitor.init()",
            "let m = GateWaitMonitor . init ()",
            "let m: GateWaitMonitor = .init()",
            "let m: GateWaitMonitor = . init ()",
            "let m = `GateWaitMonitor`()",
            "let m = AeolusHelper.GateWaitMonitor()",
            "typealias Gate = GateWaitMonitor",
        ]
        for fixture in built {
            #expect(try found(fixture) == 1, "not seen exactly once: \(fixture)")
        }
        let notBuilt = [
            "let m: GateWaitMonitor",
            "gateMonitor: GateWaitMonitor,",
            "let m = MyGateWaitMonitor()",
            "let t = GateWaitMonitorTests()",
            "/// builds a GateWaitMonitor()\nlet x = 1",
            "// GateWaitMonitor ()\nlet x = 1",
        ]
        for fixture in notBuilt {
            #expect(try found(fixture) == 0, "seen in code that builds none: \(fixture)")
        }
        // The shipped default argument: one construction, not two.
        #expect(try found("gateMonitor: GateWaitMonitor = GateWaitMonitor(),") == 1)
    }
}
