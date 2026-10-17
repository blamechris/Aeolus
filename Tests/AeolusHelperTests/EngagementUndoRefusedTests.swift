import AeolusXPC
import Foundation
import Testing

@testable import AeolusHelper

/// The engagement driver's refused undo, said as `EngagementUndoRefused`, and every router reading
/// its cause ([#406](https://github.com/blamechris/Aeolus/issues/406),
/// [ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s #410 refused-hand-back amendment):
/// the driver wraps only a refused undo, § 5's re-assert routes the cause exactly as it routed an
/// unwrapped error, and level 6's answer table answers a wrapper by its cause.
///
/// Level 6's keeping of the fan the wrapper names is `LeaseApplierKeptFanTests`'. Each test names
/// the mutation it kills, and each was run.
@Suite("A refused undo is said, and routed by its cause", .timeLimit(.minutes(1)))
struct EngagementUndoRefusedTests {

    /// What the driver says at `.fault` when its undo is refused.
    static let undoRefused = "Could not undo the engagement of fan 0"

    /// Whether `error` is the plane's refusal of a first step of `fan`'s that failed before it
    /// issued any write.
    static func failedBeforeFirstWrite(_ error: (any Error)?, fan: Int) -> Bool {
        guard case .failedBeforeFirstWrite(let index, _)? = error as? FanControlPlaneError else {
            return false
        }
        return index == fan
    }

    // MARK: - The driver (H6)

