import Testing

@testable import AeolusHelper

/// `ConnectionHealth`: the count, the word "consecutive", and the rate limit.
///
/// Every test here drives the observer through `schedulerDidObserve(_:)` — the same
/// synchronous, ordered call the scheduler makes from inside its own actor — rather than
/// through a scheduler. That is deliberate: the scheduler's emission is
/// `SchedulerObservingTests`' subject, and mixing the two would make a failure here
/// ambiguous between "the count is wrong" and "the event was not emitted".
///
/// `observedOutcomes` is what each test waits on. Waiting on the *effect* instead — the
/// reconnect count — cannot tell "exactly one fired" from "the second has not been processed
/// yet", which is [#109](https://github.com/blamechris/Aeolus/issues/109)'s complaint in the
/// one place it would be invisible.
///
/// ## Every count below is a literal, and that is not a style choice
///
/// The first draft of this suite derived its counts from
/// `ConnectionHealthLimits.consecutiveWholeReadFailures`, which reads as the careful thing to
/// do and is the opposite. **It was measured:** raising that constant from 3 to 4 raised the
/// number of failures every test drove along with it, and the whole 1088-test suite stayed
/// green — a suite that could not fail on the mutation it was written to catch. Literals are
/// what make the policy and the assertion two things that can disagree.
///
/// `theLimitsAreWhatTheseTestsAssume` pins the constants those literals encode, so a
/// deliberate change to the policy fails in one obvious place rather than silently making the
/// rest of the suite mean something else.
///
/// `.timeLimit` because every wait here is on a pump task: a pump that stopped draining would
/// hang rather than fail, and a green suite must mean the tests ran.
@Suite("Connection health", .timeLimit(.minutes(1)))
struct ConnectionHealthTests {

    private static func failure(
        _ priority: SMCReadPriority = .snapshot
    ) -> SchedulerEvent {
        .wholeReadFailed(priority: priority, detail: "the SMC did not answer")
    }

    /// Yields `events` and waits until every one has been handled to completion.
    ///
    /// The target is computed from the count already handled rather than from `events.count`,
    /// because `observedOutcomes` is cumulative and a test may drive twice — which is what
    /// `aRunAfterTheWindowReconnectsAgain` does either side of the clock advancing.
    private static func drive(
        _ health: ConnectionHealth, _ events: [SchedulerEvent]
    ) async {
        let target = await health.observedOutcomes + events.count
        for event in events { health.schedulerDidObserve(event) }
        await yieldUntil("every event to be handled") {
            await health.observedOutcomes == target
        }
    }

    // MARK: - The policy the literals encode

    /// The two numbers every count below is written against.
    ///
    /// It is the only place either constant is read, which is what makes the rest of the
    /// suite able to disagree with it. See this suite's documentation for the measurement
    /// that made this necessary: with the counts derived instead, raising the threshold by
    /// one left all 1088 tests green.
    @Test("The policy is three consecutive failures and a thirty-second window")
    func theLimitsAreWhatTheseTestsAssume() {
        #expect(ConnectionHealthLimits.consecutiveWholeReadFailures == 3)
        #expect(ConnectionHealthLimits.minimumInterval == .seconds(30))
    }

    // MARK: - The count

    /// Three consecutive whole-read failures fire exactly one reconnect.
    ///
    /// **Mutation:** raise `ConnectionHealthLimits.consecutiveWholeReadFailures` by one. Run:
    /// red here — three failures no longer reach the threshold and nothing reconnects — and
    /// red on `theLimitsAreWhatTheseTestsAssume`. Both, deliberately: the pin alone would say
    /// a number changed, and this says the behaviour did.
    ///
    /// It drives *exactly* three rather than comfortably more, because a test that drove six
    /// would still see one reconnect with the threshold raised — it would be asserting the
    /// rate limit under another name.
    @Test("A run of whole-read failures fires one reconnect")
    func aRunOfFailuresFiresOneReconnect() async throws {
        let recovery = RecordingReconnector()
        let health = ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
        await health.start(recovering: recovery)

        await Self.drive(health, Array(repeating: Self.failure(), count: 3))

        #expect(await recovery.attempts == 1)
        await health.stop()
    }

    /// One short of the threshold does nothing at all.
    ///
    /// The other side of the boundary, and the mutation it kills is the mirror of the one
    /// above.
    ///
    /// **Mutation:** lower `ConnectionHealthLimits.consecutiveWholeReadFailures` by one, or
    /// change the comparison to `>` … `- 1`. Run: red — a reconnect fires on a run the
    /// policy says is still a transient.
    @Test("One failure short of the threshold reconnects nothing")
    func aShortRunReconnectsNothing() async throws {
        let recovery = RecordingReconnector()
        let health = ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
        await health.start(recovering: recovery)

        await Self.drive(health, Array(repeating: Self.failure(), count: 2))

        #expect(await recovery.attempts == 0)
        await health.stop()
    }

