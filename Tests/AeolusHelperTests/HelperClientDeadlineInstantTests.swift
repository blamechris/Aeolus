import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// Each kind of deadline the client holds a call to runs out at its length: not a nanosecond
/// before, and at the nanosecond ([#577](https://github.com/blamechris/Aeolus/issues/577)).
///
/// Every other deadline test in this target asserts the figure the client reports, which
/// `.helperNeverAnswered(after:)` repeats back from the configuration, and not the instant it
/// fired. With the deadline counted on a `ManualClock` only the test moves, the instant is
/// observable. `InFlightMessages.startDeadline` handed `clock.timer(after: deadline / 2)` in
/// place of `deadline` made every deadline fire at half its length. Of the other client suites
/// (`swift test --filter HelperClient`, 92 tests) only the five that hold an `apply` went red, and
/// no test of a gated verb, the handshake or the panic path on its own.
///
/// **The shape of each test**, from the shipping deadlines, which are the harness's own:
/// 1. Hold the call at the helper until its deadline has parked on the clock, one sleeper.
/// 2. Move the hands to one nanosecond short of the deadline. The sleeper is still parked, and the
///    call has not come back. `ManualClock.advance(by:)` ends every due sleep before it returns,
///    so the count is read on the move itself, not after some wait that a stall could cut short.
/// 3. Move one nanosecond more. The call comes back `helperNeverAnswered(after:)`.
///
/// A deadline that fires early is red on step 2, and one that fires late is red on step 3: the
/// call stays parked, and `returnedOutcome` names it instead of leaving it to the time limit.
@Suite("The XPC client's deadlines run out at their length", .timeLimit(.minutes(1)))
struct HelperClientDeadlineInstantTests {

    private static let deadlines = ClientListenerHarness.defaultDeadlines

    // MARK: - The three kinds

    /// **A gated verb's deadline, the snapshot's, runs out at `gatedVerb`.**
    ///
    /// **Mutation:** in `InFlightMessages.startDeadline(of:after:)`, pass `deadline / 2` to
    /// `clock.timer(after:)`. Run: red on the sleeper count, 0 where one is parked, one nanosecond
    /// short of the deadline.
    /// **Mutation:** the same line with `deadline * 2`. Run: red on `returnedOutcome`'s wait for
    /// the call to come back, once the clock has moved the whole deadline.
    @Test("A gated verb's deadline runs out at its length")
    func aGatedVerbsDeadlineRunsOutAtItsLength() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client(deadlines: Self.deadlines)

        let snapshot = ParkedCall(of: "the snapshot the helper never answers") {
            _ = try await client.snapshot()
        }
        try await waitUntil("the snapshot is held at the helper and its deadline is running") {
            await authority.hasBeenAsked && harness.clock.sleepers == 1
        }

