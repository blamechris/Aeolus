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
}
