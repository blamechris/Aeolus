import AeolusXPC
import FanKit
import Testing

@testable import AeolusHelper

/// [#295](https://github.com/blamechris/Aeolus/issues/295), through the **composed** helper:
/// a fan whose handback the firmware *accepted* stays in § 3's registry until § 3's own cycle
/// reads it automatic, and the read that decides it is never on a keystone's path.
///
/// Composed for `HelperRestorerTests`' reason: the defect is wiring — which reader § 3 was
/// handed, and which caller takes the read — so the graph under test is the one
/// `HelperComposition` builds, over `ControlStateGatePlane` so a mode read can be parked or
/// made to throw while § 3 keeps reading its critical temperatures. The supervisors are not
/// started; every § 3 cycle below is driven by hand.
@Suite("Accepted handbacks, read back by § 3, composed", .timeLimit(.minutes(1)))
struct AcceptedHandbackCompositionTests {

    /// Fan 0 automatic under nominal die temperatures, with `writes` as the firmware's answer
    /// to every write, then — for a test that advances — the same machine above its ceiling.
    private static func composed(
        writes: ScriptedControlPlane.WriteBehaviour = .honoured,
        log: RecordedLog = RecordedLog()
    ) -> HelperComposition<ControlStateGatePlane> {
        HelperComposition(
            plane: ControlStateGatePlane(
                ScriptedControlPlane(
                    fans: [0: .automatic(at: 2_400)],
                    stages: [
                        .nominal(
                            temperatures: LeaseFixture.nominalDieTemperatures, writes: writes),
                        .at(96, writes: writes),
                    ])),
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { log.append($0, $1) }),
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    /// Registers fan 0 with both registries, takes a lease over it, puts the firmware into
    /// manual as E3's engage write would, and releases the lease — the ordinary teardown.
    ///
    /// The mode write is `setMode`, not the plane's write verb, so it lands whatever the
    /// stage's `WriteBehaviour` says: the scenario is about what the *restore* meets.
    private static func engageThenRelease(
        in helper: HelperComposition<ControlStateGatePlane>
    ) async throws {
        await helper.bindSafetyRegistries()
        try await HelperRestorerTests.engage(fan: 0, in: helper)
        let connection = ConnectionID()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        await helper.plane.wrapped.setMode(.manual, ofFan: 0)
        try await helper.leases.releaseLease(id: lease.id, from: connection)
    }

    // MARK: - Accepted, and still manual

    /// A restore the firmware accepts and discards leaves fan 0 manual, and § 3 keeps it —
    /// cycle after cycle — so the next emergency bridges it to maximum.
    ///
    /// `.reverted` is the firmware #291 is about: the write returns cleanly and nothing
    /// changes. Before #295 the restorer dropped fan 0 from § 3 on that return, and the hot
    /// cycle at the end would have written nothing to it.
    ///
    /// **Mutation:** in `ThermalEmergency.readBackAcceptedHandbacks()`, make the `.manual`
    /// case call `forget(fanAt: fan)` as `.automatic` does. Run: red — fan 0 is gone after
    /// the first cycle and the hot cycle issues no `commandTarget`.
    /// **Mutation:** delete `guard owed.reported.insert(.manual).inserted else { continue }`.
    /// Run: red on the line count — two `.fault` lines for one handback.
    @Test("A fan the firmware accepted but left manual stays bridgeable")
    func anAcceptedButManualFanStaysBridgeable() async throws {
        let log = RecordedLog()
        let helper = Self.composed(writes: .reverted, log: log)
        try await Self.engageThenRelease(in: helper)
        #expect(await helper.plane.restoreAttempts == [.fan(0)], "the handback was never issued")

        await helper.thermalEmergency.cycle()
        await helper.thermalEmergency.cycle()

        #expect(
            await helper.thermalEmergency.fansUnderManualControl == [0],
            "§ 3 forgot a fan that still reads manual after an accepted handback")
        #expect(await helper.thermalEmergency.fansOwedHandbackReadBack == [0])
        let stillManual = log.levels(containing: "still reads manual")
        #expect(
            stillManual == [.fault],
            "one transition, one line: § 3 asks every cycle, and must not log every cycle")

        await helper.plane.wrapped.advance()
        await helper.thermalEmergency.cycle()

