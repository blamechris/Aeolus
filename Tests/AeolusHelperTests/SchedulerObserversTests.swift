import Testing

@testable import AeolusHelper

/// The fan-out that lets two things listen to one scheduler (ADR 0012, PR C).
///
/// `SMCReadScheduler` takes one observer, and `ConnectionHealth` was it. The gate monitor needs
/// the same events, and `ConnectionHealth`'s count is a claim about **order** ("three failures
/// in a row"), so the one rule of the fan-out is that it changes nothing for the first listener:
/// every event, in the order the scheduler made them, delivered before the call returns.
///
/// Every test names the mutation that must turn it red; each was run, and the table is on the
/// pull request.
@Suite("The scheduler's observer fan-out", .timeLimit(.minutes(1)))
struct SchedulerObserversTests {

    private static let script: [SchedulerEvent] = {
        let base = ContinuousClock.now
        return [
            .waiterParked(priority: .supervisor, queuedAt: base),
            .turnGranted(priority: .supervisor, queuedAt: base),
            .wholeReadFailed(priority: .supervisor, detail: "no answer"),
            .turnEnded(priority: .supervisor),
            .wholeReadSucceeded(priority: .snapshot),
        ]
    }()

    /// Each observer hears every event, and within one event they hear it in the order they
    /// were given — the listener the helper already had stays first.
    ///
    /// **Mutation:** drop the first observer (`observers.dropFirst()`) in
    /// `schedulerDidObserve(_:)`. Run: red.
    /// **Mutation:** iterate `observers.reversed()`. Run: red.
    /// **Mutation:** deliver only `waiterParked` events to every observer after the first.
    /// Run: red.
    @Test("Every observer hears every event, in the order they were given")
    func everyObserverHearsEveryEventInOrder() {
        let journal = ObserverJournal()
        let fanOut = SchedulerObservers([
            JournalingObserver("first", into: journal), JournalingObserver("second", into: journal),
        ])

        for event in Self.script { fanOut.schedulerDidObserve(event) }

        let expected = Self.script.flatMap { event in
            [
                HeardEvent(observer: "first", event: event),
                HeardEvent(observer: "second", event: event),
            ]
        }
        #expect(journal.heard == expected)
    }

    /// Delivery is synchronous: it has happened by the time the call returns, on the calling
    /// thread, with no hop. The scheduler reports from inside its own isolation so that the
    /// report is ordered with the state change it describes, and a fan-out that handed each
    /// event to a `Task` would give that up.
    ///
    /// **Mutation:** wrap the delivery loop in `Task { … }`. Run: red — the journal is empty when
    /// the call returns.
    @Test("Delivery is complete when the call returns")
    func deliveryIsSynchronous() {
        let journal = ObserverJournal()
        let fanOut = SchedulerObservers([JournalingObserver("only", into: journal)])

        fanOut.schedulerDidObserve(.turnEnded(priority: .snapshot))

        #expect(journal.heard.count == 1, "the event was not delivered before the call returned")
    }

    /// The real `ConnectionHealth`, behind the fan-out, still counts: three consecutive
    /// whole-read failures reach a reconnect, and a success between them resets the run. The
    /// second half is the one about **order** — failure, failure, success, failure, failure is
    /// four failures and no run of three.
    ///
    /// **Mutation:** build the fan-out without its first observer. Run: red — the three
    /// failures reach nothing.
    /// **Mutation:** deliver `wholeReadSucceeded` to nobody. Run: red — the second half
    /// reconnects.
    @Test("ConnectionHealth behind the fan-out counts what it counted before")
    func connectionHealthStillCountsThroughTheFanOut() async {
        let failure = SchedulerEvent.wholeReadFailed(priority: .snapshot, detail: "no answer")
        let success = SchedulerEvent.wholeReadSucceeded(priority: .snapshot)

        // A run of three reconnects once.
        do {
            let recovery = RecordingReconnector()
            let health = ConnectionHealth(
                clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
            await health.start(recovering: recovery)
            let fanOut = SchedulerObservers([health, GateWaitMonitor()])

            for _ in 0..<3 { fanOut.schedulerDidObserve(failure) }
            await yieldUntil("three outcomes to be handled") {
                await health.observedOutcomes == 3
            }

            #expect(await recovery.attempts == 1)
            await health.stop()
        }

        // Interrupted by a success, four failures are not a run of three.
        do {
            let recovery = RecordingReconnector()
            let health = ConnectionHealth(
                clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
            await health.start(recovering: recovery)
            let fanOut = SchedulerObservers([health, GateWaitMonitor()])

            for event in [failure, failure, success, failure, failure] {
                fanOut.schedulerDidObserve(event)
            }
            await yieldUntil("five outcomes to be handled") {
                await health.observedOutcomes == 5
            }

            #expect(await recovery.attempts == 0, "a success in the middle did not reset the run")
            await health.stop()
        }
    }
}
