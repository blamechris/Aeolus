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
    /// **The deadline cannot fire, so the test asks whether the caller came back and not how
    /// long it took.** The latch's deadline is measured on a `ManualClock` nothing advances.
    /// A latch that parks the cancelled caller is therefore parking it on something that will
    /// never happen, and the caller never returns; a correct latch hands it the fallback at
    /// once, and it returns and sets a flag. `waitUntil` watches that flag on its default
    /// budget, which counts only the time the waiter ran, so a runner stall is added to the
    /// wait instead of spent from it — and the defect, which no stall can cause, still runs
    /// the budget out.
    ///
    /// **Why it is no longer timed.** It asserted the elapsed time: under one second until CI
    /// showed that a loaded runner could take longer than that to run a task that does
    /// nothing, then under five after #319 widened it — on the argument that a bound a busy
    /// machine can reach is the wall-clock upper bound that issue rules out. Five seconds was
    /// still one. A correct latch measured 5.2, 5.6 and 7.6 seconds on stalled runners (#421),
    /// because elapsed time is the one quantity a stall changes without the latch having
    /// done anything. The latch has no delay of its own to measure — it either hands the
    /// caller the fallback or leaves it parked until something resumes it — so the test
    /// asks which, on a clock that cannot answer for it.
    ///
    /// **A failure releases what it left parked.** When the caller did not return, the test
    /// calls `expire()` so the value below can be read and the failure is `waitUntil`'s
    /// record, naming the wait, instead of this test's one-minute time limit. That is after
    /// the claim has been judged; it is not part of it.
    ///
    /// **Mutation:** in `PendingReply.giveUp()`, restore the early `return` that recorded
    /// nothing when `continuation` was `nil`. Run: red on the `waitUntil` after five
    /// scheduled seconds, naming the wait — not on the time limit.
    @Test("A caller cancelled before it waits gives up at once", .timeLimit(.minutes(1)))
    func aCallerCancelledBeforeItWaitsGivesUpAtOnce() async throws {
        let latch = PendingReply<String>(ifNothingArrives: "nothing arrived")
        let release = AsyncSignal()
        let returned = CompletionFlag()
        // Never advanced: the deadline below cannot run out, however long the runner stalls.
        let clock = ManualClock()

        let waiting = Task { () -> String in
            try? await release.wait()
            let answer = await latch.answer(within: .seconds(10), on: clock)
            await returned.mark()
            return answer
        }
        waiting.cancel()
        await release.signal()

        try await waitUntil(
            """
            the caller cancelled before it waited to come back. Cancellation arrived before \
            anything was attached, so the give-up had nobody to hand the fallback to — and a \
            latch that drops it there leaves the caller parked on a continuation nothing will \
            revisit, with a deadline on a clock this test never moves
            """
        ) {
            await returned.isSet
        }

        if await !returned.isSet {
            latch.expire()
        }
        #expect(await waiting.value == "nothing arrived")
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
