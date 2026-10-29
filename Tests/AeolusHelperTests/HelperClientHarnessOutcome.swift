import Foundation
import Testing

/// What `call` came back with, for a test whose claim is that a client call **comes back**,
/// on a harness whose deadlines nothing moves
/// ([#421](https://github.com/blamechris/Aeolus/issues/421)).
///
/// `ClientListenerHarness.clock` is frozen, so a call the client fails to answer does not end at
/// 5 s with `helperNeverAnswered`; it stays parked, and the only thing left to end the test is its
/// `.timeLimit`, which records "Time limit was exceeded" and names nothing. Every test whose
/// claim is that a call comes back promptly (a refusal, a helper that died under it, a verb
/// behind one that timed out) used to be red on the error the deadline produced. This is what
/// keeps it red on the claim: when the call has not come back, the failure names it.
///
/// The call runs in a task of its own, and the wait for it is `waitUntil`'s, which counts only
/// time the waiter ran, so a runner stall is added to the wait and never spent from it. When the
/// wait ends and the call has not returned, the failure is recorded against the caller's line and
/// the call is **cancelled**. A call parked in the client's wait on its own reply is answered at
/// once with a `CancellationError` (`PendingReply`), so the test ends on its own assertions and
/// not on its time limit.
///
/// **So is a call parked behind the shared handshake**, since
/// [#576](https://github.com/blamechris/Aeolus/issues/576): it waits for the handshake through a
/// `PendingReply` of its own, and leaves the handshake running when it goes. Before #576 it
/// waited on the handshake task's `value`, which does not hear its waiter's cancellation, and came
/// back only when the harness's backstop ran the `hello` deadline out, about 30 s in. `release`
/// runs once the call has been cancelled and before it is awaited, and lets go of whatever the
/// test was holding the call behind, such as a `hello`, so that is not left parked until the
/// harness goes. A `call` that awaits another task's `value` is the one kind cancelling it cannot
/// free, and when the wait runs out, `release` is how such a test ends it.
///
/// The clock is not moved to release a parked call. Doing so would run out a deadline, and the
/// call would come back with `helperNeverAnswered`, the very answer a caller of this is asking
/// whether it got without. A test whose claim *is* the deadline moves the clock itself, from the
/// test body, while the call runs through here in a task of its own.
///
/// - Parameters:
///   - what: the call, as the failure should name it.
///   - timeout: how long the call may take, as scheduled waiting time. 15 s, which is what the
///     deadlines used to give a failing call (5 s gated, 10 s panic, 15 s handshake; 15 s is the
///     longest); it costs time only in a failing run.
///   - sourceLocation: the caller's line, which a failed wait is recorded against.
///   - release: what to do once a call that did not come back has been cancelled.
///   - call: the call itself.
/// - Returns: the call's result or its error, and `CancellationError` if it was cancelled.
/// - Throws: `CancellationError`, from the wait, when the test itself is cancelled; the call is
///   cancelled first, so it does not outlive the test. That holds for every client call, which
///   hears its cancellation wherever it waits, the shared handshake included since #576; a `call`
///   that awaits another task's `value` does not hear it.
func returnedOutcome<Value: Sendable>(
    of what: String,
    timeout: Duration = .seconds(15),
    sourceLocation: SourceLocation = #_sourceLocation,
    afterCancelling release: () async -> Void = {},
    _ call: @escaping @Sendable () async throws -> Value
) async throws -> Result<Value, any Error> {
    let returned = CompletionFlag()
    let task = Task { () -> Result<Value, any Error> in
        let result: Result<Value, any Error>
        do {
            result = .success(try await call())
        } catch {
            result = .failure(error)
        }
        await returned.mark()
        return result
    }

    do {
        try await waitUntil(
            "\(what) to come back, with its deadline on a clock nothing moves",
            timeout: timeout,
            { await returned.isSet },
            sourceLocation: sourceLocation)
    } catch {
        // The test was cancelled (a `.timeLimit`, say). The call is its own task and would
        // otherwise run on until the backstop, with nobody left to read what it returns.
        task.cancel()
        throw error
    }
    if await !returned.isSet {
        task.cancel()
        await release()
    }
    return await task.value
}

/// Runs every deadline on a harness's clock out once the harness has lived for `budget` of
/// scheduled waiting time, so a client that never answers fails its test and cannot hang it
/// ([#421](https://github.com/blamechris/Aeolus/issues/421)).
///
/// A harness's deadlines are on a clock nothing moves, which is the point; but then a call whose
/// answer is lost stays parked, and in a test that awaits it directly the only other end is the
/// suite's `.timeLimit`, a minute in, naming nothing. Before
/// [#576](https://github.com/blamechris/Aeolus/issues/576) not even that: a verb waited for the
/// shared handshake task with an `await` cancellation did not reach, so a client that lost its
/// `hello` parked its test, and with it the run, for as long as the CI job allowed. The wait here
/// is `StallTolerantWait.poll`, which counts only time the waiter ran, so a stall is added to the
/// 30 s; it is cancelled with the harness, and a test that finishes never reaches it.
///
/// **The stall allowance has a cap.** `poll` ends at its 50 s wall ceiling whatever it has
/// compensated, so once a harness has lived through more than 20 s of stalls in total, the
/// backstop fires at 50 s of wall time, which is 50 s minus that total of scheduled time. 50 s
/// is also what keeps it under the 60 s of the smallest `.timeLimit`.
///
/// **It keeps going once it has fired.** A client that has been told its deadline ran out may be
/// asked again by the same test, and a deadline started after the backstop fired would otherwise
/// be parked on a clock nothing moves, for good. So every 50 ms until the harness goes, the
/// hands move an hour.
final class ClockBackstop: Sendable {

    private let task: Task<Void, Never>

    /// The scheduled waiting time a harness lives before its backstop runs every deadline out.
    ///
    /// One figure for every harness that has a backstop, so that
    /// `StallTolerantWaitTests.theOneMinuteSuitesBackstopFitsInsideTheirTimeLimit` can hold it
    /// against the limits those harnesses' suites carry and not a number restated beside it.
    static let defaultBudget: Duration = .seconds(30)

    init(running clock: ManualClock, after budget: Duration = ClockBackstop.defaultBudget) {
        task = Task {
            let outcome = try? await StallTolerantWait.poll(
                timeout: budget, interval: .milliseconds(50), clock: SystemWaitClock(),
                condition: { false })
            guard case .timedOut? = outcome else { return }
            while !Task.isCancelled {
                clock.advance(by: .seconds(3600))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    deinit { task.cancel() }
}
