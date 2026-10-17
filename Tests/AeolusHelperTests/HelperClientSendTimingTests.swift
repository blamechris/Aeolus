import AeolusXPC
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import AeolusXPCClient

/// When a message's deadline starts counting, and what a message may still be sent on
/// ([#418](https://github.com/blamechris/Aeolus/pull/418)'s review, F1 and F2).
///
/// Neither question has an answer on the wall clock that a stalled runner could not change, so
/// both are asked of the client's own structure. The first test asks which task reads the clock
/// when a deadline begins. The second builds the interleaving that would send on a connection the
/// client already gave up, and requires that nothing is sent.
@Suite("When a message's deadline starts, and what it may be sent on", .timeLimit(.minutes(1)))
struct HelperClientSendTimingTests {

    /// **A deadline's instant is read on its timer's own task, not on the task that sends.**
    ///
    /// The rule F1 restored: a deadline counts from when its timer first runs, as
    /// `PendingReply.answer(within:on:)` always did. The timer's first run is late by exactly as
    /// long as the client's own cooperative pool is stalled, so a stall is not charged to the
    /// helper, and a reply the helper sent in time is not cut off for it. With the instant read
    /// when the timer was made, inside the sender's own turn on the actor, the stall counted.
    ///
    /// What a test can pin deterministically is **where** the instant is read. That a stall delays
    /// that read is the runtime's, and no test here can stall a pool on demand. So the clock notes,
    /// for each reading of `now`, whether it came from inside the sending task, marked by a task
    /// local the sender sets. A detached timer does not inherit task locals, so a reading on the
    /// timer's own task is unmarked.
    ///
    /// The snapshot is held at the helper until its deadline has parked on the clock, so that
    /// deadline's timer has certainly read the hands, which is the floor below.
    ///
    /// **Mutation:** in `Clock.timer(after:_:)`, read `let due = now.advanced(by: duration)`
    /// before `Task.detached` rather than inside it, which is #418's first head. Run: red on the
    /// readings taken while sending.
    @Test("A deadline's instant is read on its timer's own task, not on the sender's")
    func aDeadlineIsReadOnItsTimersOwnTask() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let clock = SendObservingClock()
        let client = HelperClient(
            transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
            clientDescription: "test client", deadlines: HelperClientApplyDeadlineTests.deadlines,
            clock: clock)

        let snapshot = Task {
            try await SendObservingClock.$sending.withValue(true) { try await client.snapshot() }
        }
        try await waitUntil(
            "the snapshot is held and its deadline has parked", timeout: .seconds(30)
        ) {
            await authority.hasBeenAsked && clock.hands.sleepers == 1
        }

