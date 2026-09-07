import Foundation

/// Resumes a continuation exactly once, whichever of the reply block, the connection's
/// error handler, and the deadline gets there first.
///
/// ## Why once-only is a correctness property and not a nicety
///
/// Both blocks can run. `AeolusXPCProtocol` is explicit that a reply block may never be
/// invoked at all when the connection fails — but the reverse also happens: a reply that
/// was already on its way when the connection died delivers, and the error handler fires
/// too. `withCheckedContinuation` **traps** on a second resume, so a client without this
/// latch does not misreport that race, it crashes on it. In `Aeolus.app` that is a crash
/// in the user's face at the moment the helper died; in `fanctl` it is a non-zero exit with
/// no diagnosis. A test cannot catch a trap either — the process is gone — which is why
/// this is a type rather than a convention.
///
/// ## Why it lives here rather than in the suite
///
/// It was the test harness's, in `AnonymousListenerHarness`. Two implementations of a
/// once-only latch — one exercised by the suite, one shipping — is one more than this
/// project can defend, and the shipping one would have been the untested copy. The harness
/// now uses this via `@testable import AeolusXPCClient`, so the primitive the suite proves
/// is the primitive that ships.
///
/// `@unchecked Sendable` over an `NSLock`: the state is three fields behind one lock with
/// no path that touches any of them outside it, and the alternative — an actor — cannot be
/// called from the synchronous, non-isolated context an XPC reply block runs in, which is
/// the entire reason this type exists. `CLAUDE.md` rule 10 and the repository's SwiftLint
/// rule scope that prohibition to the helper and `SMCCore`, where a data race is a
/// hardware-safety issue; here the claim is small enough to check by reading it.
final class PendingReply<Answer>: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Unchecked<Answer>, Never>?
    private var buffered: Unchecked<Answer>?
    private var isFinished = false
    private let fallback: Unchecked<Answer>

    init(ifNothingArrives fallback: Answer) {
        self.fallback = Unchecked(value: fallback)
    }

    /// Runs `send`, then waits for the first answer or for the deadline.
    func awaitingAnswer(
        within deadline: Duration = .seconds(10),
        _ send: (@escaping @Sendable (Answer) -> Void) -> Void
    ) async -> Answer {
        send { [self] answer in deliver(answer) }
        return await answer(within: deadline)
    }

    /// The first half of `awaitingAnswer`, for a caller that has to get a message sent —
    /// or a second one — before it starts waiting. Buffered if it beats the wait, which a
    /// synchronous refusal can.
    func deliver(_ answer: Answer) {
        resolve(Unchecked(value: answer))
    }

    /// The second half: waits for the first answer or for the deadline.
    ///
    /// The deadline is a detached task rather than a `withTaskGroup` race, because the
    /// thing being raced is not a task at all — it is two C callbacks libxpc may or may not
    /// invoke.
    func answer(within deadline: Duration = .seconds(10)) async -> Answer {
        let deadlineTask = Task.detached { [self] in
            try? await Task.sleep(for: deadline)
            giveUp()
        }
        defer { deadlineTask.cancel() }

        // Cancellation gives up too, and mutation testing is what put it here. Without it,
        // *removing* the deadline does not make a test fail — it makes the suite **hang**:
        // nothing else ever resumes the continuation, and a `.timeLimit` cancels the test's
        // task without ever reaching it. That is the one outcome a safety suite must not
        // have, and it is not only a test property: a caller cancelled mid-message would
        // otherwise stay parked on a deadline nobody is waiting for any more.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                attach(continuation)
            }.value
        } onCancel: {
            giveUp()
        }
    }

    /// Hands the fallback to whoever is waiting, and does nothing when nobody is.
    ///
    /// Deliberately **not** `resolve(fallback)`, and the difference is what the second
    /// latch mutation exposed. `resolve` declines once an answer has been chosen — right
    /// for a *second answer*, wrong for giving up, because a latch that chose an answer and
    /// then failed to hand it over leaves a caller parked with nothing left that could wake
    /// it. Here the question is "is somebody waiting", not "has an answer been chosen".
    ///
    /// While the rest of this type is correct that distinction cannot be observed — an
    /// answer that beat the wait is buffered, and `attach` consumes it without ever storing
    /// a continuation, so "finished, and someone is still waiting" is unreachable. It is
    /// what stops a defect in `resolve` from becoming a **hang** rather than a failure, and
    /// that is worth having: the mutation that removed the buffering ran for ten minutes
    /// without producing a result before this existed.
    ///
    /// It cannot double-resume: this and `resolve` both take the continuation out from
    /// under the same lock, so exactly one of them ever holds it.
    private func giveUp() {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        isFinished = true
        lock.unlock()
        continuation.resume(returning: fallback)
    }

    private func attach(_ continuation: CheckedContinuation<Unchecked<Answer>, Never>) {
        lock.lock()
        if let buffered {
            self.buffered = nil
            lock.unlock()
            continuation.resume(returning: buffered)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Buffers the answer when it beats `attach`, which a synchronous refusal can.
    private func resolve(_ answer: Unchecked<Answer>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        guard let continuation else {
            buffered = answer
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: answer)
    }
}

/// Wraps a value the compiler cannot prove `Sendable` so it can cross a continuation.
///
/// What actually crosses is a `Result` whose failure is an existential `Error` — in
/// practice an `NSError` libxpc has just created and handed to exactly one callback — or
/// `Data`. Neither is shared with anything else, which is what the annotation asserts and
/// the scope of this file is small enough to check.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}
