import AeolusXPC
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// `AnonymousListenerHarness`'s own claim ([#583](https://github.com/blamechris/Aeolus/issues/583)):
/// the wait for a reply is counted on a clock only the test moves, and a reply nobody sends ends
/// the wait at the backstop and not at the suite's time limit.
///
/// The listener suites rely on both without saying so. A reply deadline on the wall clock fails
/// every one of them together when the runner stalls, and a deadline on a clock nothing moves
/// hangs them when a regression drops a reply, so each half needs a test of its own: neither
/// shows up as anything but a green run until the day it matters.
@Suite("The listener harness counts its reply deadline on a clock only the test moves")
struct AnonymousListenerHarnessTests {

    /// A reply that does not come is given up on when the test moves the clock past
    /// ``AnonymousListenerHarness/replyDeadline``, and not before.
    ///
    /// The snapshot parks in the authority, so its reply is withheld for as long as the test
    /// likes. A side task waits until the harness has parked the deadline on its clock, which is
    /// the proof that the wait is counted there, and moves the hands by exactly the deadline. The
    /// call must not have come back before that.
    ///
    /// **The hands moved by exactly the deadline, and no other route moved them**
    /// ([#589](https://github.com/blamechris/Aeolus/issues/589)). The clock is read before the call
    /// and again the moment it returns, and the difference must be the deadline. That one read is
    /// what holds both ways to go wrong. A wait that ended earlier than the test's advance has
    /// seen the clock moved by less than the deadline, none at all if the test had not moved it
    /// yet. A test that dropped its advance would still return at the backstop, 30 s in, which
    /// moves the hands an hour. The read is taken before `mover` is awaited, because by then the
    /// advance that ended the wait has been made, and one made after it ended is not what ended it.
    /// There is no flag for the first case: the test once set one before its advance and read it
    /// after `mover` was awaited, by which time `mover` had set it whatever had ended the wait, so
    /// it could not fail ([#581](https://github.com/blamechris/Aeolus/issues/581), item 6).
    ///
    /// **Mutation:** in `AnonymousListenerHarness.answer(of:)`, replace `on: clock` with
    /// `on: ContinuousClock()`. Run: red on the named wait, "the harness's reply deadline parked
    /// on its clock": nothing is parked there.
    /// **Mutation:** delete this test's own `clock.advance(…)`, the one in `mover`. Run: red on the
    /// clock's movement, an hour where the deadline was expected, after the backstop's 30 s.
    /// **Mutation (early end):** make `AnonymousListenerHarness.answer(of:)` park a sleeper with
    /// `Task { try? await clock.sleep(for: Self.replyDeadline) }`, start a `Task` that sleeps 1 ms
    /// of real time and calls `reply.expire()`, and `return await reply.waitForAnswer()`. Run:
    /// red on the clock's movement alone, 0.0 s where 10.0 s was expected, one issue in each of
    /// three runs. The named waits pass, the sleeper being parked. Against the flag this replaces,
    /// the same mutation was red on the movement alone too: the flag never fired.
    @Test("A reply nobody sends is given up on when the clock is moved past its deadline")
    func aReplyNobodySendsIsGivenUpOnWhenTheClockMoves() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let harness = AnonymousListenerHarness(authority: authority)
        let clock = harness.clock

        let hello = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: (try? helloPayload()) ?? Data(), reply: reply)
        }
        #expect(hello.payload != nil, "the handshake failed, so the snapshot was refused instead")

        let mover = Task {
            try await waitUntil(
                "the snapshot reached the authority", timeout: StallTolerantWait.deliveryBudget
            ) {
                await authority.hasBeenAsked
            }
            try await waitUntil(
                "the harness's reply deadline parked on its clock",
                timeout: StallTolerantWait.deliveryBudget
            ) {
                clock.sleepers >= 1
            }
            clock.advance(by: AnonymousListenerHarness.replyDeadline)
        }
        let start = clock.now
        let snapshot = await harness.payloadMessage { proxy, reply in
            proxy.snapshot(reply: reply)
        }
        // Read before `mover` is awaited: the advance that ended the wait has been made by now,
        // and one made after the wait ended is not what ended it.
        let movedBy = clock.now - start
        try await mover.value

        #expect(snapshot.timedOut, "the wait ended with \(snapshot)")
        #expect(
            movedBy == AnonymousListenerHarness.replyDeadline,
            """
            the wait ended with the clock moved by \(movedBy), not by the deadline of \
            \(AnonymousListenerHarness.replyDeadline): the test's own advance did not end it, \
            and the backstop (an hour) or an early end did
            """)
        await gate.signal()
    }

    /// A reply nobody sends ends the wait at the backstop, with the reply's fallback, and not at
    /// the suite's time limit.
    ///
    /// The backstop is given one second here instead of its thirty. Without it the call would
    /// stay parked on a deadline nothing moves, and the only thing left to end the test would be
    /// its limit, a minute in, naming nothing.
    ///
    /// **Mutation:** in `AnonymousListenerHarness.init`, run the backstop on another clock,
    /// `ClockBackstop(running: ManualClock(), after: backstopAfter)`. Run: red on this test's
    /// one-minute limit, which is the very outcome the backstop exists to avoid.
    @Test(
        "A reply nobody sends ends the wait at the backstop, not at the time limit",
        .timeLimit(.minutes(1)))
    func aReplyNobodySendsEndsTheWaitAtTheBackstop() async throws {
        let gate = AsyncSignal()
        let harness = AnonymousListenerHarness(
            authority: GatedSnapshotAuthority(gate: gate), backstopAfter: .seconds(1))

        _ = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: (try? helloPayload()) ?? Data(), reply: reply)
        }
        let snapshot = await harness.payloadMessage { proxy, reply in
            proxy.snapshot(reply: reply)
        }

        #expect(snapshot.timedOut, "the wait ended with \(snapshot)")
        await gate.signal()
    }
}
