import AeolusXPCClient
import Testing

@testable import AeolusHelper

/// The examination gate through its waits: exclusion, the per-fan lanes, the order waiters are
/// served in, both bounds to the nanosecond, § 5's bound outlasting a step queued ahead of it, a
/// grant and an expiry at the same instant, a cancelled waiter, a clock that fails, a pass that
/// does not hold, the outwaited holder, and the timers it leaves.
///
/// On `ManualClock`, so a wait ends only when the test moves the hands, grants or cancels, and a
/// bound is checked exactly. Each test ends by asserting the gate is idle and no timer is left
/// sleeping, which is the gate prototype's second gap: a timer the gate cancels must not stay
/// parked. **Mutation:** in `wait(_:fanAt:within:)`, delete `defer { timer.cancel() }`. Run: red
/// at `expectNothingLeft` in every test whose wait ended before its bound. The bookkeeping alone,
/// every interleaving as a value, is `FanExaminationGateLanesTests`.
@Suite("The examination gate", .timeLimit(.minutes(1)))
struct FanExaminationGateTests {

    static func gate(
        _ clock: ManualClock, log: RecordedLog = RecordedLog()
    ) -> FanExaminationGate {
        FanExaminationGate(clock: clock, log: SafetyLog(recording: { log.append($0, $1) }))
    }

    /// Gives every task the gate or the clock just resumed a chance to run, for the assertions
    /// that something did *not* happen.
    static func settle() async {
        for _ in 0..<500 { await Task.yield() }
    }

