import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// The two things the client harness's frozen clock asks of its tests: that a client built
/// without a clock counts its deadline on the harness's, and that a call which does not come
/// back is reported as that and not as a time limit
/// ([#421](https://github.com/blamechris/Aeolus/issues/421)).
@Suite("The client harness's clock and the bounded call", .timeLimit(.minutes(1)))
struct HelperClientHarnessOutcomeTests {

    /// **A client the harness builds counts its deadline on the harness's clock**, and the
    /// deadline it counts is the shipping `gatedVerb`.
    ///
    /// This is the property every test that inherits the default relies on, and nothing else in
    /// the target observes it: a client on `ContinuousClock` behaves identically until a runner
    /// stalls. The snapshot is held at the helper, so a deadline is running; one sleep parked on
    /// `harness.clock` is that deadline, and moving the hands by the shipping bound is what ends
    /// it, with the bound in the error.
    ///
    /// **Mutation:** in `ClientListenerHarness.client(…)`, pass `clock ?? ContinuousClock()` in
    /// place of `clock ?? self.clock`. Run: red on the wait for the deadline to park on the
    /// harness's clock, which it never does.
    @Test("A client built without a clock counts its deadline on the harness's")
    func aDefaultClientCountsItsDeadlineOnTheHarnessClock() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client()

        let snapshot = Task {
            try await returnedOutcome(of: "the snapshot the helper never answers") {
                try await client.snapshot()
            }
        }
        try await waitUntil(
            "the snapshot's deadline has parked on the harness's clock",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            await authority.hasBeenAsked && harness.clock.sleepers == 1
        }
        harness.clock.advance(by: HelperClientDeadlines.gatedVerb)

