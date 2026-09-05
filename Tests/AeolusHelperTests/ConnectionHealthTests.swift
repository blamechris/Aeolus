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