    /// The gate is idle and no timer is left on the clock.
    static func expectNothingLeft(
        _ gate: FanExaminationGate, on clock: ManualClock,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        #expect(
            gate.isIdle, "the gate kept a lane, a parked waiter or a decision",
            sourceLocation: sourceLocation)
        #expect(
            await yieldUntil(
                "every wait's timer to end", { clock.sleepers == 0 },
                sourceLocation: sourceLocation),
            "a wait's timer was left sleeping", sourceLocation: sourceLocation)
    }

    // MARK: - Exclusion and order

    /// A held gate makes the next entrant wait, and leaving grants it.
    ///
    /// **Mutation:** in `leave(_:)`, delete `next?.resume(returning: .granted)`. Run: red on the
    /// grant, which never comes.
    @Test("A held gate makes the next entrant wait until it is left")
    func aHeldGateIsExclusive() async throws {
        let clock = ManualClock()
        let gate = Self.gate(clock)
        let holder = try #require(await gate.enterForStep(fanAt: 0))
        let next = observing { await gate.enterForExamination(fanAt: 0) }
        #expect(await yieldUntil("the examination to wait") { gate.waiting(onFan: 0) == 1 })
        await Self.settle()
        #expect(await next.isFinished.isSet == false, "two held fan 0's gate at once")

        gate.leave(holder)
        let granted = try #require(try await finished("the examination's grant", next))
        #expect(granted.isHeld && !granted.isPastTheBound)
        gate.leave(granted)
        await Self.expectNothingLeft(gate, on: clock)
    }

    /// One fan's held gate does not hold another's.
    ///
    /// **Mutation:** in `enter(fanAt:as:within:)`, arrive at fan 0 whatever `fan` is. Run: red on
    /// fan 1's grant.
    @Test("Each fan's gate is its own")
    func eachFanIsIndependent() async throws {
        let clock = ManualClock()
        let gate = Self.gate(clock)
        let fanZero = try #require(await gate.enterForStep(fanAt: 0))
        let fanOne = observing { await gate.enterForExamination(fanAt: 1) }
        let granted = try await finished("fan 1's grant", fanOne)
        #expect(granted?.isHeld == true, "fan 1 waited on fan 0")
        if let granted { gate.leave(granted) }
        gate.leave(fanZero)
        await Self.expectNothingLeft(gate, on: clock)
    }

    /// Waiters are granted in the order they arrived: an examination before a later step.
    ///
    /// **Mutation:** in `Lanes.leave(_:fanAt:)`, serve the newest waiter. Run: red on the first
    /// grant.
    @Test("Waiters are granted in the order they arrived, across both parties")
    func waitersAreGrantedInOrder() async throws {
        let clock = ManualClock()
        let gate = Self.gate(clock)
        let holder = try #require(await gate.enterForStep(fanAt: 0))
        let examination = observing { await gate.enterForExamination(fanAt: 0) }
        #expect(await yieldUntil("the examination to wait") { gate.waiting(onFan: 0) == 1 })
        let step = observing { await gate.enterForStep(fanAt: 0) }
        #expect(await yieldUntil("the step to wait") { gate.waiting(onFan: 0) == 2 })

        gate.leave(holder)
        await Self.settle()
        #expect(await step.isFinished.isSet == false, "the later step was granted first")
        let first = try #require(try await finished("the examination's grant", examination))
        #expect(first.isHeld, "the examination that arrived first was not granted first")
        gate.leave(first)
        let second = try await finished("the step's grant", step)
        #expect(second??.isHeld == true, "the step was not granted once the examination left")
        if case let pass?? = second { gate.leave(pass) }
        await Self.expectNothingLeft(gate, on: clock)
    }

    // MARK: - The bounds

    /// § 5's wait runs out at `examinationWait` exactly, and level 6's at `stepWait`: a
    /// nanosecond short, each is still waiting. § 5's says so once, at `.fault`.
    ///
    /// **Mutation:** in `wait(_:fanAt:within:)`, `let deadline = clock.now + bound +
    /// .nanoseconds(1)`. Run: red on § 5's expiry, where the `#require` ends the test. With
    /// `- .nanoseconds(1)`: red on both waits a nanosecond short.
    @Test("Each wait runs out at its bound, to the nanosecond")
    func eachWaitRunsOutAtItsBound() async throws {
        let clock = ManualClock()
        let log = RecordedLog()
        let gate = Self.gate(clock, log: log)
        let holder = try #require(await gate.enterForStep(fanAt: 0))

        let examination = observing { await gate.enterForExamination(fanAt: 0) }
        #expect(await yieldUntil("the examination's timer") { clock.sleepers == 1 })
        clock.advance(by: FanExaminationGate.examinationWait - .nanoseconds(1))
        await Self.settle()
        #expect(await examination.isFinished.isSet == false, "§ 5's wait ran out early")
        clock.advance(by: .nanoseconds(1))
        let pastTheBound = try #require(try await finished("§ 5's expiry", examination))
        #expect(pastTheBound.isPastTheBound && !pastTheBound.isHeld)
        #expect(log.levels(containing: "for fan 0's examination gate") == [.fault])

        gate.leave(holder)
        let next = try #require(await gate.enterForStep(fanAt: 0))
        let step = observing { await gate.enterForStep(fanAt: 0) }
        #expect(await yieldUntil("the step's timer") { clock.sleepers == 1 })
        clock.advance(by: FanExaminationGate.stepWait - .nanoseconds(1))
        await Self.settle()
        #expect(await step.isFinished.isSet == false, "level 6's wait ran out early")
        clock.advance(by: .nanoseconds(1))
        let refused = try await finished("level 6's expiry", step)
        #expect(refused == .some(nil), "a step past its bound was given a pass")
        #expect(log.lines(containing: "examination gate").count == 1, "a step's expiry said so")
        gate.leave(next)
        await Self.expectNothingLeft(gate, on: clock)
    }

    /// The instant the bound arrives, a grant that reaches the gate before the timer wins, and
    /// the timer's expiry then changes nothing; the other way round, the expiry wins and the
    /// leave grants nobody. `move(by:)` brings the instant without running the timer, so the
    /// order is the test's.
    ///
    /// **Mutation:** decide by the clock after the wait instead of under the lock — in
    /// `wait(_:fanAt:within:)`, return `.expired` when `clock.now >= deadline` whatever the
    /// continuation said. Run: red on the first grant, and the lane is left held by a pass that
    /// says it does not hold.
    @Test("A grant and an expiry at the same instant are decided once")
    func aGrantAndAnExpiryAtTheSameInstantAreDecidedOnce() async throws {
        let clock = ManualClock()
        let gate = Self.gate(clock)

        let holder = try #require(await gate.enterForStep(fanAt: 0))
        let waiter = observing { await gate.enterForStep(fanAt: 0) }
        #expect(await yieldUntil("the step's timer") { clock.sleepers == 1 })
        clock.move(by: FanExaminationGate.stepWait)
        gate.leave(holder)
        clock.endDueSleeps()
        let granted = try await finished("the grant at the bound", waiter)
        #expect(granted??.isHeld == true, "the grant that came first was undone by the bound")
        #expect(gate.isHeld(fanAt: 0), "the gate is held by nobody who knows it")
        if case let pass?? = granted { gate.leave(pass) }
        await Self.expectNothingLeft(gate, on: clock)

        let incumbent = try #require(await gate.enterForStep(fanAt: 0))
        let late = observing { await gate.enterForStep(fanAt: 0) }
        #expect(await yieldUntil("the step's timer") { clock.sleepers == 1 })
        clock.advance(by: FanExaminationGate.stepWait)
        let expired = try await finished("the expiry at the bound", late)
        #expect(expired == .some(nil), "a step whose wait ran out was given a pass")
        gate.leave(incumbent)
        #expect(gate.isHeld(fanAt: 0) == false, "the leave granted the expired step")
        await Self.expectNothingLeft(gate, on: clock)
    }

    // MARK: - Cancellation

    /// A waiter whose task is cancelled returns at once, holding nothing and not past the bound,
    /// and is never granted: the holder's leave finds nobody waiting. One cancelled before it
    /// arrives does not wait at all.
    ///
    /// **Mutation:** in `wait(_:fanAt:within:)`, make the cancellation handler do nothing. Run:
    /// red on "at once"; the cancelled waiter is granted when the holder leaves.
    @Test("A cancelled waiter returns at once and is never granted")
    func aCancelledWaiterIsNeverGranted() async throws {
        let clock = ManualClock()
        let gate = Self.gate(clock)
        let holder = try #require(await gate.enterForStep(fanAt: 0))

        let waiter = observing { await gate.enterForExamination(fanAt: 0) }
        #expect(await yieldUntil("the examination to wait") { gate.waiting(onFan: 0) == 1 })
        waiter.task.cancel()
        let withdrawn = try await finished("the cancelled wait", waiter)
        #expect(withdrawn?.isHeld == false, "a cancelled waiter holds the gate")
        #expect(withdrawn?.isPastTheBound == false, "a cancelled wait was taken for an expiry")

        let early = observing {
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.enterForStep(fanAt: 0)
        }
        let refused = try await finished("the wait cancelled before it began", early)
        #expect(refused == .some(nil))

        gate.leave(holder)
        #expect(gate.isHeld(fanAt: 0) == false, "the holder's leave granted a cancelled waiter")
        await Self.expectNothingLeft(gate, on: clock)
    }

    /// **The gate prototype's first gap, through the waits.** A wait that ran out and whose task
    /// is then cancelled leaves nothing behind. `FanExaminationGateLanesTests` drives the
    /// interleaving the prototype leaked on deterministically; this checks the gate's own
    /// plumbing keeps nothing either.
    @Test("A wait cancelled after it ran out leaves nothing behind")
    func aWaitCancelledAfterItRanOutLeavesNothing() async throws {
        let clock = ManualClock()
        let gate = Self.gate(clock)
        let holder = try #require(await gate.enterForStep(fanAt: 0))
        let waiter = observing { await gate.enterForStep(fanAt: 0) }
        #expect(await yieldUntil("the step's timer") { clock.sleepers == 1 })
        clock.advance(by: FanExaminationGate.stepWait)
        waiter.task.cancel()
        let ended = try await finished("the wait", waiter)
        #expect(ended == .some(nil))
        gate.leave(holder)
        await Self.expectNothingLeft(gate, on: clock)
    }

    // MARK: - Leaving

    /// A pass that does not hold releases nothing, and leaving a held pass twice releases only
    /// once.
    ///
    /// **Mutation:** in `Lanes.leave(_:fanAt:)`, drop `lane.holder == ticket` from the `guard`.
    /// Run: red on both.
    @Test("Leaving a pass that does not hold, or leaving twice, releases nothing")
    func leavingWithoutHoldingReleasesNothing() async throws {
        let clock = ManualClock()
        let gate = Self.gate(clock)
        let holder = try #require(await gate.enterForStep(fanAt: 0))
        let examination = observing { await gate.enterForExamination(fanAt: 0) }
        #expect(await yieldUntil("the examination's timer") { clock.sleepers == 1 })
        clock.advance(by: FanExaminationGate.examinationWait)
        let unheld = try #require(try await finished("the examination's expiry", examination))
        #expect(unheld.isHeld == false)

        gate.leave(unheld)
        #expect(gate.isHeld(fanAt: 0), "a pass that held nothing released the holder")

        let next = observing { await gate.enterForStep(fanAt: 0) }
        #expect(await yieldUntil("the step to wait") { gate.waiting(onFan: 0) == 1 })
        gate.leave(holder)
        let granted = try #require(try await finished("the step's grant", next))
        gate.leave(holder)
        #expect(gate.isHeld(fanAt: 0), "a second leave released the next holder")
        if let granted { gate.leave(granted) }
        await Self.expectNothingLeft(gate, on: clock)
    }

    // MARK: - The outwaited holder

    /// An examination that outwaits a holder records it: the next examination against that holder
    /// returns at once, past the bound, with the clock unmoved and no second line. Once the holder
    /// leaves, an examination is granted again.
    ///
    /// **Mutation:** in `Lanes.withdraw(_:fanAt:because:)`, delete `if outwaits { lane.outwaited =
    /// lane.holder }`. Run: red on "at once".
    @Test("A holder § 5 outwaited once costs later examinations no wait")
    func anOutwaitedHolderCostsNoSecondWait() async throws {
        let clock = ManualClock()
        let log = RecordedLog()
        let gate = Self.gate(clock, log: log)
        let stuck = try #require(await gate.enterForStep(fanAt: 0))
        let first = observing { await gate.enterForExamination(fanAt: 0) }
        #expect(await yieldUntil("the examination's timer") { clock.sleepers == 1 })
        clock.advance(by: FanExaminationGate.examinationWait)
        #expect(try await finished("the first expiry", first)?.isPastTheBound == true)

        let second = observing { await gate.enterForExamination(fanAt: 0) }
        let atOnce = try await finished("the second examination, at once", second)
        #expect(atOnce?.isPastTheBound == true, "the second examination waited on a stuck holder")
        #expect(log.lines(containing: "examination gate").count == 1, "the stuck holder said twice")

        gate.leave(stuck)
        let third = try await finished(
            "an examination after the holder left",
            observing { await gate.enterForExamination(fanAt: 0) })
        #expect(third?.isHeld == true, "the memory outlived the holder it was about")
        if let third { gate.leave(third) }
        await Self.expectNothingLeft(gate, on: clock)
    }

    // MARK: - The bounds' derivation

    /// `examinationWait` is `UnlockLimits.yieldBudget`, two `WatchdogLimits.roundTrip` and
    /// `stepWait`: the longest hold a step may make, after the longest wait a step queued ahead of
    /// § 5 has for its grant. `stepWait` plus the yield budget stays under the client's 5 s
    /// gated-verb deadline. Literals beside the constants, for `ReclamationLimitsTests`' reason: a
    /// bound derived from the constant it checks moves with it.
    @Test("The gate's bounds are derived, and fit the client's deadline")
    func theBoundsAreDerived() {
        #expect(
            FanExaminationGate.examinationWait
                == UnlockLimits.yieldBudget + WatchdogLimits.roundTrip * 2
                + FanExaminationGate.stepWait)
        #expect(FanExaminationGate.examinationWait == .milliseconds(14_500))
        #expect(FanExaminationGate.stepWait == .seconds(1))
        #expect(UnlockLimits.yieldBudget + FanExaminationGate.stepWait < .seconds(5))
        #expect(
            UnlockLimits.yieldBudget + FanExaminationGate.stepWait
                < HelperClientDeadlines.gatedVerb)
    }
}
