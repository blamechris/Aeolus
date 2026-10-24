import os

/// Every message this client has sent and not yet seen settled, on every connection it has held,
/// and the one place a message's deadline starts and ends.
///
/// ## A sequenced message's deadline starts at its turn
///
/// The helper answers a connection's `hello`, `snapshot`, `acquireLease` and `apply` one at a
/// time, in the order they were sent (D25, `HelperMessage.sequenced`). A `snapshot` sent while an
/// `apply` is engaging a fan waits at the helper for that `apply`, which may lawfully take 57 s
/// for one fan. A deadline started at the snapshot's send runs out while it waits. The cut-off
/// discards the connection, and the helper releases a connection's leases when it goes: #325's
/// false teardown, moved off the `apply` and onto the read behind it
/// ([#413](https://github.com/blamechris/Aeolus/issues/413)).
///
/// So a sequenced message's deadline starts when every sequenced message sent before it on the
/// same connection has **settled**: answered by its reply block, failed through the connection's
/// error handler, cut off by its own deadline, or answered by a discard. Until then the message
/// has been sent and is waiting for its turn, and nothing about the helper is late. The other
/// three messages are dispatched by the helper the moment they arrive (#229), so their deadline
/// starts at their send, exactly as before.
///
/// Only the earliest unsettled sequenced message on a connection is ever in its turn, because the
/// turn passes only when every message before it has settled. Later messages that settle first,
/// through the error handler, do not move it.
///
/// What the deadline itself is, and when it runs out, is unchanged: `HelperClientDeadlines` picks
/// the figure, `helperNeverAnswered` is the answer, and the caller's `translate(_:on:)` discards
/// the connection. Only the instant it is counted from moves.
///
/// ## Each connection has its own order
///
/// A `Ticket` carries the connection generation its message was sent on, and the turn is passed
/// only among messages of one generation. Two connections are two queues at the helper too, and
/// one must not be able to hold the other's deadlines back.
///
/// An interruption keeps the connection object and its generation. The messages in flight when
/// the helper died each fail with 4097 through their own error handler, which settles them, so a
/// `hello` sent to the replacement waits only until those failures have arrived. Their deadlines
/// still bound that wait if one never does.
///
/// ## A cancelled caller does not settle its message
///
/// Cancellation says nothing about the helper, which is still working on the message, and a
/// message sent after it still waits for it at the helper. If cancelling the caller settled it,
/// the next sequenced message's deadline would start while the helper was still lawfully inside
/// the cancelled one, and a view navigating away from an `apply` it had started would cut off the
/// next snapshot: #413 again, through a different door.
///
/// So the deadline belongs to the **message**, not to its caller. It keeps running when the caller
/// goes, and when it runs out it settles the message and passes the turn. It does not discard the
/// connection, because cancellation is not a teardown (`translate(_:on:)`): with nobody waiting,
/// nothing reports the cut-off, and the message behind it then gets its own deadline. A healthy
/// helper is never torn down for a caller that left.
///
/// **What a wedged helper costs is one deadline per orphan, not one in all.** Each cancelled
/// sequenced message ahead of a live read settles only when its own deadline runs out, and only
/// then does the next one's begin. So a read behind N orphans waits N deadlines before its own
/// starts. A caller that cancels and re-sends a `snapshot` every 2 s behind a wedged `apply` adds
/// orphans faster than their 5 s deadlines retire them, and the read it is waiting for is never
/// cut off. No client does that: `fanctl` awaits each verb, and the app follows the rule below.
///
/// **The rule the app chose for [#419](https://github.com/blamechris/Aeolus/issues/419): the UI
/// never cancels a sequenced verb it means to send again.** This client still does not bound the
/// cost of orphans; the app simply makes none.
///
/// - **The read connection sends only `snapshot`, one at a time, and never cancels one.**
///   `HelperSnapshotSource`, in the app, owns its own `HelperClient` and nothing else talks on
///   it. Its loop awaits each answer before it pauses and sends the next; a consumer that leaves
///   cuts short only the pause, and a request outstanding at that moment is left to finish.
///   `HelperSnapshotSourceTests` holds it there with a parked reply: cancelling that request
///   from `stop()` turns them red.
/// - **A SwiftUI `.task` never owns an XPC await.** SwiftUI cancels a `.task` when its view
///   disappears, which is exactly the cancellation this rule forbids. Views call the source's
///   `start()` and `stop()`, and the request's task belongs to the source.
/// - **Control is to travel on a second connection** (later PRs of #153), so that no
///   `snapshot` ever queues behind an `apply`; until then the app sends no control verb. The
///   control side's own test of this rule lands with its driver.
///
/// ## A discard answers everything still in flight on its connection
///
/// `abandonAll(on:answering:)` is how `HelperClient.discardConnection` settles a generation, and it
/// answers each message **before** the connection is invalidated. That order is the point. The
/// client's own `invalidate()` comes back to every message still parked on the connection as 4099,
/// which `translate(_:on:)`'s default arm reads as "the helper is not installed or not yet
/// approved": a message the client killed itself, misdiagnosed as a helper that was never there
/// (#413's comment). Answered first, each one carries what is true instead, and the 4099 that
/// follows finds its latch already resolved.
///
/// ## Why a lock and not the actor
///
/// A message settles inside its reply block or its error handler, which libxpc calls on its own
/// threads, synchronously. Settling through the actor would need a `Task` hop, and the turn would
/// then pass whenever that hop ran rather than when the answer arrived: a gap in which the next
/// message's deadline had not started though nothing was ahead of it. `OSAllocatedUnfairLock` makes
/// the class `Sendable` without the `@unchecked` that `CLAUDE.md` rule 10 treats as a claim needing
/// review, as `MessageSequencer`'s does on the helper's side.
///
/// It holds no fan state and nothing a lease could be rebuilt from: what each message left behind
/// is how to answer its caller, and nothing it carried.
final class InFlightMessages: Sendable {

