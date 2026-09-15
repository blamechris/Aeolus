import Foundation
import Testing

@testable import AeolusXPCClient

/// The once-only latch every XPC reply in this project goes through, on its own.
///
/// It is one type now rather than two: the client's, used by the client and by
/// `AnonymousListenerHarness`. It used to be the harness's, which meant the copy the suite
/// exercised and the copy that shipped were different code.
///
/// **Why the latch is a correctness property.** The reply block and the connection's error
/// handler can both run — a reply already on its way when the connection dies delivers, and
/// the error handler fires too — and `withCheckedContinuation` *traps* on a second resume.
/// A client without this does not misreport that race, it crashes on it, and a test cannot
/// catch a trap because the process is gone.
///
/// So the assertions below are written to fail **before** a trap can happen: both answers
/// are delivered before anything waits, which is the buffered path, so a latch with its
/// once-only guard removed returns the *second* answer rather than aborting the runner.
@Suite("The once-only reply latch")
struct PendingReplyTests {

    /// **The mutation kill.** Two answers, delivered before anyone is waiting: the first
    /// one is the answer, and the second is dropped.
    ///
    /// This is the reply-block-and-error-handler race in the shape a test can assert on.
    ///
    /// **Mutation:** delete `guard !isFinished else { … }` from `PendingReply.resolve(_:)`.
    /// Run: red — the second answer overwrites the first in the buffer, and this returns
    /// `"the error handler"`.
    @Test("The first answer wins and the second is dropped")
    func theFirstAnswerWins() async {
        let latch = PendingReply<String>(ifNothingArrives: "nothing arrived")

        latch.deliver("the reply block")
        latch.deliver("the error handler")

        #expect(await latch.answer(within: .seconds(1)) == "the reply block")
    }

    /// Nothing arrives, and the deadline is what turns that into a value.
    ///
    /// `NSXPCConnection` has no per-message timeout: a peer that accepts a message and never
    /// answers holds its caller forever, and on the wedged `io_connect_t` of
    /// `docs/SAFETY.md` § 4 that is the expected case rather than an exotic one.
    ///
    /// **Mutation:** delete the `deadlineTask` from `PendingReply.answer(within:)`. Run: red
    /// — on this suite's time limit rather than on this expectation, because what the
    /// mutation removes is the only thing that would ever have answered.
    @Test("The deadline answers when nothing else does", .timeLimit(.minutes(1)))
    func theDeadlineAnswersWhenNothingElseDoes() async {
        let latch = PendingReply<String>(ifNothingArrives: "nothing arrived")

        #expect(await latch.answer(within: .milliseconds(50)) == "nothing arrived")
    }

    /// An answer that arrives while the caller is still sending is not lost.
    ///
    /// A refusal can be synchronous — the whole exchange can be over before the caller
    /// reaches its `await` — so the latch buffers rather than assuming somebody is already
    /// waiting.
    ///
    /// **Mutation:** in `PendingReply.resolve(_:)`, drop the answer instead of buffering it
    /// when `continuation` is `nil`. Run: red — the deadline's fallback comes back instead.
    @Test("An answer that beats the wait is buffered, not lost")
    func anAnswerThatBeatsTheWaitIsBuffered() async {
        let latch = PendingReply<String>(ifNothingArrives: "nothing arrived")

        latch.deliver("the reply block")
        try? await Task.sleep(for: .milliseconds(20))

        #expect(await latch.answer(within: .seconds(1)) == "the reply block")
    }

