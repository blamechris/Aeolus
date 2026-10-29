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
/// the call is **cancelled**, which the client answers at once with a `CancellationError`
/// (`PendingReply`), so the test ends on its own assertions and not on its time limit.
///
/// **A call that cancellation cannot free** is one parked behind something the test holds: a
/// `hello` whose reply the test has not released, because the verb waits for the
/// shared handshake task and that task does not hear its waiter's cancellation. `release`
/// is for that: it runs once the call has been cancelled and before it is awaited, and releases
/// what the test holds.
///
/// The clock is not moved to release a parked call. Doing so would run out a deadline, and the
/// call would come back with `helperNeverAnswered`, the very answer a caller of this is asking
/// whether it got without. A test whose claim *is* the deadline moves the clock itself, from the
/// test body, while the call runs through here in a task of its own.
///
/// - Parameters:
///   - what: the call, as the failure should name it.
///   - timeout: how long the call may take, as scheduled waiting time (`waitUntil`'s default).
///   - sourceLocation: the caller's line, which a failed wait is recorded against.
///   - release: what to do once a call that did not come back has been cancelled.
///   - call: the call itself.
/// - Returns: the call's result or its error, and `CancellationError` if it was cancelled.
/// - Throws: `CancellationError`, from the wait, when the test itself is cancelled.
func returnedOutcome<Value: Sendable>(
    of what: String,
    timeout: Duration = .seconds(5),
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

    try await waitUntil(
        "\(what) to come back, with its deadline on a clock nothing moves",
        timeout: timeout,
        { await returned.isSet },
        sourceLocation: sourceLocation)
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
/// A harness's deadlines are on a clock nothing moves, which is the point; but a verb waits for
/// the shared handshake task with an `await` that cancellation does not end, and a `.timeLimit`
/// is only a cancellation. A client that lost its `hello` would then park its test, and with it
/// the run, for as long as the CI job allows. The wait here is `waitUntil`'s, counting only time
/// the waiter ran, so a stalled runner moves it no nearer; it is cancelled with the harness, and
/// a test that finishes never reaches it. 30 s sits under the 60 s of the smallest `.timeLimit`
/// with the room `StallTolerantWait.ceiling` allows a stall to add.
///
/// **It keeps going once it has fired.** A client that has been told its deadline ran out may be
/// asked again by the same test, and a deadline started after the backstop fired would otherwise
/// be parked on a clock nothing moves, for good. So every 50 ms until the harness goes, the
/// hands move an hour.
final class ClockBackstop: Sendable {

    private let task: Task<Void, Never>

    init(running clock: ManualClock, after budget: Duration = .seconds(30)) {
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