    /// "Consecutive" means consecutive: one successful read in the middle resets the run.
    ///
    /// Without this, `consecutiveFailures` could be a lifetime total and every test above
    /// would still pass — and a helper that reconnected after its third *ever* failed read,
    /// hours apart, would be recycling the connection over a machine that is working.
    ///
    /// **Mutation:** delete `consecutiveFailures = 0` from the `.wholeReadSucceeded` branch
    /// of `ConnectionHealth.handle(_:)`. Run: red.
    @Test("A successful read resets the run")
    func aSuccessfulReadResetsTheRun() async throws {
        let recovery = RecordingReconnector()
        let health = ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
        await health.start(recovering: recovery)

        var script = Array(repeating: Self.failure(), count: 2)
        script.append(.wholeReadSucceeded(priority: .supervisor))
        script += Array(repeating: Self.failure(), count: 2)
        await Self.drive(health, script)

        #expect(
            await recovery.attempts == 0,
            "two short runs either side of a good read were counted as one long one")
        await health.stop()
    }

    /// The run is counted across **both** paths, which is what "either path" in #103's A6
    /// means and is the whole reason the count lives at the scheduler.
    ///
    /// A machine with no client attached produces supervisor reads only; a machine whose
    /// safety cycle is between ticks produces snapshot reads only. A counter that reset on a
    /// change of priority would need both paths to fail three times each before it noticed
    /// anything, on a connection that is simply gone.
    @Test("Failures on either path count towards the same run")
    func failuresOnEitherPathCountTogether() async throws {
        let recovery = RecordingReconnector()
        let health = ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
        await health.start(recovering: recovery)

        let alternating = (0..<3).map { index in
            Self.failure(index.isMultiple(of: 2) ? .snapshot : .supervisor)
        }
        await Self.drive(health, alternating)

        #expect(await recovery.attempts == 1)
        await health.stop()
    }

    // MARK: - The rate limit

    /// Twice the threshold's worth of failures, back to back, is still one reconnect.
    ///
    /// A connection that is genuinely gone keeps failing, so without a limiter this fires
    /// once every `consecutiveWholeReadFailures` reads — roughly every 1.5 s, for ever — and
    /// each attempt takes the exclusive scheduler turn the safety cycle needs to discover
    /// that reading works again. The limiter is what keeps a dead connection from becoming a
    /// busy loop against the mechanism that would notice it coming back.
    ///
    /// **Mutation:** delete the `if let lastAttemptAt, now - lastAttemptAt < …` block from
    /// `ConnectionHealth.attemptReconnect()`. Run: red on the attempt count — two, not one.
    @Test("A second run inside the window reconnects nothing")
    func aSecondRunInsideTheWindowIsRefused() async throws {
        let recovery = RecordingReconnector()
        let health = ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
        await health.start(recovering: recovery)

        await Self.drive(health, Array(repeating: Self.failure(), count: 6))

        #expect(await recovery.attempts == 1)
        await health.stop()
    }

    /// The window **reopens**, and this is the half a fast test cannot reach without a clock
    /// it owns.
    ///
    /// A limiter with no expiry is a helper that reconnects once per boot: the SMC comes back
    /// on its own — a driver reload, a wake that took longer than expected — and nothing ever
    /// rebuilds the handle again. `TestClock` is injected for this test and for no other
    /// reason.
    ///
    /// **Mutation:** in `attemptReconnect()`, drop the `now - lastAttemptAt < …` comparison
    /// and refuse whenever `lastAttemptAt` is non-`nil`. Run: red — the second run after the
    /// window has passed reconnects nothing.
    @Test("A run after the window has passed reconnects again")
    func aRunAfterTheWindowReconnectsAgain() async throws {
        let recovery = RecordingReconnector()
        let clock = TestClock()
        let health = ConnectionHealth(clock: clock, log: SafetyLog(recording: { _, _ in }))
        await health.start(recovering: recovery)

        await Self.drive(health, Array(repeating: Self.failure(), count: 3))
        clock.advance(by: ConnectionHealthLimits.minimumInterval + .seconds(1))
        await Self.drive(health, Array(repeating: Self.failure(), count: 6))

        #expect(await recovery.attempts == 2)
        await health.stop()
    }

    /// The refusal is logged **once per window**, not once per refused run.
    ///
    /// `connectionReconnectRateLimited` is a `.fault`, and a machine whose `open()` keeps
    /// failing produces a run every ~1.5 s for the whole thirty seconds — so logging the
    /// *state* puts twenty identical fault lines in `log show` per window, which is the
    /// per-tick logging this subsystem refuses everywhere else. It is a transition instead,
    /// the discipline `ReclamationWatchdog` already uses.
    ///
    /// Both halves are here, because a flag that is set and never cleared is silent for the
    /// rest of the process: the second window must produce a second line.
    ///
    /// **Mutation A:** drop the `guard !hasLoggedRefusalInThisWindow` from
    /// `attemptReconnect()` and log every refusal. Run: red — four lines, not two.
    /// **Mutation B:** delete `hasLoggedRefusalInThisWindow = false` from the attempt path,
    /// so the flag is never cleared. Run: red — one line, not two.
    @Test("The rate-limited refusal is logged once per window")
    func theRefusalIsLoggedOncePerWindow() async throws {
        let recovery = RecordingReconnector()
        let clock = TestClock()
        let recorded = RecordedLog()
        let health = ConnectionHealth(
            clock: clock,
            log: SafetyLog(recording: { [recorded] in recorded.append($0, $1) }))
        await health.start(recovering: recovery)

        // A rebuild, then two further runs inside the window it opened — two refusals, one
        // line. Six rather than three, because one refused run cannot tell "once per window"
        // from "once per run".
        await Self.drive(health, Array(repeating: Self.failure(), count: 3))
        await Self.drive(health, Array(repeating: Self.failure(), count: 6))
        #expect(recorded.lines(containing: "Not rebuilding").count == 1)

        // The window reopens, a second rebuild happens, and the next refusal inside *that*
        // window is a new transition.
        clock.advance(by: ConnectionHealthLimits.minimumInterval + .seconds(1))
        await Self.drive(health, Array(repeating: Self.failure(), count: 3))
        await Self.drive(health, Array(repeating: Self.failure(), count: 6))

        #expect(await recovery.attempts == 2)
        #expect(
            recorded.lines(containing: "Not rebuilding").count == 2,
            """
            the rate-limited refusal was logged \
            \(recorded.lines(containing: "Not rebuilding").count) times across two windows \
            with two refusals in each. Once per window is a transition; more is the state, \
            and the state is a fault line every second and a half for as long as the SMC is \
            gone.
            """)
        await health.stop()
    }

    /// **The reset happens before the window is consulted**, which `attemptReconnect()`'s own
    /// comment calls "the whole of the rate limit" and which nothing tested.
    ///
    /// Moving `consecutiveFailures = 0` below the window check leaves the run standing on the
    /// refused path — so every subsequent failure asks again, and the *next* open window is
    /// spent by a single failure rather than by a fresh run of three. The limiter would then
    /// be the only thing between the helper and a reconnect attempt per read, which is a check
    /// nothing may depend on alone.
    ///
    /// The assertion is deliberately on the far side of the window rather than on the log:
    /// with the refusal now logged once per window, a log-based test cannot see this mutation
    /// at all.
    ///
    /// **Mutation:** in `attemptReconnect()`, move `consecutiveFailures = 0` below the
    /// `if let lastAttemptAt …` block. Run: red — the single failure after the window reopens
    /// reconnects, because the refused run was never cleared.
    @Test("A refused run is cleared before the window is checked, not after")
    func theRunIsResetBeforeTheWindowIsChecked() async throws {
        let recovery = RecordingReconnector()
        let clock = TestClock()
        let health = ConnectionHealth(clock: clock, log: SafetyLog(recording: { _, _ in }))
        await health.start(recovering: recovery)

        await Self.drive(health, Array(repeating: Self.failure(), count: 3))
        #expect(await recovery.attempts == 1)

        // Refused, and the run it was refused for must not survive the refusal.
        await Self.drive(health, Array(repeating: Self.failure(), count: 3))
        #expect(await recovery.attempts == 1)

        clock.advance(by: ConnectionHealthLimits.minimumInterval + .seconds(1))
        await Self.drive(health, [Self.failure()])

        #expect(
            await recovery.attempts == 1,
            """
            one failure after the window reopened was enough to reconnect, so the run refused \
            inside the window was still standing. Three consecutive failures is the policy; a \
            run that survives a refusal makes it one.
            """)
        await health.stop()
    }

    // MARK: - The buffer

    /// An outcome the buffer threw away is **noticed**, and the run it was in ends.
    ///
    /// `.bufferingNewest` drops the oldest unhandled outcome, and the doc argued only the
    /// harmless direction of that: a dropped *failure* delays a reconnect the next failure
    /// asks for again. The direction it did not argue is the dangerous one — a dropped
    /// *success* joins two runs that were never consecutive into one that looks it, and
    /// rebuilds a handle that is working. So the gap is made visible rather than reasoned
    /// about.
    ///
    /// The pump is parked inside a reconnect while the flood arrives, which is the only place
    /// it can be parked deliberately; everything yielded during the park piles up in the
    /// 64-slot buffer, and the sixty-fifth arrival evicts the oldest — the success.
    ///
    /// **The assertion is the drop count rather than a reconnect that did not happen**, and
    /// that is a limit worth stating plainly rather than dressing up. A run only ever survives
    /// a suspension of the pump if the pump suspended mid-run, and the sole suspension point
    /// is `attemptReconnect`, which resets the run before it suspends — so no fixture can put
    /// the pump to sleep holding a run of two. What is asserted is therefore that the
    /// eviction was seen, exactly, and by how much; the reset it drives is one line away from
    /// it in `handle(_:recovering:)`.
    ///
    /// **Mutation:** delete the `if let lastHandledSequence, outcome.sequence >
    /// lastHandledSequence + 1` block from `ConnectionHealth.handle(_:recovering:)`. Run: red
    /// — nothing notices, which is the state this test exists to end.
    @Test("An outcome evicted by the buffer is counted rather than silently absorbed")
    func anEvictedOutcomeIsNoticed() async throws {
        let recovery = HoldingReconnector()
        let health = ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
        await health.start(recovering: recovery)

        for _ in 0..<3 { health.schedulerDidObserve(Self.failure()) }
        await yieldUntil("the pump to park inside the reconnect") { await recovery.isHolding }

        // One success, then a full buffer behind it. The success is the oldest unhandled
        // outcome, so it is the one thrown away — the eviction the doc used to argue was
        // harmless.
        health.schedulerDidObserve(.wholeReadSucceeded(priority: .snapshot))
        for _ in 0..<64 { health.schedulerDidObserve(Self.failure()) }

        await recovery.release()
        await yieldUntil("everything the buffer kept to be handled") {
            await health.observedOutcomes == 3 + 64
        }

        #expect(
            await health.outcomesLostToTheBuffer == 1,
            """
            the buffer dropped an outcome and nothing noticed. A dropped success joins two \
            runs that were never consecutive, and the reconnect that follows rebuilds a \
            handle that is working.
            """)
        await health.stop()
    }

    // MARK: - Binding, and what is not counted

    /// Failures that arrive **before** the observer is bound are handled once it is.
    ///
    /// The window is real: `HelperComposition.production(log:)` builds the scheduler with
    /// this observer attached, and `bringUp()` binds the plane afterwards — so discovery and
    /// reconciliation's reads happen while the pump is not yet draining. Buffered rather than
    /// dropped, because a boot where the SMC is already gone is the least convenient time to
    /// start ignoring failures.
    @Test("Failures observed before the bind are handled once it happens")
    func failuresBeforeTheBindAreNotLost() async throws {
        let recovery = RecordingReconnector()
        let health = ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))

        for _ in 0..<3 {
            health.schedulerDidObserve(Self.failure())
        }
        #expect(await recovery.attempts == 0, "nothing may be handled before the pump exists")

        await health.start(recovering: recovery)
        await yieldUntil("the buffered failures to be handled") {
            await health.observedOutcomes == 3
        }

        #expect(await recovery.attempts == 1)
        await health.stop()
    }

    /// A `start(recovering:)` after `stop()` is refused, and says so.
    ///
    /// It used to succeed and observe nothing: `stop()` finishes the stream and clears `pump`,
    /// so the `guard pump == nil` let a second start through, the `for await` returned at
    /// once, and the instance was left holding a completed task. Looking started while
    /// observing nothing is the precise shape `stop()`'s own documentation says this
    /// repository refuses, one method away from where it says it.
    ///
    /// Refused rather than trapped: this is unreachable through the composition root, which
    /// starts once in `bringUp()` and stops once in `shutDown()`, and a root daemon holding
    /// fans must not be killed by a lifecycle mistake it can survive. `isObserving` is what
    /// makes the refusal a fact rather than a silence.
    ///
    /// **Mutation:** delete the `guard !hasStopped` from `start(recovering:)`. Run: red —
    /// `isObserving` is `true` on an instance whose stream is finished.
    @Test("A start after a stop is refused rather than quietly observing nothing")
    func aRestartAfterStopIsRefused() async throws {
        let recovery = RecordingReconnector()
        let recorded = RecordedLog()
        let health = ConnectionHealth(
            clock: TestClock(),
            log: SafetyLog(recording: { [recorded] in recorded.append($0, $1) }))

        await health.start(recovering: recovery)
        #expect(await health.isObserving)

        await health.stop()
        #expect(await health.isObserving == false)

        await health.start(recovering: recovery)
        #expect(
            await health.isObserving == false,
            """
            a restarted observer reports that it is observing. Its stream is finished, so it \
            will count no failure for the life of the process while every caller believes \
            something is watching.
            """)
        #expect(!recorded.lines(containing: "refused").isEmpty)

        // And the refusal is real, not merely reported: nothing is handled afterwards.
        for _ in 0..<3 { health.schedulerDidObserve(Self.failure()) }
        #expect(await health.observedOutcomes == 0)
        #expect(await recovery.attempts == 0)
    }

    /// A reconnect that throws is not a crash and is not a retry: the run is already reset,
    /// so the next one starts from zero and the window still governs it.
    @Test("A reconnect that throws leaves the observer counting")
    func aFailedReconnectIsSurvived() async throws {
        let recovery = RecordingReconnector(failing: true)
        let recorded = RecordedLog()
        let health = ConnectionHealth(
            clock: TestClock(),
            log: SafetyLog(recording: { [recorded] in recorded.append($0, $1) }))
        await health.start(recovering: recovery)

        await Self.drive(health, Array(repeating: Self.failure(), count: 3))

        #expect(await recovery.attempts == 1)
        #expect(!recorded.lines(containing: "Rebuilding the SMC connection failed").isEmpty)
        await health.stop()
    }

    /// Turn events are dropped **at the door**, before the buffer, and this is the shape that
    /// can tell that apart from dropping them one step later.
    ///
    /// A snapshot is 46 turns and one outcome, so turn events outnumber the ones this type
    /// counts by about that ratio — and the event buffer holds the *newest* 64. Forwarding
    /// them would therefore evict the outcomes being counted, invisibly, on a busy machine.
    ///
    /// The script reproduces exactly that, and it is the only shape that can: three failures
    /// while the pump is not yet running, then a flood of turn events, then the pump. With the
    /// filter, the buffer holds three failures and one reconnect fires. Without it, the
    /// failures are the oldest of two hundred and three events in a 64-slot buffer, so they
    /// are gone before anything reads them.
    ///
    /// An earlier version of this test flooded *first* and asserted that nothing changed. It
    /// could not fail: `handle(_:recovering:)` ignores turn events too, and with the pump
    /// draining continuously nothing was ever evicted. Removing the door filter left it green.
    ///
    /// **Mutation:** in `schedulerDidObserve(_:)`, yield every event rather than only the two
    /// outcome cases. Run: red.
    @Test("Turn events are dropped before they can evict what is counted")
    func turnEventsNeverDisplaceAnOutcome() async throws {
        let recovery = RecordingReconnector()
        let health = ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))

        for _ in 0..<3 {
            health.schedulerDidObserve(Self.failure())
        }
        for _ in 0..<200 {
            health.schedulerDidObserve(.turnEnded(priority: .snapshot))
        }

        await health.start(recovering: recovery)
        await yieldUntil("the buffered failures to be handled") {
            await health.observedOutcomes == 3
        }

        #expect(
            await recovery.attempts == 1,
            "turn events displaced the outcomes this observer exists to count")
        await health.stop()
    }
}