        await snapshot.expectItRunsOutAt(Self.deadlines.gatedVerb, on: harness.clock)
        await gate.signal()
    }

    /// **The handshake's deadline, the `hello`'s, runs out at `handshakeVerb`.**
    ///
    /// The reply is held at the helper, so the `hello` is in flight and unanswered. The 15 s is the
    /// longest of the three, and the one a `gatedVerb` substituted for it would shorten by two
    /// thirds, which `HelperClientTests.theHandshakeIsSentWithinItsOwnDeadline` pins by wiring and
    /// this pins by instant.
    ///
    /// **Mutation:** in `InFlightMessages.startDeadline(of:after:)`, pass `deadline / 2` to
    /// `clock.timer(after:)`. Run: red on the sleeper count.
    @Test("The handshake's deadline runs out at its length")
    func theHandshakesDeadlineRunsOutAtItsLength() async throws {
        let releaseHandshake = AsyncSignal()
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(), holdingHandshakeReplies: releaseHandshake)
        let client = harness.client(deadlines: Self.deadlines)

        let snapshot = ParkedCall(
            of: "the snapshot whose hello is held",
            afterCancelling: { await releaseHandshake.signal() },
            { _ = try await client.snapshot() })
        try await waitUntil("the hello is held at the helper and its deadline is running") {
            harness.arrivals == ["hello"] && harness.clock.sleepers == 1
        }

        await snapshot.expectItRunsOutAt(Self.deadlines.handshakeVerb, on: harness.clock)
        await releaseHandshake.signal()
    }

    /// **The panic path's deadline, `restoreAllToAutomatic`'s, runs out at `panicVerb`.**
    ///
    /// The helper accepted the request and never answers it: `docs/SAFETY.md` § 4's wedged
    /// connection, which is the state a user reaches the panic path in. It sends no `hello`, so the
    /// deadline parked on the clock is the panic path's alone.
    ///
    /// **Mutation:** in `InFlightMessages.startDeadline(of:after:)`, pass `deadline / 2` to
    /// `clock.timer(after:)`. Run: red on the sleeper count.
    @Test("The panic path's deadline runs out at its length")
    func thePanicPathsDeadlineRunsOutAtItsLength() async throws {
        let gate = AsyncSignal()
        let authority = GatedRestoreAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client(deadlines: Self.deadlines)

        let restore = ParkedCall(of: "the panic path the helper never answers") {
            try await client.restoreAllToAutomatic()
        }
        try await waitUntil("the request is held at the helper and its deadline is running") {
            await authority.hasBeenAsked && harness.clock.sleepers == 1
        }

        await restore.expectItRunsOutAt(Self.deadlines.panicVerb, on: harness.clock)
        await gate.signal()
    }

    // MARK: - The deadlines are distinct

    /// The three figures the tests above move the hands by differ, so a deadline of the wrong kind
    /// cannot satisfy another's test.
    ///
    /// Each test moves the clock by its own kind's figure less a nanosecond and then by one
    /// nanosecond. Two kinds with the same figure would let a client that swapped them pass both,
    /// and these are the shipping figures (5 s, 10 s, 15 s), so the check is of the premise the
    /// three share.
    ///
    /// **Mutation:** in `HelperClientDeadlines`, set `panicVerb` to `gatedVerb`'s figure. Run: red.
    @Test("The three deadlines the instant tests move the hands by are distinct")
    func theThreeDeadlinesAreDistinct() {
        let figures = [
            Self.deadlines.gatedVerb, Self.deadlines.panicVerb, Self.deadlines.handshakeVerb,
        ]
        #expect(
            Set(figures).count == 3,
            "\(figures) are not three figures, so a swapped kind would pass its neighbour's test")
    }
}

/// A client call held at the helper, with its deadline running on a clock only the test moves.
private struct ParkedCall {

    private let outcome: Task<Result<Void, any Error>, any Error>
    private let returned = CompletionFlag()

    /// Starts `call` in a task of its own, through `returnedOutcome`, so that a call that never
    /// comes back fails a wait that names it and is cancelled, and does not leave the test to its
    /// time limit.
    ///
    /// - Parameters:
    ///   - what: the call, as a failed wait should name it.
    ///   - sourceLocation: the caller's line, which a failed wait is recorded against.
    ///   - release: what to do once a call that did not come back has been cancelled.
    ///   - call: the call itself.
    init(
        of what: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        afterCancelling release: @escaping @Sendable () async -> Void = {},
        _ call: @escaping @Sendable () async throws -> Void
    ) {
        let returned = returned
        outcome = Task {
            try await returnedOutcome(
                of: what, sourceLocation: sourceLocation, afterCancelling: release
            ) {
                let result: Result<Void, any Error>
                do {
                    try await call()
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                // Marked where the call itself returns, not where `returnedOutcome` notices it,
                // which is up to a poll later.
                await returned.mark()
                return try result.get()
            }
        }
    }

    /// Moves the hands to one nanosecond short of `deadline` and requires the deadline to be
    /// pending, then moves them one nanosecond more and requires it to have run out.
    ///
    /// - Parameters:
    ///   - deadline: the length the client was given for this call, which is also what it reports.
    ///   - clock: the clock the deadline is parked on, with that one sleeper on it.
    ///   - sourceLocation: the caller's line, which a failed expectation is recorded against.
    func expectItRunsOutAt(
        _ deadline: Duration, on clock: ManualClock,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        clock.advance(by: deadline - .nanoseconds(1))
        // `advance(by:)` ends every due sleep before it returns, so this is the count at that
        // instant and not a count after a wait. A deadline that fired early has ended its sleep.
        #expect(
            clock.sleepers == 1,
            "the deadline ran out before \(deadline), at one nanosecond short of it",
            sourceLocation: sourceLocation)
        #expect(
            await !returned.isSet,
            "the call came back one nanosecond short of its deadline of \(deadline)",
            sourceLocation: sourceLocation)

        clock.advance(by: .nanoseconds(1))
        await #expect(
            throws: HelperClientError.helperNeverAnswered(after: deadline),
            sourceLocation: sourceLocation
        ) {
            _ = try await outcome.value.get()
        }
    }
}
