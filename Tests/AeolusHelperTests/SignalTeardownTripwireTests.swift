import Foundation
import Testing

@testable import AeolusHelper

/// The claims about § 6's teardown that have **nothing to observe at runtime**, asserted at
/// the source instead.
///
/// Split out of `SignalTeardownTests` when #197's review added two more of them, and the
/// split is along a real seam rather than a line count: everything in that file drives the
/// composed helper and asserts on an ordered journal, and everything here reads the tree.
/// A source tripwire is this repository's last resort, and each one below states why the
/// behavioural test it would rather be does not exist.
@Suite("What § 6's teardown must and must not contain")
struct SignalTeardownTripwireTests {

    /// The one type name this file may not spell.
    ///
    /// `theSuiteNeverConstructsTheRealSignalSources` scans `Tests/AeolusHelperTests` for
    /// exactly this token, and `SeamScanner.strippingComments` deliberately preserves string
    /// literals — so a tripwire that wrote the name out would fire on itself. Assembling it
    /// from two halves is what keeps both tripwires honest at once.
    private static let realSources = "DispatchSignal" + "Sources"

    private func helperSource(_ file: String) throws -> String {
        let url = SeamScanner.sourcesRoot
            .appendingPathComponent("AeolusHelper/Lifecycle/\(file)")
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - What must not be in the tree

    /// No crash-signal source, no mach exception port, no `atexit`, anywhere in the helper.
    ///
    /// A source tripwire because there is nothing to observe at runtime: a crash handler is
    /// visible only when the process crashes, and by then the test is the crash. § 6's
    /// ruling is that crash coverage is restart plus reconciliation, uniformly — a handler
    /// calling `IOConnectCallStructMethod` from signal context is undefined behaviour on the
    /// one path it exists to serve.
    ///
    /// `atexit` is here for a **different** reason and the two must not be conflated. It runs
    /// in normal context, so it is not undefined behaviour; it is simply useless for this,
    /// because every step of the teardown is `async` and an `atexit` body is synchronous. The
    /// only bridge is blocking an exiting process on a semaphore. ADR 0007 permitted the belt
    /// when it was written and its amendment records the correction.
    ///
    /// `sigaction` is on the list although the acceptance criteria do not name it: installing
    /// one puts a handler body back into signal context, which is the whole of what § 6's
    /// `SIG_IGN`-plus-`DispatchSourceSignal` shape exists to avoid. It is the same defect
    /// reached by a different call.
    ///
    /// **Mutation:** add a `DispatchSource.makeSignalSource(signal: SIGSEGV, queue: …)` — or
    /// any of the other nine tokens — to a file under `Sources/AeolusHelper`. Run: red.
    @Test("The helper installs no crash handler, no exception port, and no atexit")
    func noCrashHandlingExistsInTheTree() throws {
        let forbidden = [
            "SIGSEGV", "SIGBUS", "SIGILL", "SIGABRT", "SIGFPE",
            "task_set_exception_ports", "thread_set_exception_ports",
            "host_set_exception_ports", "atexit", "sigaction",
        ]

        var found: [String] = []
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            for token in forbidden where code.contains(token) {
                found.append("\(file.lastPathComponent): \(token)")
            }
        }

        #expect(
            found.isEmpty,
            """
            \(found.sorted()). A crash is exactly when heap and lock state are unknown, and \
            `IOConnectCallStructMethod` is not async-signal-safe — docs/SAFETY.md § 6 gives \
            crash signals no in-process restore at all. `atexit` is excluded for its own \
            reason: the restore is `async`, so an `atexit` body could only block an exiting \
            process on a semaphore.
            """)
    }

    // MARK: - The exit

    /// The orderly path is the only thing in the helper that ends the process, and no exit
    /// code is written as a literal anywhere.
    ///
    /// A3 makes the exit code a contract: `SuccessfulExit = false` means launchd reads a zero
    /// exit as *no fan is off automatic control because of Aeolus, do not restart me*. A
    /// second exit site anywhere would compile, pass every behavioural test, and quietly say
    /// that about a helper that restored nothing.
    ///
    /// **The zero-exit half changed shape in #197 and is now stricter.** It used to count the
    /// literal `exit(0)` and require exactly one, which had two holes: `exit( 0 )` and
    /// `exit(0 as Int32)` both evaded a literal substring search, and the switch that chose
    /// between the codes lived inside a closure calling `exit`, where no test could execute
    /// it. The mapping is now `TeardownOutcome.exitCode`, a pure function
    /// `theOutcomesCarryTheExitCodesTheRestartPolicyReads` runs, and the shipping seam is
    /// `exit($0.exitCode)` — so the correct count of literal exit codes in this target is
    /// **zero**, and a literal reappearing is a second mapping competing with the tested one.
    /// The pattern is the tolerant one either way: `\s*` around the parenthesis and a word
    /// boundary after the digit.
    ///
    /// Ruling D20 on #197: this is the one exit-count tripwire. #199 shipped a second in
    /// `LaunchDaemonPlistTests` — the literal `exit(0)` counted over raw source, comments
    /// included, asserted at zero until the teardown landed — and the rebase onto it folded
    /// that one into this. The regex form stays; comments are stripped first, so the prose
    /// explaining the rule cannot trip it; and the count is of **call sites**, exactly one,
    /// in `SignalTeardown.swift`. The earlier form here asserted the set of files, which a
    /// second `exit` inside the teardown's own file would have passed.
    ///
    /// **Mutation:** add `exit(1)` to any other file under `Sources/AeolusHelper`. Run: red.
    /// **Mutation:** add a second `exit($0.exitCode)` to `SignalTeardown.swift`. Run: red.
    /// **Mutation:** write `exit(0)`, `exit( 0 )` or `exit(0 as Int32)` anywhere in the
    /// target, `SignalTeardown.swift` included. Run: red.
    @Test("The helper ends the process in one place, and writes no exit code as a literal")
    func theOrderlyPathIsTheOnlyExit() throws {
        let call = try NSRegularExpression(pattern: #"(?<![\w.])exit\s*\("#)
        let literalCode = try NSRegularExpression(pattern: #"(?<![\w.])exit\s*\(\s*\d"#)
        var sites: [String: Int] = [:]
        var literals: [String] = []

        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            let calls = call.numberOfMatches(in: code, range: range)
            if calls > 0 { sites[file.lastPathComponent] = calls }
            if literalCode.numberOfMatches(in: code, range: range) > 0 {
                literals.append(file.lastPathComponent)
            }
        }

        #expect(
            sites == ["SignalTeardown.swift": 1],
            """
            the helper ends the process somewhere other than the orderly teardown's one \
            call, or more than once: \(sites.sorted { $0.key < $1.key }). Every other exit \
            is a root daemon leaving the fans wherever they were, with launchd told nothing \
            useful about it.
            """)
        #expect(
            literals.isEmpty,
            """
            an exit code is written as a literal in \(literals.sorted()). The one mapping \
            from outcome to code is `TeardownOutcome.exitCode`, which a test executes; a \
            literal beside it is a second mapping that nothing checks, and decision A3 pairs \
            a zero exit with `KeepAlive = { SuccessfulExit = false }`.
            """)
    }

    // MARK: - The signal sources

    /// The three lines of `serve(_:with:)` that make a real signal reach the teardown.
    ///
    /// **Nothing else in this repository covers them, and that is a deliberate limit rather
    /// than an oversight.** Exercising them needs the real thing, and the real thing calls
    /// `signal(_, SIG_IGN)` — process-wide, permanent, and applied to the `swift test`
    /// runner. A suite that installed it would leave the run uninterruptible and would then
    /// end the runner on the next `SIGTERM`, reporting success for a run that never
    /// finished. The alternative, a child process that installs the source and raises a
    /// signal at itself, needs an executable target this package does not build for tests.
    ///
    /// So the three properties are asserted at the source, and each one is a distinct silent
    /// failure:
    ///
    /// - **`SIG_IGN` first.** Without it the kernel applies the default disposition and kills
    ///   the helper before the source's handler ever runs, because a `DispatchSourceSignal`
    ///   observes delivery rather than intercepting it. The fans are then left wherever they
    ///   were, on every `launchctl bootout`.
    /// - **`resume()`.** A dispatch source is created suspended. One that is never resumed
    ///   serves no signal, and nothing anywhere reports it.
    /// - **The append into the retained array.** A `DispatchSourceSignal` released by ARC is
    ///   cancelled, so a source held only by a local is a signal nobody serves — and the
    ///   failure appears at the moment the machine is shutting down.
    ///
    /// **Mutation:** delete `_ = signal(number, SIG_IGN)`. Run: red.
    /// **Mutation:** delete `source.resume()`. Run: red.
    /// **Mutation:** delete `sources.append(source)`. Run: red.
    @Test("The daemon's signal sources are ignored first, resumed, and retained")
    func theRealSignalSourcesAreInstalledCorrectly() throws {
        let file = try helperSource("SignalTeardown.swift")
        let start = try #require(
            file.range(of: "actor \(Self.realSources)"),
            "the daemon's signal sources are no longer declared in SignalTeardown.swift")
        let end = try #require(
            file.range(of: "actor SignalTeardown"),
            "SignalTeardown is no longer declared after the sources it is served by")
        let body = String(file[start.lowerBound..<end.lowerBound])

        #expect(
            body.contains("SIG_IGN"),
            """
            the daemon no longer replaces the default disposition of the orderly signals, so \
            the kernel terminates the helper before any handler runs and no fan is handed \
            back on shutdown.
            """)
        #expect(
            body.contains("resume()"),
            """
            a dispatch source is created suspended. One that is never resumed serves no \
            signal at all, and nothing reports it.
            """)
        #expect(
            body.contains("sources.append("),
            """
            the signal sources are not retained. ARC cancels a released \
            `DispatchSourceSignal`, so the teardown would be uninstalled the moment \
            `serve(_:with:)` returned — silently, and at the moment the machine is shutting \
            down.
            """)
    }

    /// **Nothing under `Tests/` may construct the daemon's real signal sources.**
    ///
    /// Stated in `SignalTeardownDoubles` since E5.4d and enforced by nothing until #197's
    /// review said so. `serve(_:with:)` calls `signal(_, SIG_IGN)`, which is process-wide and
    /// permanent: a single test that used the real one would leave `swift test` unable to be
    /// interrupted, and would then end the runner with a zero exit on the next `SIGTERM` —
    /// reporting success for a run that never finished. That is a failure mode nobody would
    /// diagnose from the output, because the output would say the suite passed.
    ///
    /// **Mutation:** name the type anywhere under `Tests/AeolusHelperTests`. Run: red.
    @Test("No test constructs the daemon's real signal sources")
    func theSuiteNeverConstructsTheRealSignalSources() throws {
        var found: [String] = []
        for file in try SeamScanner.swiftFiles(underTests: "AeolusHelperTests") {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            if code.contains(Self.realSources) {
                found.append(file.lastPathComponent)
            }
        }

        #expect(
            found.isEmpty,
            """
            \(found.sorted()) names the daemon's real signal sources. Constructing one \
            applies `SIG_IGN` to the test runner permanently and hands the next `SIGTERM` to \
            a teardown that exits the process zero — a run that reports success without \
            finishing. `RecordingSignalSources` is the double, and it installs nothing.
            """)
    }
}