    /// A deadline that fires after an answer has already arrived changes nothing.
    ///
    /// The same guard as `theFirstAnswerWins`, reached by the other door: the fallback is
    /// just one more thing racing to resolve, and a latch that let it win would report "no
    /// answer" about a message that was answered.
    @Test("A late deadline does not overwrite an answer that arrived")
    func aLateDeadlineDoesNotOverwriteAnAnswer() async {
        let latch = PendingReply<String>(ifNothingArrives: "nothing arrived")

        latch.deliver("the reply block")
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await latch.answer(within: .nanoseconds(1)) == "the reply block")
    }

    /// A caller that was **already cancelled** before it started waiting does not park for
    /// the deadline.
    ///
    /// `withTaskCancellationHandler` runs `onCancel` *before* the operation when the task is
    /// already cancelled, so "give up, then attach" is the ordinary order on a cancelled
    /// caller rather than an exotic interleaving. A `giveUp` that recorded nothing when
    /// nobody was waiting left `attach` storing a continuation that cancellation was never
    /// going to revisit, and the caller waited out the whole deadline — five seconds on a
    /// gated verb, ten on the panic path, which is the opposite of what the handler is
    /// installed for.
    ///
    /// **The order is forced rather than raced.** `AsyncSignal.wait()` is the only thing
    /// that can release the task, and this test does not release it until after `cancel()`,
    /// so `answer(within:)` is guaranteed to be entered on an already-cancelled task. A bare
    /// `Task { … }; task.cancel()` would be a coin flip between the two orders and would let
    /// the defect through whenever the coin came up "attached first".
    ///
    /// **The deadline is ten seconds, not sixty.** The assertion has to be the elapsed time
    /// — a latch that waits out its deadline still returns the fallback eventually, so the
    /// *value* proves nothing — and sixty would trip this suite's time limit before the
    /// expectation could record, which is the weaker kill this repository keeps rejecting.
    ///
    /// **Mutation:** in `PendingReply.giveUp()`, restore the early `return` that recorded
    /// nothing when `continuation` was `nil`. Run: red on the elapsed-time expectation after
    /// ten seconds, naming the wait.
    @Test("A caller cancelled before it waits gives up at once", .timeLimit(.minutes(1)))
    func aCallerCancelledBeforeItWaitsGivesUpAtOnce() async {
        let latch = PendingReply<String>(ifNothingArrives: "nothing arrived")
        let release = AsyncSignal()

        let waiting = Task { () -> String in
            try? await release.wait()
            return await latch.answer(within: .seconds(10))
        }
        waiting.cancel()
        await release.signal()

        let started = ContinuousClock.now
        let answer = await waiting.value
        let waited = started.duration(to: .now)

        #expect(answer == "nothing arrived")
        #expect(
            waited < .seconds(1),
            """
            the cancelled caller waited \(waited). Cancellation arrived before anything was \
            attached, so the give-up had nobody to hand the fallback to — and a latch that \
            drops it there leaves the caller parked on a continuation nothing will revisit \
            until the deadline it was cancelled out of.
            """)
    }

    /// Many answers arriving at once still resolve the continuation exactly once.
    ///
    /// The once-only guard is what stands between this client and a **trap**:
    /// `withCheckedContinuation` aborts the process on a second resume, and a test cannot
    /// catch that because the process is gone. `theFirstAnswerWins` asserts the rule on the
    /// buffered path, where both answers are delivered before anyone waits and nothing is
    /// concurrent; this one puts a real waiter and thirty-two real threads on the latch at
    /// the same time, which is the shape the reply block and the error handler actually
    /// arrive in.
    ///
    /// There is no mutation that reddens this without aborting the runner instead — which is
    /// precisely why the guard is a type rather than a convention. What it asserts is that
    /// one of the delivered answers comes back, exactly once, and that the concurrent path
    /// never falls through to the fallback.
    @Test("Answers racing each other resolve the wait exactly once", .timeLimit(.minutes(1)))
    func concurrentAnswersResolveTheWaitExactlyOnce() async {
        let latch = PendingReply<Int>(ifNothingArrives: -1)

        async let answered = latch.answer(within: .seconds(10))
        await withTaskGroup(of: Void.self) { group in
            for value in 1...32 {
                group.addTask { latch.deliver(value) }
            }
        }

        let answer = await answered
        #expect(
            (1...32).contains(answer),
            """
            the latch answered \(answer). -1 is the fallback, which means thirty-two \
            deliveries raced and none of them reached the caller; anything else is a value \
            nobody delivered.
            """)
    }
}
