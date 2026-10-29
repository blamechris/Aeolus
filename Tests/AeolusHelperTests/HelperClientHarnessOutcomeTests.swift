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
        try await waitUntil("the snapshot's deadline has parked on the harness's clock") {
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
    /// **Mutation:** in `returnedOutcome`, delete the `task.cancel()`. Run: red on the time
    /// limit, not on this expectation, because the awaited task is still parked: a limit is
    /// what this exists to keep from being the only thing that reports a hang.
    /// **Mutation:** in `returnedOutcome`, delete the `waitUntil`. Run: red on `withKnownIssue`,
    /// which records no issue.
    @Test("A call that does not come back fails the wait and is cancelled")
    func aCallThatDoesNotComeBackIsNamedAndCancelled() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client()

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
}
