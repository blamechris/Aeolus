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
    /// the proof that the wait is counted there, records that it is about to move the hands, and
    /// moves them by exactly the deadline. The call must not have come back before that.
    ///
    /// **Mutation:** in `AnonymousListenerHarness.answer(of:)`, replace `on: clock` with
    /// `on: ContinuousClock()`. Run: red on the named wait, "the harness's reply deadline parked
    /// on its clock": nothing is parked there.
    @Test("A reply nobody sends is given up on when the clock is moved past its deadline")
    func aReplyNobodySendsIsGivenUpOnWhenTheClockMoves() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let harness = AnonymousListenerHarness(authority: authority)
        let clock = harness.clock
        let moved = CompletionFlag()

        let hello = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: (try? helloPayload()) ?? Data(), reply: reply)
        }
        #expect(hello.payload != nil, "the handshake failed, so the snapshot was refused instead")

        let mover = Task {
            try await waitUntil("the snapshot reached the authority") {
                await authority.hasBeenAsked
            }
            try await waitUntil("the harness's reply deadline parked on its clock") {
                clock.sleepers >= 1
            }
            await moved.mark()
            clock.advance(by: AnonymousListenerHarness.replyDeadline)
        }
        let snapshot = await harness.payloadMessage { proxy, reply in
            proxy.snapshot(reply: reply)
        }
        try await mover.value

        #expect(snapshot.timedOut, "the wait ended with \(snapshot)")
        #expect(await moved.isSet, "the wait ended before the test moved the clock")
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
