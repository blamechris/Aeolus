import ArgumentParser
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl reset --all`, end to end: the real command, the real `HelperClient`, a real
/// `NSXPCListener` and the real `HelperConnectionSession` behind it.
///
/// **Why this suite lives here rather than in `fanctlTests`.** The only peer the real client
/// can be driven against is the real helper session, and that is behind
/// `@testable import AeolusHelper`. Driving the command from `fanctlTests` instead would mean
/// a second listener harness, a second unenforced pinning policy and a stub exported object —
/// three copies of things that already exist in this target, none of which is the helper. The
/// same argument put `AeolusXPCClient` here in #237.
///
/// What this suite therefore covers that `ResetCommandTests` cannot: that the errors the
/// command renders are the errors the client actually produces against a live peer, and that
/// an accepted request really did reach a helper.
///
/// What none of it proves, and what the acceptance criterion still waits on: that a **signed**
/// `fanctl` is admitted by an **installed** helper. A `swift build` binary carries no Team ID
/// and is refused at both ends by design (ADR 0005), so hardware acceptance of this command is
/// blocked on [#82](https://github.com/blamechris/Aeolus/issues/82).
@Suite("fanctl reset --all against a real helper session")
struct FanctlResetTests {

    /// One run's observable result: what swift-argument-parser would print, and what it
    /// would exit with.
    private struct Emitted {
        let message: String
        let exitCode: ExitCode
    }

    /// Deadlines long enough that a loaded runner cannot fake a failure.
    ///
    /// **Three of these four tests assert text and an exit code and nothing about timing**,
    /// so a short deadline buys them nothing and costs a red CI run: `ClientListenerHarness`
    /// defaults to 750 ms, which this machine never approaches and a GitHub runner exceeded
    /// for a message the helper had already answered — reporting a working helper as one that
    /// never answered, which is the exact misreport this suite exists to forbid. A generous
    /// deadline costs nothing when the reply arrives, and every reply here does.
    private static let unhurried = HelperClientDeadlines(
        gatedVerb: .seconds(10), panicVerb: .seconds(10), handshakeVerb: .seconds(10))

    /// The one deadline this suite asserts on, in the one test whose peer never replies.
    ///
    /// Not the 750 ms default, for the reason above, and not ten seconds either: this is the
    /// wall clock the suite actually spends, so it is the shortest figure that still leaves a
    /// slow runner no way to make a delivered message look undelivered.
    private static let observableDeadline = Duration.seconds(2)

    /// Parsed rather than constructed, so `--all` reaching the flag and `validate()`
    /// accepting the invocation are part of every case below.
    private static func resetAll() throws -> Fanctl.Reset {
        try #require(Fanctl.parseAsRoot(["reset", "--all"]) as? Fanctl.Reset)
    }

    /// Runs the real command against one client and captures how it left.
    private static func emitted(over client: HelperClient) async throws -> Emitted {
        do {
            try await resetAll().run(restoring: { try await client.restoreAllToAutomatic() })
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
    /// having sent nothing at all.
    ///
    /// **Mutation:** in `ResetCommand.attempt(_:)`, return `accepted` without calling
    /// `restore`. Run: red on the authority's call count, and on the arrivals.
    @Test("An accepted request exits 0, reached the helper, and claims no restore")
    func anAcceptedRequestExitsZeroAndClaimsNoRestore() async throws {
        let authority = RecordingFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client(
            description: ResetCommand.clientDescription, deadlines: Self.unhurried)

        let emitted = try await Self.emitted(over: client)

        #expect(emitted.exitCode == .success)
        #expect(emitted.message.contains("accepted the reset request"))
        #expect(
            emitted.message.contains(
                "has not reported that any fan is back under automatic control"))

        #expect(await authority.calls.count == 1, "the request did not reach the helper")
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
        let client = harness.client(
            description: ResetCommand.clientDescription, deadlines: Self.unhurried)

        let emitted = try await Self.emitted(over: client)
        #expect(emitted.exitCode == .success)

        let session = try #require(harness.sessions.first)
        #expect(await session.messageCount == 1, "only the panic path was sent")
        #expect(await session.handshakeState == nil, "the command sent a hello")
    }

    // MARK: - The helper never answered

    /// A helper that accepts the request and never answers: non-zero, and the text says the
    /// effect is unknown rather than guessing either way.
    ///
    /// This is `docs/SAFETY.md` § 4's wedged `io_connect_t`, constructed rather than waited
    /// for: the authority parks inside the panic path, so the helper has the message and the
    /// reply never comes. `NSXPCConnection` has no per-message timeout, so what turns that
    /// into an answer at all is the client's own `panicVerb` deadline.
    ///
    /// **Mutation:** in `HelperClient.exchange(on:within:_:)`, replace
    /// `pending.answer(within: deadline)` with `pending.answer(within: .seconds(600))`. Run:
    /// red on the suite's time limit rather than here, which is the weaker kill — so the
    /// expectations below are on the text, which no timeout can produce.
    @Test("A helper that never answers exits non-zero and says the effect is unknown")
    func aHelperThatNeverAnswersIsReportedAsUnknown() async throws {
        let gate = AsyncSignal()
        let authority = GatedRestoreAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client(
            description: ResetCommand.clientDescription,
            deadlines: HelperClientDeadlines(
                gatedVerb: Self.observableDeadline,
                panicVerb: Self.observableDeadline,
                handshakeVerb: .seconds(10)))

        let emitted = try await Self.emitted(over: client)

        #expect(emitted.exitCode != .success)
        #expect(emitted.message.contains("did not confirm the reset request"))
        #expect(
            emitted.message.contains("Nothing can be said about whether it took effect"),
            """
            a wedged helper was reported as "\(emitted.message)". Neither "restored" nor \
            "failed" is observable here: the helper has the message and may yet act on it.
            """)
        #expect(emitted.message.contains("sudo launchctl bootout system/"))

        // The precondition, so this cannot pass against a client that sent nothing at all —
        // which produces the same `helperNeverAnswered` and the same text.
        //
        // A **bounded wait**, not an instantaneous read, and the difference is not cosmetic:
        // the client gives up on its own deadline, so at the moment it returns there is no
        // guarantee libxpc has finished delivering. Read straight after the timeout this
        // raced, and failed under a full-suite run. What it must not become is a wait that
        // *supplies* the condition — it does not: a client that never sent the message
        // leaves `arrivals` empty for the whole timeout and this records an issue.
        //
        // `arrivals` rather than the authority's own flag, because it is recorded
        // synchronously by `ArrivalRecordingService` on delivery, with no actor hop between
        // the wire and the observation.
        try await waitUntil("the panic path reached the helper") {
            harness.arrivals.contains("restoreAllToAutomatic")
        }
        #expect(await authority.hasBeenAsked, "the helper received it but never dispatched it")

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
        let client = harness.client(
            description: ResetCommand.clientDescription, deadlines: Self.unhurried)

        let emitted = try await Self.emitted(over: client)

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