        let commanded = await helper.plane.wrapped.attempts.compactMap(\.commandedRPM)
        #expect(
            commanded == [5_777],
            "the emergency did not bridge a fan that was still off automatic control")
        #expect(await helper.thermalEmergency.fansOwedHandbackReadBack.isEmpty)
    }

    /// A fan that stays manual while its read intermittently throws logs "still manual" once.
    ///
    /// Manual, then unreadable, then manual again: the second manual is not news — nothing
    /// was learned about the fan in between — and a last-reported value flapped on exactly this
    /// sequence, writing a `.fault`/`.notice` pair every two cycles for as long as it lasted.
    ///
    /// **Mutation:** revert to the single-value check — replace
    /// `guard owed.reported.insert(.manual).inserted else { continue }` with
    /// `guard owed.reported != [.manual] else { continue }; owed.reported = [.manual]`, and the
    /// `.unreadable` guard likewise with `[.unreadable]`. Run: red on `stillManual == [.fault]`.
    @Test("A manual fan whose read intermittently throws logs still-manual once")
    func anIntermittentlyUnreadableManualFanLogsOnce() async throws {
        let log = RecordedLog()
        let helper = Self.composed(writes: .reverted, log: log)
        try await Self.engageThenRelease(in: helper)

        await helper.thermalEmergency.cycle()
        await helper.plane.modeReads(.failing)
        await helper.thermalEmergency.cycle()
        await helper.plane.modeReads(.answered)
        await helper.thermalEmergency.cycle()
        await helper.plane.modeReads(.failing)
        await helper.thermalEmergency.cycle()

        let stillManual = log.levels(containing: "still reads manual")
        #expect(
            stillManual == [.fault],
            "a fan that never stopped reading manual was reported manual again after one throw")
        #expect(log.levels(containing: "could not be read back after its handback") == [.notice])
        #expect(await helper.thermalEmergency.fansOwedHandbackReadBack == [0])
    }

    // MARK: - Unreadable

    /// A fan owed a read-back whose `F<n>Md` will not read stays registered and owed, and says
    /// so once.
    ///
    /// **Mutation:** in `ThermalEmergency.readBackAcceptedHandbacks()`, make the `.unreadable`
    /// case call `forget(fanAt: fan)`. Run: red — fan 0 leaves the registry on a read that
    /// established nothing.
    @Test("A fan whose read-back throws stays registered and owed")
    func anUnreadableFanStaysOwed() async throws {
        let log = RecordedLog()
        let helper = Self.composed(log: log)
        try await Self.engageThenRelease(in: helper)
        await helper.plane.modeReads(.failing)

        await helper.thermalEmergency.cycle()
        await helper.thermalEmergency.cycle()

        #expect(
            await helper.thermalEmergency.fansUnderManualControl == [0],
            "§ 3 forgot a fan on a read that established nothing about it")
        #expect(await helper.thermalEmergency.fansOwedHandbackReadBack == [0])
        #expect(log.levels(containing: "could not be read back after its handback") == [.notice])
        #expect(
            log.lines(containing: "Fan 0's control state could not be read back after Aeolus")
                .isEmpty,
            "§ 3 went through the lease core's .fault-per-throw read, not its own seam")
    }

    // MARK: - The keystone does not wait on the read

    /// With § 3 parked inside its owed read-back, the restorer — the path § 4's sleep handback
    /// and SIGTERM's teardown await before issuing the machine-wide keystone — still returns,
    /// and its restore write still reaches the firmware.
    ///
    /// The wait is bounded (`finished(_:_:)`), so a restorer that waits on the read is a red
    /// expectation in milliseconds rather than a test killed at the suite's time limit.
    ///
    /// **The firmware reverts every write, and that is what lets the mutation below reach the
    /// assertion it is named for.** With honoured writes, a read moved into the restorer runs
    /// during the setup's release, finds fan 0 automatic and clears it — so the test went red
    /// on its owed-precondition instead, with the bounded wait never exercised. Reverted, fan 0
    /// reads manual throughout, stays owed through any read, and the only thing the mutant can
    /// do differently is park the restorer.
    ///
    /// **Mutation:** move the read inline into the restorer — make
    /// `ThermalEmergency.readBackAcceptedHandbacks()` non-`private` and call
    /// `await thermalEmergency?.readBackAcceptedHandbacks()` after the `handbackAccepted` loop
    /// in `HelperFanRestorer.restoreToAutomatic(fans:because:)`. Run: red — "timed out waiting
    /// for the restorer to return while § 3's read-back is held".
    @Test("The restorer returns while § 3's owed read-back is held")
    func theRestorerDoesNotWaitOnTheReadBack() async throws {
        let helper = Self.composed(writes: .reverted)
        try await Self.engageThenRelease(in: helper)
        #expect(await helper.thermalEmergency.fansOwedHandbackReadBack == [0])

        await helper.plane.modeReads(.held)
        let cycle = observing { await helper.thermalEmergency.cycle() }
        #expect(
            await yieldUntil("§ 3's read-back to park") { await helper.plane.heldModeReads == 1 })

        let restore = observing {
            await helper.restorer.restoreToAutomatic(fans: [0], because: .leaseReleased)
        }
        let abandoned = try await finished(
            "the restorer to return while § 3's read-back is held", restore)

        #expect(abandoned == [], "the firmware accepts every restore in this scenario")
        #expect(
            await helper.plane.restoreAttempts == [.fan(0), .fan(0)],
            "the restore write was not issued while § 3's read-back was held")

        await helper.plane.modeReads(.answered)
        _ = try await finished("§ 3's cycle to finish once the read is let through", cycle)
    }
}
