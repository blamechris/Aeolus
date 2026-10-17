import Testing

@testable import AeolusHelper

/// `FanExaminationGateTests`' cases about § 5's bound itself: what it must outlast, the margin
/// included, and what ends a wait whose clock fails. An extension of the same suite, in a file of
/// its own so the suite's body stays under `type_body_length`, on the suite's own `ManualClock`,
/// `gate(_:log:)`, `settle()` and `expectNothingLeft(_:on:)`.
extension FanExaminationGateTests {

    /// **§ 5's bound outlasts a lawful hold by a step queued ahead of it.** Step A holds fan 0's
    /// gate and step B waits behind it; § 5 arrives 0.05 s later. A leaves at 0.95 s, inside B's
    /// `stepWait`, so B is granted then and may hold for `FanExaminationGate.lawfulHold`, as long
    /// as A6's contract lets a step hold, to 30.95 s. § 5 is still waiting at that instant, says
    /// nothing, and is granted when B leaves: its bound, from 0.05 s, runs to 32.05 s. With no
    /// `stepWait` in the bound, § 5 ran out 0.95 s inside B's lawful hold.
    ///
    /// **Mutation:** drop `stepWait` and `examinationMargin` from `examinationWait`. Run: red on
    /// "ran out inside B's lawful hold", and in `theBoundsAreDerived`.
    @Test("§ 5's wait outlasts a lawful hold by a step that queued ahead of it")
    func theBoundCoversAStepQueuedAhead() async throws {
        let clock = ManualClock()
        let log = RecordedLog()
        let gate = Self.gate(clock, log: log)
        let lawfulHold = FanExaminationGate.lawfulHold

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

    /// **§ 5's bound outlasts the worst lawful path: a step granted at the instant its own wait
    /// ran out, then holding three turns** (ADR 0014's A6 PR-2 amendment). Step A holds fan 0's
    /// gate, and step B and § 5 queue behind it at the same instant. A leaves at the exact instant
    /// B's `stepWait` ends, before B's timer has run, so the grant wins that tie. B then holds its
    /// worst path, three turns each taken at G: a first step superseded at its admission, its one
    /// retry, and the driver's undo, `FanExaminationGate.lawfulHold` in all, to 31 s after § 5
    /// arrived. With no margin § 5's bound ran out at that same instant: one `.fault`, and one
    /// examination without the gate inside a lawful hold. With `examinationMargin`, § 5 is still
    /// waiting then, says nothing, and is granted when B leaves.
    ///
    /// **Mutation:** set `examinationMargin` to `.zero`. Run: red on "ran out at the instant B's
    /// lawful hold ended", and on the breach line.
    @Test("§ 5's wait outlasts a step granted at the instant its own wait ran out")
    func theBoundCoversAStepGrantedAtTheEndOfItsWait() async throws {
        let clock = ManualClock()
        let log = RecordedLog()
        let gate = Self.gate(clock, log: log)
        let lawfulHold = FanExaminationGate.lawfulHold

        let stepA = try #require(await gate.enterForStep(fanAt: 0))
        let stepB = observing { await gate.enterForStep(fanAt: 0) }
        #expect(await yieldUntil("step B's timer") { clock.sleepers == 1 })
        let examination = observing { await gate.enterForExamination(fanAt: 0) }
        #expect(await yieldUntil("§ 5's timer, at B's instant") { clock.sleepers == 2 })

        // B's wait runs out now, and no timer has run: A leaving grants B first.
        clock.move(by: FanExaminationGate.stepWait)
        gate.leave(stepA)
        let grantedB = try await finished("step B's grant, at the end of its stepWait", stepB)
        let passB = try #require(grantedB.flatMap { $0 }, "the tie went to B's timer")
        #expect(await yieldUntil("step B's timer to end") { clock.sleepers == 1 })

        let turn = WatchdogLimits.gateWaiterAlarm
        #expect(turn * 3 == lawfulHold, "the worst path is no longer three turns at G")
        for _ in 1...3 { clock.advance(by: turn) }
        await Self.settle()
        #expect(
            await examination.isFinished.isSet == false,
            "§ 5's wait ran out at the instant B's lawful hold ended")
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