    /// **Only a refused undo is wrapped.** Three refusals of one engagement each: § 3 latching
    /// after the write with the undo then refused, which throws the wrapper carrying the latch's
    /// own refusal; a yield that never arrives, whose undo lands, which throws the bare refusal;
    /// and a fan already in manual, refused before anything is written, which throws the bare
    /// refusal.
    ///
    /// **Mutation (always wrap):** in `EngagementDriver.engageManualControl(of:)`, throw
    /// `EngagementUndoRefused(fan: index, cause: error)` from both of the `catch`'s `throw`s. Run:
    /// red on the landed undo and on the refusal that wrote nothing. **Mutation (never wrap):**
    /// throw `error` whatever the aftermath. Run: red on the refused undo.
    @Test("The driver wraps only a refused undo, carrying exactly what it threw before")
    func theDriverWrapsOnlyARefusedUndo() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [.nominal(), .nominal(writes: .refused(reason: "firmware said no"))])
        let interfering = InterferingFanStateSensing(plane, during: .engageWrite)
        let refusedUndo = try await EngagementRig(plane: plane, writes: interfering)
        await interfering.interfere {
            await refusedUndo.engageThermalEmergency()
            await plane.advance()
        }
        let wrapped = await LeaseApplierAnswerTests.answer {
            try await refusedUndo.driver.engageManualControl(of: refusedUndo.fan(0))
        }
        #expect(await interfering.didFire, "the scenario never arranged the interleaving")
        let refusal = try #require(
            wrapped as? EngagementUndoRefused, "a refused undo threw \(wrapped as Any)")
        #expect(refusal.fan == 0)
        #expect(
            refusal.cause as? EngagementRefusal == .preempted(fan: 0, by: .thermalEmergency),
            "the wrapper carries \(refusal.cause), not the step's own refusal")
        #expect(refusedUndo.log.faults.contains { $0.contains(Self.undoRefused) })

        let landed = try await EngagementRig(unlock: .neverYields)
        let undone = await LeaseApplierAnswerTests.answer {
            try await landed.driver.engageManualControl(of: landed.fan(0))
        }
        #expect(
            undone as? EngagementRefusal == .yieldDidNotArrive(fan: 0, steps: 35),
            "an undo that landed threw \(undone as Any)")
        #expect(await landed.plane.keyWrites.last == .forceKey(0), "the undo did not land")

        let foreign = try await EngagementRig(unlock: .naive)
        await foreign.plane.setMode(.manual, ofFan: 0)
        let nothingWritten = await LeaseApplierAnswerTests.answer {
            try await foreign.driver.engageManualControl(of: foreign.fan(0))
        }
        #expect(
            nothingWritten as? FanControlPlaneError == .notAutomatic(index: 0, rawMode: 1),
            "a refusal that wrote nothing threw \(nothingWritten as Any)")
        #expect(await foreign.plane.keyWrites.isEmpty)
    }

    /// **A first step that could not read its fan is not undone.** The fan's `F0Md` does not
    /// answer, so the engagement's first step fails before it issues any write and says so, as
    /// `.failedBeforeFirstWrite`. The driver throws it bare: no restore is requested, § 3 is not
    /// told of the fan, and the refusal's line says nothing was written. Writing `F0Md = 0` to a
    /// fan whose mode was never read would be ADR 0011's contest (ADR 0014's #410 refused-hand-back
    /// amendment).
    ///
    /// **Mutation:** drop `.failedBeforeFirstWrite` from `EngagementDriver.wroteNothing`. Run: red,
    /// the fan restored and registered with § 3, and the line saying it was handed back.
    @Test("A first step that could not read its fan is refused bare, with nothing undone")
    func aFirstStepThatCouldNotReadItsFanIsNotUndone() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal], stages: [ScriptedControlPlane.Stage(unreadableModes: [0])])
        let rig = try await EngagementRig(
            plane: plane, writes: InterferingFanStateSensing(plane, during: .restoreWrite))

        let refused = await LeaseApplierAnswerTests.answer {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(
            Self.failedBeforeFirstWrite(refused, fan: 0),
            "a first step that could not read its fan threw \(refused as Any)")
        #expect(
            await plane.attempts.contains(.restoreToAutomatic(.fan(0))) == false,
            "the driver restored a fan whose mode it never read")
        #expect(await rig.registry.engaged.isEmpty, "§ 3 was told of a fan nothing wrote to")
        let refusal = rig.log.lines(containing: "The engagement of fan 0 was refused")
        #expect(refusal.count == 1)
        #expect(
            refusal.allSatisfy { $0.contains("Nothing was written.") },
            "the refusal's line said: \(refusal)")
    }

    // MARK: - § 5 (H7)

    /// **(a) A cause that yields the fan hands it back.** § 5 re-engages a reclaimed fan; its mode
    /// write lands, then the lease ends and the firmware stops taking writes, so the driver's
    /// after-check refuses with `.leaseNotLive` and its undo is refused. § 5 reads the cause: the
    /// fan is no longer its own, so it is handed back through `restoreAndForget` — a second
    /// `.fan(0)` restore and the yield line — and not recorded as a failed re-engage.
    ///
    /// **Mutation:** in `ReclamationWatchdog.reassert`, engage through
    /// `driver.engageManualControl(of: permit)` directly, without `throwingTheCause`. Run: red, the
    /// `.fault` re-engage line, the record kept and one restore.
    @Test("A re-engage whose undo was refused with a yielding cause hands the fan back")
    func aReEngageWhoseUndoIsRefusedRoutesByItsCause() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)],
            stages: [.nominal(), .nominal(writes: .refused(reason: "F0Md refused"))])
        let sensing = InterferingFanStateSensing(plane, during: .engageWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [machine] in
            await machine.endLease()
            await machine.plane.advance()
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(machine.safetyLog.levels(containing: Self.undoRefused) == [.fault])
        #expect(
            machine.safetyLog.lines(containing: "re-assert of fan 0 was refused").count == 1,
            "§ 5 did not route the wrapper's cause as the yield it is")
        #expect(
            machine.safetyLog.lines(containing: "could not re-engage manual control of fan 0")
                .isEmpty)
        #expect(
            await machine.attempts.filter { $0 == .restoreToAutomatic(.fan(0)) }.count == 2,
            "restoreAndForget did not hand the fan back after the driver's refused undo")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    /// **(b) Any other cause is a refused re-engage, attempt spent.** § 5 re-engages a reclaimed
    /// fan whose yield never arrives, and the firmware stops taking writes after the last step, so
    /// the driver's undo of `.yieldDidNotArrive` is refused. § 5 reads the cause: the `.fault`
    /// re-engage line, the record kept, and the attempt spent — so the next re-assert is the
    /// second of the budget.
    ///
    /// **Mutation:** make `EngagementRefusal.yieldsTheFan` true for `.yieldDidNotArrive`. Run: red,
    /// the fan handed back and the record gone.
    @Test("A re-engage whose undo was refused with any other cause spends the attempt")
    func aReEngageWhoseUndoIsRefusedWithAnotherCauseSpendsTheAttempt() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)],
            stages: [
                .nominal(), .nominal(writes: .refused(reason: "F0Md refused")), .nominal(),
            ],
            unlock: .neverYields)
        let sensing = InterferingFanStateSensing(plane, during: .engageWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        // The 35th step is the budget's last: the firmware stops taking writes once it returns,
        // and before the undo.
        await sensing.interfere(beforeEngageStep: 35) {
            await sensing.interfere { await plane.advance() }
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(machine.safetyLog.levels(containing: Self.undoRefused) == [.fault])
        let reengage = machine.safetyLog.lines(
            containing: "could not re-engage manual control of fan 0")
        #expect(reengage.count == 1, "§ 5 did not route the cause as a refused re-engage")
        #expect(reengage.allSatisfy { $0.contains("yieldDidNotArrive(fan: 0, steps: 35)") })
        #expect(machine.safetyLog.lines(containing: "re-assert of fan 0 was refused").isEmpty)
        #expect(await machine.watchdog.fansUnderManualControl == [0], "§ 5 gave the fan up")

        await plane.advance()
        await plane.setMode(.manual, ofFan: 0)
        await machine.watchdog.cycle()

        #expect(
            machine.safetyLog.lines(containing: "re-asserted 2400 RPM, attempt 2 of").count == 1,
            "the refused re-engage's attempt was not spent")
    }

    // MARK: - Level 6's answer (H8)

    /// **The table answers a wrapper by its cause.** Level 6's step throws the driver's refusal as
    /// it came, so a refused undo reaches the table as the wrapper (ADR 0014's #410
    /// refused-hand-back amendment); `aDriverUndoRefusedOnFanOneKeepsFanOnesAccount` holds the arm
    /// through `apply`.
    ///
    /// **Mutation:** delete `LeaseApplyRules.answer(to:)`'s first arm. Run: red, every wrapper
    /// answered `helperFailed` with `Detail.unexpected`.
    @Test("Level 6's table answers a wrapper as it answers the cause")
    func theAnswerReadsTheCause() {
        let causes: [any Error] = [
            EngagementRefusal.yieldDidNotArrive(fan: 0, steps: 35),
            EngagementRefusal.leaseNotLive(fan: 0),
            EngagementRefusal.preempted(fan: 0, by: .thermalEmergency),
            FanControlPlaneError.supersededAfterWrite,
            FanControlPlaneError.engagementNotConfirmed(index: 0, rawMode: 0),
            FanControlPlaneError.firmwareRefusedControl(detail: "no"),
            CancellationError(),
        ]
        for cause in causes {
            #expect(
                LeaseApplyRules.answer(to: EngagementUndoRefused(fan: 0, cause: cause))
                    == LeaseApplyRules.answer(to: cause),
                "\(cause)")
        }
    }

    /// **`apply` answers a refused undo by its cause, even a cancellation.** Fan 0's engagement is
    /// cancelled while it waits for its yield, and the firmware then refuses the driver's undo, so
    /// the driver throws the wrapper around a `CancellationError`: a cause the table answers
    /// `.unchanged`. `refusal(for:)` returns the cause, so what leaves `apply` is the cancellation
    /// and never the wrapper.
    ///
    /// **Mutation:** in `LeaseApplier.refusal(for:)`, return the raw error from the `.unchanged`
    /// arm. Run: red, the wrapper itself thrown out of `apply`.
    @Test("apply answers a refused undo by its cause, even a cancellation")
    func applyAnswersARefusedUndoByItsCauseEvenACancellation() async throws {
        let fans: [Int: ScriptedControlPlane.FanCondition] = [0: .automatic(at: 1_800)]
        let plane = ScriptedControlPlane(
            fans: fans,
            stages: [.nominal(), .nominal(writes: .refused(reason: "F0Md refused")), .nominal()],
            unlock: .heldUntilForced(stepsToYield: 2))
        let machine = ReclamationMachine(plane: plane, fans: fans)
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(plane, during: .engageWrite)
        await writes.interfere {
            await plane.advance()
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let levelSix = machine.levelSix(writingThrough: writes)

        let answered = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }

        #expect(await writes.didFire, "the engagement was never cancelled")
        #expect(machine.safetyLog.levels(containing: Self.undoRefused) == [.fault])
        #expect(answered is CancellationError, "apply answered \(answered as Any)")
        #expect(answered is EngagementUndoRefused == false, "the wrapper left apply")
    }
}