        let readings = clock.readings
        #expect(
            !readings.contains(true),
            """
            \(readings.filter { $0 }.count) of \(readings.count) readings of the clock were taken \
            inside the sending task. A deadline's instant read there counts any stall of the \
            client's own pool against the helper, and cuts off a reply that was sent in time.
            """)
        #expect(readings.count >= 1, "no deadline read the clock, so the check above saw nothing")

        await gate.signal()
        _ = try await HelperClientApplyDeadlineTests.answer(of: snapshot)
        #expect(harness.sessions.count == 1)
    }

    /// **A verb whose connection was given up while it waited sends nothing on it** (F2).
    ///
    /// Two verbs meet one cold handshake and both wait for it (the arrangement
    /// `HelperClientTests.racingVerbsShareOneHandshake` uses, for the reason it gives: while the
    /// `hello` reply is held, neither can find the connection already handshaken). When it
    /// completes, both resume on the actor, one after the other. Each sends through the
    /// internal gate with a send of the test's own, which runs on the actor in the same
    /// synchronous stretch as the check before it. The first to run gives the connection up from
    /// inside its send, as a `disconnect()` or another message's cut-off can while a waiter has
    /// not yet resumed. The second then holds a `live` for a connection the client has given up.
    ///
    /// It must not send on it. Sent, the message would reach a connection the client invalidated,
    /// and the 4099 that came back would read as a helper that is not installed. Whichever verb
    /// runs second is the one asserted on, so the order the runtime resumes them in does not
    /// matter. A send on the given-up connection is told apart from one on a fresh connection by
    /// the generation: one past the given-up one, with no connection, against two past it.
    ///
    /// **Mutation:** in `HelperClient.exchange`, delete the `guard live.generation == generation`.
    /// Run: red on the record, which names the second verb's send on the given-up connection, and
    /// on its outcome, which comes back answered.
    @available(macOS 14.0, *)
    @Test("A verb whose connection was given up while it waited sends nothing on it")
    func aVerbWhoseConnectionWasGivenUpWhileItWaitedSendsNothing() async throws {
        let releaseHandshake = AsyncSignal()
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(), holdingHandshakeReplies: releaseHandshake)
        // A clock nothing moves, so a stalled runner cannot run out the handshake's 15 s while the
        // test holds its reply (#341's class). No deadline is meant to run out here at all.
        let client = HelperClient(
            transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
            clientDescription: "test client", deadlines: ClientListenerHarness.defaultDeadlines,
            clock: ManualClock())
        let record = GivingUpRecord()

        let first = Task { try await Self.send(on: client, recordingIn: record, as: "first") }
        try await waitUntil(
            "the handshake reached the helper and is being held", timeout: .seconds(30)
        ) {
            harness.arrivals == ["hello"]
        }
        let secondStarted = AsyncSignal()
        let second = Task {
            await secondStarted.signal()
            try await Self.send(on: client, recordingIn: record, as: "second")
        }
        try await secondStarted.wait()
        await releaseHandshake.signal()

        let outcomes = [await Self.outcome(of: first), await Self.outcome(of: second)]

        #expect(record.gaveUp.count == 1, "the connection was given up \(record.gaveUp) times")
        #expect(
            record.sentOnTheGivenUpConnection.isEmpty,
            """
            \(record.sentOnTheGivenUpConnection) sent on the connection the client had already \
            given up. Its 4099 would have read as a helper that is not installed.
            """)
        for outcome in outcomes {
            #expect(
                outcome == .connectionAbandoned,
                "a verb on the given-up connection came back \(String(describing: outcome))")
        }
        #expect(await client.health == .idle)
        let session = try #require(harness.sessions.first)
        #expect(await session.messageCount == 1, "anything but the hello reached the helper")
    }

    /// One verb's send: the first to run gives the connection up from inside it; any later one
    /// records whether it is being sent on that given-up connection, and is otherwise answered.
    @available(macOS 14.0, *)
    private static func send(
        on client: HelperClient, recordingIn record: GivingUpRecord, as verb: String
    ) async throws {
        try await client.withHandshakenProxy(.snapshot) { _, resolve in
            let generation = client.assumeIsolated { $0.currentGeneration }
            if record.firstToGiveUp(at: generation, as: verb) {
                // Running on the actor, inside `exchange`: the same thing a `disconnect()` that
                // lands while another verb waits to resume does.
                client.assumeIsolated { $0.disconnect() }
            } else if generation == record.givenUpGeneration.map({ $0 + 1 }) {
                record.sentOnTheGivenUpConnection(by: verb)
            }
            resolve(.success(()))
        }
    }

    /// How a verb's task ended: `nil` for an answer, or the client error it threw.
    private static func outcome(of task: Task<Void, Error>) async -> HelperClientError? {
        do {
            try await HelperClientApplyDeadlineTests.answer(of: task)
            return nil
        } catch {
            return error as? HelperClientError
        }
    }
}

/// What the two verbs in `aVerbWhoseConnectionWasGivenUpWhileItWaitedSendsNothing` saw.
///
/// `Sendable` by way of a lock: the sends run on the client's executor, the reads on the test's.
final class GivingUpRecord: Sendable {

    private struct State {
        var gaveUp: [String] = []
        var givenUpGeneration: UInt64?
        var sentOnTheGivenUpConnection: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var gaveUp: [String] { state.withLock { $0.gaveUp } }
    var givenUpGeneration: UInt64? { state.withLock { $0.givenUpGeneration } }
    var sentOnTheGivenUpConnection: [String] { state.withLock { $0.sentOnTheGivenUpConnection } }

    /// Claims the giving-up for `verb` at `generation` if nobody has claimed it yet.
    func firstToGiveUp(at generation: UInt64, as verb: String) -> Bool {
        state.withLock { state in
            guard state.givenUpGeneration == nil else { return false }
            state.givenUpGeneration = generation
            state.gaveUp.append(verb)
            return true
        }
    }

    func sentOnTheGivenUpConnection(by verb: String) {
        state.withLock { $0.sentOnTheGivenUpConnection.append(verb) }
    }
}

/// A hand-wound clock that notes, for each reading of `now`, whether it was taken inside a task
/// that marked itself as sending.
///
/// The mark is a task local, which a detached task does not inherit: that is the whole of the
/// distinction `aDeadlineIsReadOnItsTimersOwnTask` draws. The hands are a `ManualClock`, so a
/// sleep parks until the test moves them, and `sleepers` counts it as usual.
final class SendObservingClock: Clock, Sendable {

    @TaskLocal static var sending = false

    let hands = ManualClock()
    private let marks = OSAllocatedUnfairLock(initialState: [Bool]())

    /// Every reading of `now` so far, `true` for one taken inside a sending task.
    var readings: [Bool] { marks.withLock { $0 } }

    var now: ContinuousClock.Instant {
        let sending = Self.sending
        marks.withLock { $0.append(sending) }
        return hands.now
    }

    var minimumResolution: Duration { hands.minimumResolution }

    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        try await hands.sleep(until: deadline)
    }
}