    /// One sent message: the connection generation it went out on, and its place in the order this
    /// client sends in.
    struct Ticket: Hashable, Sendable {
        let generation: UInt64
        let serial: UInt64
    }

    /// What a sent message left for whoever settles it.
    private struct Sent: Sendable {
        let isSequenced: Bool
        let deadline: Duration

        /// Hands the message's caller its deadline's answer, `helperNeverAnswered`.
        let runOut: @Sendable () -> Void

        /// Hands the message's caller a discard's answer.
        let abandon: @Sendable (HelperClientError) -> Void

        /// The deadline, from the moment the message's turn came. `nil` while it waits for one.
        var timer: Task<Void, Never>?
    }

    private struct State: Sendable {
        var issued: UInt64 = 0
        var unsettled: [Ticket: Sent] = [:]
    }

    private let clock: any Clock<Duration>
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameter clock: what every deadline here is measured on. `ContinuousClock` in
    ///   production; the suite's own clock, which only it moves, in the tests.
    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    /// How many messages have a deadline running: started at their turn and not yet settled.
    ///
    /// For the suite, through `HelperClient.deadlinesRunning`. A deadline's instant is read when
    /// its timer first runs, so a test that moves a hand-wound clock must first know that every
    /// running deadline has parked on it; this count beside the clock's own sleepers says so.
    var running: Int {
        state.withLock { state in state.unsettled.values.filter { $0.timer != nil }.count }
    }

    /// One sent message as its sender holds it: the block that answers it, and the wait for that
    /// answer.
    struct Admission<Answer>: Sendable {

        /// The message's reply block and its error handler both. It hands the waiting caller the
        /// answer and settles the message: its deadline ends, and if it was the sequenced message
        /// in its turn, the next one's begins. A second call does nothing, which is what lets both
        /// blocks run when libxpc runs both.
        let settle: @Sendable (Result<Answer, Error>) -> Void

        fileprivate let pending: PendingReply<Result<Answer, Error>>

        /// Waits for the first of: `settle`, the message's deadline running out
        /// (`helperNeverAnswered`), a discard's answer, or this caller's cancellation, which
        /// leaves the message in flight.
        func answer() async -> Result<Answer, Error> {
            await pending.waitForAnswer()
        }

        /// Settles the message with `error`, for a message that never reached the helper, and
        /// hands `error` back for its sender to throw.
        func failing(with error: Error) -> Error {
            settle(.failure(error))
            return error
        }
    }

    /// Records `message` as sent on `generation`, and starts its deadline now if its turn has come.
    ///
    /// Called immediately before the send, so that a reply arriving at once has a message to
    /// settle. An unsequenced message's turn is always now. A sequenced one's is now when no
    /// sequenced message sent before it on `generation` is still unsettled, and otherwise when the
    /// last of those settles.
    func admit<Answer>(
        _ message: HelperMessage, on generation: UInt64, within deadline: Duration,
        answering _: Answer.Type
    ) -> Admission<Answer> {
        // Two fallbacks, because the two ways of giving up are different events and the
        // deadline's is acted on. A caller that was cancelled has said nothing about the
        // helper; see `HelperClient.translate(_:on:)`.
        let pending = PendingReply<Result<Answer, Error>>(
            ifNothingArrives: .failure(HelperClientError.helperNeverAnswered(after: deadline)),
            ifCancelled: .failure(CancellationError())
        )
        let ticket = state.withLock { state in
            state.issued &+= 1
            let ticket = Ticket(generation: generation, serial: state.issued)
            state.unsettled[ticket] = Sent(
                isSequenced: message.isSequenced, deadline: deadline,
                runOut: { pending.expire() }, abandon: { pending.deliver(.failure($0)) })
            if !message.isSequenced || Self.turn(on: generation, in: state) == ticket {
                state.unsettled[ticket]?.timer = startDeadline(of: ticket, after: deadline)
            }
            return ticket
        }
        let settle: @Sendable (Result<Answer, Error>) -> Void = { [self] answer in
            pending.deliver(answer)
            take(ticket)?.timer?.cancel()
        }
        return Admission(settle: settle, pending: pending)
    }

