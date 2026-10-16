import Testing

@testable import AeolusHelper

/// `FanExaminationGateTests`' cases about § 5's bound itself: what it must outlast, and what ends
/// a wait whose clock fails. An extension of the same suite, in a file of its own so the suite's
/// body stays under `type_body_length`, on the suite's own `ManualClock`, `gate(_:log:)`,
/// `settle()` and `expectNothingLeft(_:on:)`.
extension FanExaminationGateTests {

    /// **§ 5's bound outlasts a lawful hold by a step queued ahead of it.** Step A holds fan 0's
    /// gate and step B waits behind it; § 5 arrives 0.05 s later. A leaves at 0.95 s, inside B's
    /// `stepWait`, so B is granted then and may hold for as long as A6's contract lets a step
    /// hold, 13.5 s, to 14.45 s. § 5 is still waiting at that instant, says nothing, and is
    /// granted when B leaves: its bound, from 0.05 s, runs to 14.55 s. With the bound A6's first
    /// change had, 13.5 s with no `stepWait` in it, § 5 ran out at 13.55 s and examined without
    /// the gate inside a lawful step, logging a contract breach that was not one.
    ///
    /// **Mutation:** drop `+ stepWait` from `examinationWait`. Run: red on "ran out inside B's
    /// lawful hold", and in `theBoundsAreDerived`.
    @Test("§ 5's wait outlasts a lawful hold by a step that queued ahead of it")
    func theBoundCoversAStepQueuedAhead() async throws {
        let clock = ManualClock()
        let log = RecordedLog()
        let gate = Self.gate(clock, log: log)
        let lawfulHold = UnlockLimits.yieldBudget + WatchdogLimits.roundTrip * 2

        let stepA = try #require(await gate.enterForStep(fanAt: 0))
        let stepB = observing { await gate.enterForStep(fanAt: 0) }
        #expect(await yieldUntil("step B's timer") { clock.sleepers == 1 })
        clock.advance(by: .milliseconds(50))
        let examination = observing { await gate.enterForExamination(fanAt: 0) }
        #expect(await yieldUntil("§ 5's timer, behind B") { clock.sleepers == 2 })
        clock.advance(by: .milliseconds(900))
        gate.leave(stepA)
        let grantedB = try await finished("step B's grant, inside its stepWait", stepB)
        let passB = try #require(grantedB.flatMap { $0 }, "step B was refused inside its stepWait")
        #expect(await yieldUntil("step B's timer to end") { clock.sleepers == 1 })

        clock.advance(by: lawfulHold)
        await Self.settle()
        #expect(
            await examination.isFinished.isSet == false,
            "§ 5's wait ran out inside B's lawful hold")
        #expect(log.lines(containing: "examination gate").isEmpty, "a lawful hold was a breach")
        gate.leave(passB)
        let granted = try #require(try await finished("§ 5's grant once B left", examination))
        #expect(granted.isHeld && !granted.isPastTheBound)
        gate.leave(granted)
        await Self.expectNothingLeft(gate, on: clock)
    }

    /// A clock whose sleep fails for any reason but cancellation ends the wait as the bound would:
    /// § 5's examination is past the bound and level 6's step is refused, and neither is left
    /// waiting for a grant that may never come.
    ///
    /// **Mutation:** in `wait(_:fanAt:within:)`, have the timer's `catch` only `return`. Run: red
    /// on both waits ending, which never do.
    @Test("A clock that fails ends the wait as the bound would")
    func aClockThatFailsEndsTheWait() async throws {
        let log = RecordedLog()
        let gate = FanExaminationGate(
            clock: FailingClock(), log: SafetyLog(recording: { log.append($0, $1) }))
        let holder = try #require(await gate.enterForStep(fanAt: 0))

        let examination = try await finished(
            "§ 5's wait on a clock that fails",
            observing { await gate.enterForExamination(fanAt: 0) })
        #expect(examination?.isPastTheBound == true, "§ 5's wait did not end as its bound would")
        let step = try await finished(
            "level 6's wait on a clock that fails", observing { await gate.enterForStep(fanAt: 0) })
        #expect(step == .some(nil), "a step was given a pass on a clock that failed")
        gate.leave(holder)
        #expect(gate.isIdle)
    }
}

/// A `MonotonicClock` whose sleep fails at once, with an error that is not cancellation.
private struct FailingClock: MonotonicClock {
    struct Failure: Error {}

    let now = ContinuousClock.now

    func sleep(until deadline: ContinuousClock.Instant) async throws { throw Failure() }
}
