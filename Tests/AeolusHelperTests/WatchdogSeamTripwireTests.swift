import Foundation
import Testing

@testable import AeolusHelper

/// Two claims about the watchdog's seams that nothing observes at runtime, asserted at the
/// source: the adapter that hands a request to the real `DispatchSourceTimer` hands over what it
/// was given, and the claim on ending the process has the two callers it is documented to have.
///
/// Each scan reads the normalised text (backticks dropped, whitespace collapsed, none either side
/// of a parenthesis) and is run over fixtures first, so that one which has quietly stopped seeing
/// anything cannot pass for a tree that is clean.
@Suite("The watchdog's timer adapter and claim, at the source")
struct WatchdogSeamTripwireTests {

    private func lifecycleSource(_ file: String) throws -> String {
        let url = SeamScanner.sourcesRoot.appendingPathComponent("AeolusHelper/Lifecycle/\(file)")
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - The adapter forwards what it is given

    /// What `SystemWatchdogTimer` does with each request, spelled the one way that passes its
    /// own parameters through. The recorder tests pin the call into the `makeTimer` seam
    /// (`.strict`, the label, the QoS, the period, the leeway); nothing observable pins the layer
    /// below it, because a real `DispatchSourceTimer` does not say what it was given. An adapter
    /// that built its source with `flags: []`, or scheduled it at four seconds, would delay every
    /// verdict by up to two periods and pass every test that merely waits for a tick.
    static let forwardingPins = [
        "DispatchSource.makeTimerSource(flags: flags, queue: queue)",
        "source.schedule(deadline: deadline, repeating: repeating, leeway: leeway)",
        "source.setEventHandler(handler: handler)",
        "source.resume()",
        "source.cancel()",
    ]

    /// The pins that `body` does not contain exactly once.
    static func forwardingProblems(in body: String) -> [String] {
        let text = WatchdogConfigurationTripwireTests.normalised(body)
        return forwardingPins.filter { text.components(separatedBy: $0).count - 1 != 1 }
    }

    /// **Mutation:** `makeTimerSource(flags: [], queue: queue)` in `SystemWatchdogTimer.init`.
    /// Run: red.
    /// **Mutation:** `source.schedule(deadline: deadline, repeating: .seconds(4), leeway:
    /// .seconds(5))`. Run: red.
    /// **Mutation:** delete `source.resume()`. Run: red here and in the real-timer tests.
    @Test("The timer adapter hands the real timer exactly what it is given")
    func theAdapterForwardsVerbatim() throws {
        let body = try #require(
            WatchdogBoundsTripwireTests.body(
                ofTypeDeclaredBy: "struct SystemWatchdogTimer",
                in: try lifecycleSource("LivenessWatchdog.swift")),
            "SystemWatchdogTimer is no longer declared in LivenessWatchdog.swift")

        let problems = Self.forwardingProblems(in: body)
        #expect(
            problems.isEmpty,
            """
            SystemWatchdogTimer no longer contains exactly one \(problems). It must pass the \
            flags, queue, deadline, period, leeway and handler it is given to the real timer \
            unchanged: the seam tests pin what the tick source asks for, and this is the only \
            thing that pins what the adapter does with it.
            """)
    }

    /// The pin check, over fixtures.
    ///
    /// **Mutation:** make `forwardingProblems(in:)` return an empty array. Run: red.
    @Test("The adapter scan sees a parameter that is not passed through")
    func theForwardingScanSeesWhatItShould() {
        let faithful = """
            init(flags: DispatchSource.TimerFlags, queue: DispatchQueue) {
                source = DispatchSource.makeTimerSource(flags: flags, queue: queue)
            }
            func schedule(
                deadline: DispatchTime, repeating: DispatchTimeInterval,
                leeway: DispatchTimeInterval
            ) {
                source.schedule(deadline: deadline, repeating: repeating, leeway: leeway)
            }
            func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
                source.setEventHandler(handler: handler)
            }
            func resume() { source.resume() }
            func cancel() { source.cancel() }
            """
        #expect(Self.forwardingProblems(in: faithful).isEmpty)

        func broken(_ old: String, _ new: String) -> String {
            faithful.replacingOccurrences(of: old, with: new)
        }
        #expect(
            Self.forwardingProblems(
                in: broken("makeTimerSource(flags: flags", "makeTimerSource(flags: []"))
                == [Self.forwardingPins[0]])
        #expect(
            Self.forwardingProblems(
                in: broken(
                    "repeating: repeating, leeway: leeway)",
                    "repeating: .seconds(4), leeway: .seconds(5))"))
                == [Self.forwardingPins[1]])
        #expect(
            Self.forwardingProblems(in: broken("source.resume()", "()")) == [Self.forwardingPins[3]]
        )
        // A second call is as wrong as a missing one.
        #expect(
            Self.forwardingProblems(in: faithful + "\nfunc again() { source.resume() }")
                == [Self.forwardingPins[3]])
    }

    // MARK: - The claim has two callers

    /// The call sites of `claim(…)` in `code`: a call, not the declaration, and not a longer
    /// name (`reclaim(`, `claimed(`).
    static func claimCallSites(in code: String) throws -> Int {
        let text = WatchdogConfigurationTripwireTests.normalised(code)
        return try NSRegularExpression(pattern: #"(?<!func )(?<![\w])claim\("#)
            .numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    /// `ProcessTermination.claim(_:)` takes the claim without ending the process, and **whoever
    /// is granted it must end it**: every later request is refused as "already ending", so a
    /// caller that took the claim only to *ask* whether the process is ending would leave a
    /// helper that logs every verdict as refused and never exits. It has exactly two callers —
    /// `LivenessWatchdog.tick()`, which ends the process on the grant, and
    /// `ProcessTermination.end(_:)`, which the teardown uses — and a third is a decision for a
    /// reviewer to see, which is what failing here makes it.
    ///
    /// **Mutation:** `_ = termination.claim(.restored)` anywhere else in `Sources/AeolusHelper`.
    /// Run: red.
    @Test("Only the watchdog and the termination itself take the claim")
    func theClaimHasTwoCallers() throws {
        var sites: [String: Int] = [:]
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let code = SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8))
            let count = try Self.claimCallSites(in: code)
            if count > 0 { sites[file.lastPathComponent] = count }
        }

        #expect(
            sites == ["LivenessWatchdog.swift": 1, "ProcessTermination.swift": 1],
            """
            claim(_:) is called from \(sites.sorted(by: { $0.key < $1.key })). A granted claim \
            must be ended, and every later request is refused once one is taken; only \
            LivenessWatchdog.tick() and ProcessTermination.end(_:) may take it.
            """)
    }

    /// The count, over fixtures.
    ///
    /// **Mutation:** make `claimCallSites(in:)` return zero. Run: red.
    /// **Mutation:** drop the `func ` lookbehind. Run: red — the declaration is counted.
    @Test("The claim scan counts a call and nothing else")
    func theClaimScanSeesWhatItShould() throws {
        #expect(try Self.claimCallSites(in: "switch termination.claim(.blind) {") == 1)
        #expect(try Self.claimCallSites(in: "let c = termination . claim (.blind)") == 1)
        #expect(try Self.claimCallSites(in: "let c = termination.`claim`(.blind)") == 1)
        #expect(try Self.claimCallSites(in: "claim(outcome)\nclaim(other)") == 2)
        #expect(
            try Self.claimCallSites(in: "func claim(_ outcome: TeardownOutcome) -> Claim {") == 0)
        #expect(try Self.claimCallSites(in: "func reclaim(x)\nlet y = claimed(x)") == 0)
    }
}