    /// Answers every message still unsettled on `generation` with `verdict`, and ends their
    /// deadlines. In send order, so the answers do too.
    ///
    /// `HelperClient.discardConnection` calls this before it invalidates the connection; see the
    /// type's documentation for why the order matters. The loop is a **fan-out** of one answer to
    /// the messages already sent and never a resend: nothing here sends, and
    /// `HelperClientSendPathSeamTests.sendPathFanOut` names it for that reason.
    func abandonAll(on generation: UInt64, answering verdict: HelperClientError) {
        let abandoned = state.withLock { state -> [Sent] in
            state.unsettled.keys
                .filter { $0.generation == generation }
                .sorted { $0.serial < $1.serial }
                .compactMap { state.unsettled.removeValue(forKey: $0) }
        }
        for sent in abandoned {
            sent.timer?.cancel()
            sent.abandon(verdict)
        }
    }

    // MARK: - The turn

    /// Removes `ticket`'s message, and passes the turn if it was a sequenced one.
    private func take(_ ticket: Ticket) -> Sent? {
        state.withLock { state in
            guard let sent = state.unsettled.removeValue(forKey: ticket) else { return nil }
            if sent.isSequenced { passTurn(on: ticket.generation, in: &state) }
            return sent
        }
    }

    /// Starts the deadline of the sequenced message whose turn it now is on `generation`, if it has
    /// not started already. A message that settled out of order, behind the one in its turn, moves
    /// nothing: the earliest unsettled message is the same one, with its deadline already running.
    private func passTurn(on generation: UInt64, in state: inout State) {
        guard let next = Self.turn(on: generation, in: state),
            let waiting = state.unsettled[next], waiting.timer == nil
        else { return }
        state.unsettled[next]?.timer = startDeadline(of: next, after: waiting.deadline)
    }

    /// The sequenced message whose turn it is on `generation`: the earliest still unsettled.
    private static func turn(on generation: UInt64, in state: State) -> Ticket? {
        state.unsettled
            .filter { $0.key.generation == generation && $0.value.isSequenced }
            .keys
            .min { $0.serial < $1.serial }
    }

    /// The message's deadline ran out before anything settled it.
    ///
    /// It is settled as cut off, which passes the turn, and its caller is handed
    /// `helperNeverAnswered`. A caller still waiting then discards the connection; one that was
    /// cancelled is waiting for nothing, and the answer goes nowhere.
    private func deadlineRanOut(_ ticket: Ticket) {
        take(ticket)?.runOut()
    }

    /// Starts `ticket`'s deadline, counted from when its timer first runs.
    private func startDeadline(of ticket: Ticket, after deadline: Duration) -> Task<Void, Never> {
        clock.timer(after: deadline) { [weak self] in self?.deadlineRanOut(ticket) }
    }
}

extension Clock {

    /// A task that calls `ranOut` once `duration` has passed on this clock, and never if it is
    /// cancelled first.
    ///
    /// **The instant is read when the task first runs, not when the timer is made**, as
    /// `PendingReply.answer(within:on:)` reads it. A deadline is the client's statement that the
    /// helper took too long, so time the client spent unable to run its own timer must not count
    /// against the helper: a client whose cooperative pool is stalled would otherwise cut off a
    /// reply the helper sent in time. The cost is that a deadline can run long by the stall, which
    /// is the direction a client that cannot see its helper should err in.
    ///
    /// `HelperClientSendTimingTests.aDeadlineIsReadOnItsTimersOwnTask` pins where the
    /// instant is read. That a stall delays the read is the runtime's, and no test here can stall
    /// a pool on demand.
    ///
    /// A method on the clock rather than a function taking one, so that `now` and the instant it
    /// is advanced to are the same clock's, whichever clock was injected.
    fileprivate func timer(
        after duration: Duration, _ ranOut: @escaping @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task.detached {
            let due = now.advanced(by: duration)
            do {
                try await sleep(until: due, tolerance: nil)
            } catch {
                return
            }
            ranOut()
        }
    }
}
