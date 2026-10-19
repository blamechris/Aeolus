import ArgumentParser
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl reset --all`, end to end: **the shipping `run()`**, the real `HelperClient`, a real
/// `NSXPCListener` and the real `HelperConnectionSession` behind it.
///
/// **`run()` itself, and that is the point of this file's shape.** An earlier version of this
/// suite drove a test-only `run(restoring:)` overload, so every decision the shipping path
/// makes was covered by nothing: rewriting `run()` to `try emit(accepted)` printed "the helper
/// accepted the reset request", contacted nothing, and left 1425 tests green. Three decisions
/// live there and each has an assertion below — the verb that is sent, the deadline it is sent
/// with, and the `disconnect()` afterwards. `HelperConnection` exists so they can
/// be reached without being replaced.
///
/// **Why this suite lives here rather than in `fanctlTests`.** The only peer the real client
/// can be driven against is the real helper session, and that is behind
/// `@testable import AeolusHelper`. Driving the command from `fanctlTests` instead would mean
/// a second listener harness, a second unenforced pinning policy and a stub exported object —
/// three copies of things that already exist in this target, none of which is the helper. The
/// same argument put `AeolusXPCClient` here in #237.
///
/// What none of it proves, and what the acceptance criterion still waits on: that a **signed**
/// `fanctl` is admitted by an **installed** helper. A `swift build` binary carries no Team ID
/// and is refused at both ends by design (ADR 0005), so hardware acceptance of this command is
/// blocked on [#82](https://github.com/blamechris/Aeolus/issues/82).
@Suite("fanctl reset --all against a real helper session", .timeLimit(.minutes(3)))
struct FanctlResetTests {

    /// One run's observable result: what swift-argument-parser would print, and what it
    /// would exit with. Shared with `FanctlResetCorruptedStateTests`, which drives the same
    /// shipping `run()` against a composed helper.
    struct Emitted {
        let message: String
        let exitCode: ExitCode
    }

    /// Deadlines long enough that a loaded runner cannot fake a failure — **for this suite, and
    /// no other**.
    ///
    /// `private` on purpose. A deadline this long is only safe under a time limit that sits above
    /// it, and this is the one suite whose limit does. When it was `unhurried` and internal, six
    /// other suites took it by default ([#443](https://github.com/blamechris/Aeolus/issues/443)):
    /// two with one-minute limits ended on "Time limit was exceeded" before the client's own
    /// "did not confirm" could surface, and three with no limit at all ran for two to three
    /// minutes when a request was dropped. Every other suite takes
    /// `ClientListenerHarness.defaultDeadlines`, the product's trio, and the compiler now says so.
    ///
    /// **Mutation:** make the harness drop the panic request — `ClientListenerHarness`'s
    /// `restoreAllToAutomatic(reply:)` neither forwards it nor replies. Run: red, at the
    /// deadline, within the suite's time limit: the answering tests report "did not confirm".
    ///
    /// **Three of these tests assert text and an exit code and nothing about timing**, so a
    /// short deadline buys them nothing and costs a red CI run — a working helper reported as
    /// one that never answered, which is the exact misreport this suite exists to forbid. That
    /// is what happened to the client suites in
    /// [#250](https://github.com/blamechris/Aeolus/issues/250), where `ClientListenerHarness`
    /// defaulted to 750 ms: a bound this machine never approaches and a contended GitHub runner
    /// exceeded for a message the helper had already answered. That harness now defaults to the
    /// shipping trio, so this comment no longer describes a 750 ms default anywhere.
    ///
    /// The generous terms are `gatedVerb` and `panicVerb`, which may sit **above** the product's
    /// 5 s and 10 s — tolerating a slow machine is never the defect. Of those two, `panicVerb`
    /// is the one that matters here: `fanctl reset --all` *is* the panic path, so that term is
    /// the bound every round trip in this suite actually runs under.
    ///
    /// `handshakeVerb` is the product's own 15 s and not a fourth invention — it was
    /// `.seconds(10)`, 5 s *tighter* than what a cold `hello` is allowed. **What that fixed was
    /// an invention, not a live misreport, and the difference is worth stating precisely because
    /// this is the reasoning a later reader will reuse to decide which bounds matter.** No test
    /// in this suite sends a handshake at all: `run()` reaches the helper through
    /// `HelperClient.restoreAllToAutomatic()`, which takes the ungated proxy with no `hello` in
    /// front of it (ADR 0005's exemption), and `theCommandSendsNoHandshake` asserts exactly that
    /// — `session.handshakeState == nil`. So this term was inert, and a contended runner could
    /// not have turned it red; the misreport #250 is about needs a handshake to be sent. It is
    /// held to the product's value anyway, because an invented bound is what the first test that
    /// *does* send one would silently inherit.
    ///
    /// ## Stall-tolerant: the product's term plus the stall ceiling
    ///
    /// [#341](https://github.com/blamechris/Aeolus/issues/341) made the suite's *waits* count only
    /// the time the waiter ran, and these deadlines were the one wall-clock bound left in front of
    /// a reply. Twice on #439's CI the runner was CPU-starved for the first ~30 s of the run —
    /// 2,675 tests in 41 s, every test in this suite taking ~34 s — and a 10 s panic deadline
    /// expired before the request was even delivered: `harness.arrivals` empty, "did not confirm
    /// the reset request", and a refused connection reported as an unanswered one. A deadline the
    /// client enforces cannot be compensated the way a poll is, because the poll is not the one
    /// waiting, so each term the answering tests run under is the product's own **plus
    /// `StallTolerantWait.ceiling`**: 55 s gated, 60 s on the panic path. That ceiling is the most
    /// wall time any one wait may take, stall compensation included — a total cap, not an amount
    /// of compensation granted on top of the wait — so adding it to a product term is this
    /// suite's choice of how long a stall to outlast.
    ///
    /// A request that genuinely never arrives still fails at that deadline, with the client's own
    /// "did not confirm", and this suite's three-minute `.timeLimit` sits above it, so it fails
    /// rather than hangs. **That is true of this suite only.** One minute is below 60 s, so a
    /// suite with the usual limit that waited this long would be ended by its limit, with "Time
    /// limit was exceeded", before the client could say anything. The one test that asserts a
    /// deadline passes its own (`observableDeadline`).
    ///
    /// Written as literals because `HelperClientDeadlineLiteralTests` reads every deadline passed
    /// in the test target and must resolve each to a duration;
    /// `theAnsweringDeadlinesAreTheProductsPlusTheStallCeiling` holds the derivation.
    private static let stallTolerant = HelperClientDeadlines(
        gatedVerb: .seconds(55),
        panicVerb: .seconds(60),
        handshakeVerb: HelperClientDeadlines.handshakeVerb)

    /// `stallTolerant`'s gated and panic terms are the product's plus `StallTolerantWait.ceiling`
    /// (#341), so a change to either moves them, rather than leaving a literal that has drifted
    /// from its reason. Its handshake term is the product's own: nothing here sends a `hello`, so
    /// a stall allowance on it would be inert, and an invented one is what the first test that
    /// did send one would inherit. `noHarnessDefaultImposesATighterDeadlineThanTheProduct` used to
    /// read this constant; being `private`, it cannot, so this is where all three terms are held.
    ///
    /// **Mutation:** set `stallTolerant`'s panic term to `.seconds(10)`. Run: red.
    /// **Mutation:** set `stallTolerant`'s handshake term to `.seconds(10)`. Run: red.
    @Test("The answering tests' deadlines are the product's plus the stall ceiling")
    func theAnsweringDeadlinesAreTheProductsPlusTheStallCeiling() {
        #expect(
            Self.stallTolerant.gatedVerb
                == HelperClientDeadlines.gatedVerb + StallTolerantWait.ceiling)
        #expect(
            Self.stallTolerant.panicVerb
                == HelperClientDeadlines.panicVerb + StallTolerantWait.ceiling)
        #expect(Self.stallTolerant.handshakeVerb == HelperClientDeadlines.handshakeVerb)
    }

    /// The one deadline this suite asserts on, in the one test whose peer never replies.
    ///
    /// **Two seconds, and it is neither 5 nor 10 on purpose:** those are the shipping
    /// `gatedVerb` and `panicVerb`, so a `run()` that ignored the deadline it was given and
    /// hardcoded either of them would still produce a plausible-looking message. This one is
    /// distinguishable from both in the text the client renders. It is also the wall clock
    /// this suite actually spends, and the shortest figure that leaves a slow runner no way to
    /// make a delivered message look undelivered.
    private static let observableDeadline = Duration.seconds(2)

    /// Parsed rather than constructed, so `--all` reaching the flag and `validate()`
    /// accepting the invocation are part of every case below.
    private static func resetAll() throws -> Fanctl.Reset {
        try #require(Fanctl.parseAsRoot(["reset", "--all"]) as? Fanctl.Reset)
    }

    /// Runs the **shipping** `run()` against one listener and captures how it left.
    ///
    /// Only the connection is substituted — where to look, who may answer, how long to wait.
    /// The verb, the teardown and the report all come from the function under test.
    ///
    /// `deadlines` defaults to the product's, through the harness, so a suite that calls this
    /// without naming one is bounded as the client is shipped. This suite's own answering tests
    /// pass `stallTolerant`, which only they may.
    static func emitted(
        over harness: ClientListenerHarness,
        waiting deadlines: HelperClientDeadlines = ClientListenerHarness.defaultDeadlines
    ) async throws -> Emitted {
        var command = try resetAll()
        command.helper = HelperConnection(
            transport: .endpoint(harness.endpoint),
            pinning: UnenforcedClientPinning(),
            deadlines: deadlines)
        do {
            try await command.run()
            Issue.record("fanctl reset returned without an exit code")
            return Emitted(message: "", exitCode: .success)
        } catch {
            return Emitted(
                message: Fanctl.message(for: error),
                exitCode: Fanctl.exitCode(for: error))
        }
    }

    // MARK: - The helper accepted

    /// A helper that accepts the request: exit 0, and a message that claims acceptance and
    /// stops there.
    ///
    /// The authority call count is the half that makes the text an assertion rather than a
    /// description — without it this would pass against a command that printed "accepted"
    /// having sent nothing at all, which is exactly what `run()` was free to do while only a
    /// test-only overload was covered.
    ///
    /// **Mutation:** replace `run()`'s body with `try ResetCommand.emit(ResetCommand.accepted)`.
    /// Run: red on the authority's call count and on the arrivals — the two expectations that
    /// know the difference between reporting an answer and inventing one.
    @Test("An accepted request exits 0, reached the helper, and claims no restore")
    func anAcceptedRequestExitsZeroAndClaimsNoRestore() async throws {
        let authority = RecordingFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let emitted = try await Self.emitted(over: harness, waiting: Self.stallTolerant)

        #expect(emitted.exitCode == .success)
        #expect(emitted.message.contains("accepted the reset request"))
        #expect(
            emitted.message.contains(
                "has not reported that any fan is back under automatic control"))

        let restores = await authority.calls.filter {
            if case .restoreAllToAutomatic = $0 { return true }
            return false
        }
        #expect(restores.count == 1, "the request did not reach the helper")
        #expect(
            harness.arrivals == ["restoreAllToAutomatic", "restoreAllToAutomatic→replied"],
            "the arrivals were \(harness.arrivals)")
    }

    /// The panic path `fanctl` sends carries no handshake, which is acceptance criterion 2.
    ///
    /// ADR 0005 exempts `restoreAllToAutomatic` from the version gate — its only expressible
    /// effect is the safe state, and a version fence that stopped a panicked user's older
    /// client from restoring automatic control would be a safety mechanism defeating safety.
    /// The exemption is only worth anything if the *command* uses it: a `hello` in front of
    /// the panic path is one more round trip that can fail, in the state where things are
    /// already failing.
    ///
    /// **Mutation:** route `HelperClient.restoreAllToAutomatic()` through
    /// `withHandshakenProxy`. Run: red on both expectations — and
    /// `HelperClientSeamTests.theUnhandshakenProxyHasExactlyOneCaller` goes red with it.
    @Test("The command's request is sent with no handshake behind it")
    func theCommandSendsNoHandshake() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())

        let emitted = try await Self.emitted(over: harness, waiting: Self.stallTolerant)
        #expect(emitted.exitCode == .success)

        let session = try #require(harness.sessions.first)
        #expect(await session.messageCount == 1, "only the panic path was sent")
        #expect(await session.handshakeState == nil, "the command sent a hello")
    }

    /// `run()` invalidates the connection rather than letting the reference die with the
    /// process.
    ///
    /// The helper releases what a connection was holding from its listener's invalidation
    /// handler, which fires only if somebody invalidates. Nothing is held on this build — no
    /// lease can exist — so this is a guard on the shape rather than on a present leak, and it
    /// is asserted because `await client.disconnect()` is the third decision that lived in
    /// `run()` with nothing covering it.
    ///
    /// **Mutation:** delete `await client.disconnect()` from `run()`. Run: red — the authority
    /// is never told the connection went away.
    @Test("run() gives the connection back rather than dropping it")
    func theCommandInvalidatesItsConnection() async throws {
        let authority = RecordingFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let emitted = try await Self.emitted(over: harness, waiting: Self.stallTolerant)
        #expect(emitted.exitCode == .success)

        // Bounded: the helper's invalidation handler hands off to a detached task, so the
        // event is ordered after `run()` returns but not synchronous with it. A `run()` that
        // never disconnected leaves this empty for the whole timeout.
        try await waitUntil("the helper was told the connection went away") {
            await authority.calls.contains {
                if case .connectionDidInvalidate = $0 { return true }
                return false
            }
        }
    }

    // MARK: - The helper never answered

    /// A helper that accepts the request and never answers: non-zero, the text says the effect
    /// is unknown rather than guessing either way, and `run()` waited the deadline it was
    /// given.
    ///
    /// This is `docs/SAFETY.md` § 4's wedged `io_connect_t`, constructed rather than waited
    /// for: the authority parks inside the panic path, so the helper has the message and the
    /// reply never comes. `NSXPCConnection` has no per-message timeout, so what turns that
    /// into an answer at all is the client's own `panicVerb` deadline.
    ///
    /// **The deadline assertion is the binding, not the constant.** `HelperClientDeadlines`
    /// already names 10 s and `ResetCommandTests` pins that number to D26 item 4; what nothing
    /// caught until review was whether `run()` *uses* it. The client renders the deadline it
    /// actually waited into this message, so injecting a figure that is neither 5 nor 10 makes
    /// the binding readable from the output.
    ///
    /// **Mutation:** in `run()`, replace `deadlines: helper.deadlines` with an explicit
    /// `HelperClientDeadlines(gatedVerb: .seconds(5), panicVerb: .seconds(5), handshakeVerb:
    /// .seconds(5))`. Run: red — the message names 5.0 seconds.
    @Test("A helper that never answers exits non-zero, says the effect is unknown, and waits")
    func aHelperThatNeverAnswersIsReportedAsUnknown() async throws {
        let gate = AsyncSignal()
        let authority = GatedRestoreAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)

        // The two short terms are the assertion — `observableDeadline` is what the message below
        // must name. The handshake term is not asserted by anything and no test here sends a
        // `hello` in any case, so it is the product's value rather than the tenth explicitly
        // passed invention in the target: the same reason `stallTolerant` carries it.
        let emitted = try await Self.emitted(
            over: harness,
            waiting: HelperClientDeadlines(
                gatedVerb: Self.observableDeadline,
                panicVerb: Self.observableDeadline,
                handshakeVerb: HelperClientDeadlines.handshakeVerb))

        #expect(emitted.exitCode != .success)
        #expect(emitted.message.contains("did not confirm the reset request"))
        #expect(
            emitted.message.contains("Nothing can be said about whether it took effect"),
            """
            a wedged helper was reported as "\(emitted.message)". Neither "restored" nor \
            "failed" is observable here: the helper has the message and may yet act on it.
            """)
        #expect(emitted.message.contains("sudo launchctl bootout system/"))

        // The literal, not `\(Self.observableDeadline)`: interpolating the same value on both
        // sides would compare the deadline to itself and pass whatever `run()` waited.
        #expect(
            emitted.message.contains("did not answer within 2.0 seconds"),
            """
            the client reported "\(emitted.message)". `run()` waited some deadline other than \
            the one it was given, so nothing here would notice a shipping path that hardcoded \
            a gated verb's 5 s for the panic path.
            """)

        // The precondition, so this cannot pass against a client that sent nothing at all —
        // which produces the same `helperNeverAnswered` and the same text.
        //
        // A **bounded wait**, not an instantaneous read: the client gives up on its own
        // deadline, so at the moment it returns there is no guarantee the message has been
        // delivered *and* dispatched. Read straight after the timeout this raced, and failed
        // under a full-suite run. It waits on the authority's own flag rather than on the
        // arrival record, because the arrival is appended strictly upstream of the dispatch
        // that sets the flag — waiting on the earlier event leaves the later one raced, which
        // is the same window made smaller. What it must not become is a wait that *supplies*
        // the condition, and it does not: a client that never sent the message leaves this
        // false for the whole timeout and the wait records the issue itself.
        try await waitUntil("the panic path reached the helper") { await authority.hasBeenAsked }

        // Released so the parked helper task finishes rather than outliving the test.
        await gate.signal()
    }

    // MARK: - Nothing answered at all

    /// A helper that refuses every connection: non-zero, both possibilities named, and the
    /// way out printed.
    ///
    /// ADR 0005 measured that these two cannot be separated from the client's side — libxpc
    /// drops a requirement-refused peer and invalidates the connection with nothing
    /// delivered, exactly as a client that connected to nothing sees. `fanctl` has no
    /// `HelperInstallationState` to narrow it with, so naming one alone would be a guess
    /// printed as a diagnosis.
    ///
    /// **Mutation:** in `ResetCommand.reason(for:)`, return a fixed string instead of the
    /// error's `errorDescription`. Run: red on all three possibility expectations.
    @Test("A refusing helper exits non-zero and names both possibilities")
    func aRefusingHelperNamesBothPossibilities() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        harness.isAdmitting = false

        let emitted = try await Self.emitted(over: harness, waiting: Self.stallTolerant)

        #expect(emitted.exitCode != .success)
        #expect(emitted.message.contains("not installed"))
        #expect(emitted.message.contains("approved"))
        #expect(emitted.message.contains("refused"))
        #expect(emitted.message.contains("sudo launchctl bootout system/"))

        // Keeps the harness alive to here: its `deinit` invalidates the listener, and a
        // harness released above would leave this observing a dead listener rather than a
        // refusing one.
        #expect(harness.sessions.isEmpty, "a refused connection minted a session")
    }
}