        await #expect(
            throws: HelperClientError.helperNeverAnswered(after: HelperClientDeadlines.gatedVerb)
        ) {
            _ = try await snapshot.value.get()
        }
        await gate.signal()
    }

    /// A call that comes back is handed back as it is, and nothing is moved to get it.
    ///
    /// **Mutation:** in `returnedOutcome`, return `.failure(CancellationError())` unconditionally.
    /// Run: red on the result.
    @Test("A call that comes back is returned as it came back")
    func aCallThatComesBackIsReturnedAsItIs() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client()
        let before = harness.clock.now

        let outcome = try await returnedOutcome(of: "a snapshot") { try await client.snapshot() }

        #expect((try? outcome.get()) != nil, "a snapshot came back as \(outcome)")
        #expect(harness.clock.now == before, "the clock was moved to get an answer")
        #expect(harness.sessions.count == 1)
    }

    /// A call that does not come back **fails the wait that names it, is cancelled, and is
    /// handed back as cancelled**: the three things that let a test end on its own assertions
    /// rather than on its time limit.
    ///
    /// The snapshot is held at the helper and its deadline is on a clock nothing moves, which is
    /// exactly a client that has failed to give a call its answer. `withKnownIssue` is the
    /// assertion that the wait does record a failure, and it fails if none is recorded.
    ///
    /// **The connection is handshaken first**, by a round trip that completes, so the call that
    /// does not come back is the snapshot parked on its own reply and not a call still behind the
    /// `hello`. Since #576 a call cancelled behind the `hello` leaves at once while the handshake
    /// runs on. On a runner slow enough to spend the 200 ms wait before the `hello` is answered,
    /// the health below is then read while the handshake is still in flight: CI run 40897877885
    /// failed it, and with the `hello` reply delayed 500 ms it read `.idle` locally, then
    /// `.handshaken` once the `hello` was answered.
    ///
    /// **Mutation:** in `returnedOutcome`, delete the `task.cancel()`. Run: red on `error is
    /// CancellationError`, thirty seconds on, when the harness's backstop runs the parked call's
    /// deadline out and it comes back `helperNeverAnswered`.
    /// **Mutation:** in `returnedOutcome`, delete the `waitUntil`. Run: red on `withKnownIssue`,
    /// which records no issue.
    @Test("A call that does not come back fails the wait and is cancelled")
    func aCallThatDoesNotComeBackIsNamedAndCancelled() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client()
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
        ) {
            _ = try await client.acquireLease(
                LeaseRequest(holderDescription: "test client", fanIndices: [0]))
        }
        #expect(await client.health == .handshaken)

        var outcome: Result<SystemSnapshot, any Error>?
        await withKnownIssue("the snapshot is held at the helper, which is the case under test") {
            outcome = try await returnedOutcome(
                of: "a snapshot the helper holds", timeout: .milliseconds(200)
            ) {
                try await client.snapshot()
            }
        }
        await gate.signal()

        guard case .failure(let error)? = outcome else {
            Issue.record("a parked call came back as \(String(describing: outcome))")
            return
        }
        #expect(
            error is CancellationError,
            "a parked call was told \(error), not that it was cancelled")
        #expect(
            await client.health == .handshaken,
            "releasing the call moved the connection's health, so a deadline ran out")
    }

    /// **A deadline nobody moves is still run out, in the end**: a client that never answers fails
    /// its test instead of hanging it.
    ///
    /// A sleep is parked on a clock nothing else moves, for an hour; the backstop's budget is
    /// 200 ms of scheduled time. Without it that sleep never ends, and a client call whose answer
    /// is lost ends only at its suite's `.timeLimit` (before #576, a verb behind the shared
    /// handshake did not end even then).
    ///
    /// A second sleep, started after the backstop has fired, ends too: the client may be asked
    /// again.
    ///
    /// **Mutation:** in `ClockBackstop.init`, delete the `clock.advance(by:)`. Run: red on the wait
    /// for the parked sleep to end.
    /// **Mutation:** in `ClockBackstop.init`, replace the `while` with an `if`. Run: red on the
    /// wait for the second sleep to end.
    @Test("The backstop runs a clock nobody moves out, so a hung client fails")
    func theBackstopRunsAnUnmovedClockOut() async throws {
        let clock = ManualClock()
        let backstop = ClockBackstop(running: clock, after: .milliseconds(200))
        let ended = CompletionFlag()
        let parked = Task {
            try? await clock.sleep(for: .seconds(3600))
            await ended.mark()
        }

        try await waitUntil("the parked sleep to end once the backstop's budget is spent") {
            await ended.isSet
        }
        // Cancelled whether or not it ended: a sleep the backstop did not end would otherwise
        // be awaited for good, and this is a failure to report, not to hang on.
        parked.cancel()
        await parked.value

        let endedAgain = CompletionFlag()
        let again = Task {
            try? await clock.sleep(for: .seconds(3600))
            await endedAgain.mark()
        }
        try await waitUntil("a sleep started after the backstop fired to end as well") {
            await endedAgain.isSet
        }
        again.cancel()
        await again.value
        withExtendedLifetime(backstop) {}
    }

    /// A backstop that is dropped does not fire: a test that finished must not move a clock a
    /// later reader could still hold.
    ///
    /// The absence is observed for three times the budget, a floor and not a bound: the code
    /// under test cannot fail by being slow, only a mutant can survive a short look.
    ///
    /// **Mutation:** in `ClockBackstop`, delete the `deinit`. Run: red, the clock having moved.
    @Test("A dropped backstop leaves its clock where it was")
    func aDroppedBackstopDoesNotFire() async throws {
        let clock = ManualClock()
        let before = clock.now
        var backstop: ClockBackstop? = ClockBackstop(running: clock, after: .milliseconds(200))
        withExtendedLifetime(backstop) {}
        backstop = nil

        try await Task.sleep(for: .milliseconds(600))

        #expect(clock.now == before, "a backstop that was dropped still moved the clock")
    }

    /// **A call does not outlive the test that was waiting for it.** When the wait ends because
    /// the test was cancelled (a `.timeLimit`, say), the call's own task is cancelled before the
    /// error goes on, so it is not left running until the harness's backstop.
    ///
    /// The call sleeps for an hour, so only cancellation ends it, and notes that it heard.
    ///
    /// **Mutation:** in `returnedOutcome`, delete the `task.cancel()` from the `catch`. Run: red on
    /// the wait for the call to hear that its test was cancelled.
    @Test("A call is cancelled with the test that was waiting for it")
    func aCancelledTestCancelsItsCall() async throws {
        let heard = CompletionFlag()
        let waiting = Task {
            try await returnedOutcome(of: "a sleep only cancellation ends") {
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    await heard.mark()
                    throw error
                }
            }
        }
        waiting.cancel()

        try await waitUntil("the call to hear that the test waiting for it was cancelled") {
            await heard.isSet
        }
        _ = try? await waiting.value
    }
}