// MARK: - Doubles

/// Counts reconnects, and can be told to fail them.
actor RecordingReconnector: SMCConnectionRecovering {

    private(set) var attempts = 0
    private let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    func reconnect() async throws {
        attempts += 1
        if failing { throw FakeProviderError(description: "the SMC did not come back") }
    }
}

/// A reconnector that parks inside its first attempt until the test lets it go.
///
/// It exists so a test can put the pump to sleep on purpose. `ConnectionHealth.handle` has
/// exactly one suspension point — `attemptReconnect` — so this is the only way to hold the
/// pump still while the event buffer is deliberately overflowed, which is what
/// `anEvictedOutcomeIsNoticed` needs and what nothing else could arrange.
actor HoldingReconnector: SMCConnectionRecovering {

    private(set) var attempts = 0
    private(set) var isHolding = false

    private var isHeld = true
    private var waiter: CheckedContinuation<Void, Never>?

    func reconnect() async throws {
        attempts += 1
        guard isHeld else { return }
        isHolding = true
        await withCheckedContinuation { waiter = $0 }
        isHolding = false
    }

    /// Lets the parked attempt finish, and waves every later one straight through.
    func release() {
        isHeld = false
        guard let parked = waiter else { return }
        waiter = nil
        parked.resume()
    }
}
