import FanKit
import Testing

@testable import AeolusHelper

/// § 3's own restore, read back before § 3 lets go of the fan
/// ([#300](https://github.com/blamechris/Aeolus/issues/300)), driven through `ThermalMachine`.
///
/// The firmware under fan 0 is **manual** (`FanCondition.held`), so a restore the firmware
/// discards (`.reverted`) leaves it manual, and one it honours puts it on automatic. Every
/// scenario is two episodes — hot, cool enough to release, one clear cycle that reads back,
/// hot again — and the assertion that matters is what the **second** emergency writes.
///
/// The composed standing-fight guard, where the real restorer's `handbackAccepted` runs, is in
/// `AcceptedHandbackCompositionTests`.
@Suite("The thermal emergency's read-back of its own restores", .timeLimit(.minutes(1)))
struct ThermalEmergencyRestoreTests {

    /// Hot, cool, hot — each stage's firmware answering every write with `writes`.
    private static func machine(
        writes: ScriptedControlPlane.WriteBehaviour
    ) -> ThermalMachine {
        ThermalMachine(
            stages: [.at(96, writes: writes), .at(44, writes: writes), .at(96, writes: writes)],
            fans: [0: .held(at: 2_400)])
    }

    /// Fires, releases, and runs the one clear cycle that reads back. Leaves the plane on the
    /// cool stage, one `advance()` short of the second episode.
    private static func firstEpisode(_ machine: ThermalMachine) async throws {
        try await machine.engageManualControl(fan: 0)
        await machine.emergency.cycle()
        #expect(await machine.emergency.isHolding, "the first episode never fired")
        await machine.plane.advance()
        await machine.emergency.cycle()
        #expect(await !machine.emergency.isHolding, "the first episode never released")
        await machine.emergency.cycle()
    }

    /// Every maximum command fan 0 was sent, in order.
    private static func bridges(_ machine: ThermalMachine) async -> Int {
        await machine.attempts.filter {
            if case .commandTarget(fan: 0, _) = $0 { return true }
            return false
        }.count
    }

    // MARK: - Reverted

    /// A fan § 3 restored that still reads manual is bridged again by the next emergency.
    ///
    /// Before #300 `fire` forgot fan 0 after its restore, whatever the restore did, and nothing
    /// else remembered it — so the second episode wrote nothing to a fan still off automatic.
    ///
    /// **Mutation:** in `ThermalEmergency.fire(_:from:)`, bridge `engagedFans` only —
    /// `let held = engagedFans.values.sorted { $0.index < $1.index }`. Run: red — one bridge.
    /// **Mutation:** in `fire(_:from:)`, call `forget(fanAt: fan.index)` in place of
    /// `restoredByEmergency(fan)`. Run: red — the register is empty and there is one bridge.
    @Test("A fan still manual after § 3's restore is bridged by the next emergency")
    func aRestoredButManualFanIsBridgedNextEpisode() async throws {
        let machine = Self.machine(writes: .reverted)
        try await Self.firstEpisode(machine)

        #expect(
            await machine.emergency.fansRestoredUnconfirmed == [0],
            "§ 3 forgot a fan its own restore left manual")
        #expect(await machine.emergency.fansUnderManualControl.isEmpty)
        #expect(await machine.handbackReadBack.requests == [[0]], "the read was never issued")
        #expect(
            machine.safetyLog.levels(containing: "is still manual after the thermal emergency")
                == [.fault])

        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(
            await Self.bridges(machine) == 2,
            "the second emergency did not bridge a fan § 3 had left manual")
    }

    /// A fan take-back bridged, whose restore the firmware discarded, is bridged by the next
    /// emergency too.
    ///
    /// The other half of #300. Every other test here reaches the register through `fire`; this
    /// one reaches it only through take-back. The emergency fires with nothing registered, fan 0
    /// is engaged while it holds (a lease that raced the latch), and the next latched cycle
    /// takes it back.
    ///
    /// **Mutation:** in `ThermalEmergency.takeBackAnythingEngagedSinceFiring()`, call
    /// `forget(fanAt: fan.index)` in place of `restoredByEmergency(fan)`. Run: red — the
    /// register is empty after take-back and the second emergency writes nothing to fan 0.
    @Test("A fan still manual after take-back's restore is bridged by the next emergency")
    func aTakenBackButManualFanIsBridgedNextEpisode() async throws {
        let machine = Self.machine(writes: .reverted)
        await machine.emergency.cycle()
        #expect(await machine.emergency.isHolding, "the first episode never fired")
        #expect(await Self.bridges(machine) == 0, "fire bridged a fan nothing had engaged")

        try await machine.engageManualControl(fan: 0)
        await machine.emergency.cycle()
        #expect(await Self.bridges(machine) == 1, "take-back never bridged the late engagement")
        #expect(
            await machine.emergency.fansRestoredUnconfirmed == [0],
            "take-back forgot a fan its restore left manual")

        await machine.plane.advance()
        await machine.emergency.cycle()
        #expect(await !machine.emergency.isHolding, "the first episode never released")
        await machine.emergency.cycle()
        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(
            await Self.bridges(machine) == 2,
            "the second emergency did not bridge a fan take-back had left manual")
    }

    /// A fan whose read-back fails is kept for the next emergency.
    ///
    /// This is what separates the register from re-registering a fan only once a read shows
    /// it manual: a machine that cannot read the fan still bridges it next time.
    ///
    /// **Mutation:** in `ThermalEmergency.readBackAcceptedHandbacks()`, make the restored
    /// loop's `.unreadable` case set `restoredUnconfirmed[fan] = nil`. Run: red — the register
    /// is empty and the second emergency writes nothing to fan 0.
    @Test("A fan whose restore cannot be read back is bridged by the next emergency")
    func anUnreadableRestoredFanIsKept() async throws {
        let machine = Self.machine(writes: .reverted)
        await machine.handbackReadBack.omit([0])
        try await Self.firstEpisode(machine)

        #expect(await machine.emergency.fansRestoredUnconfirmed == [0])
        #expect(
            machine.safetyLog.levels(containing: "could not be read back after the thermal")
                == [.notice])

        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(await Self.bridges(machine) == 2)
    }

    /// A fan restored again by a later emergency, and still manual, is reported again.
    ///
    /// **Mutation:** in `ThermalEmergency.restoredByEmergency(_:)`, carry the old set over —
    /// `RestoredFan(fan: fan, reported: restoredUnconfirmed[fan.index]?.reported ?? [])`.
    /// Run: red on `stillManual == [.fault, .fault]`.
    @Test("A fan still manual after a second emergency's restore is reported again")
    func aSecondRestoreIsReportedAfresh() async throws {
        let machine = ThermalMachine(
            stages: [
                .at(96, writes: .reverted), .at(44, writes: .reverted),
                .at(96, writes: .reverted), .at(44, writes: .reverted),
            ],
            fans: [0: .held(at: 2_400)])
        try await Self.firstEpisode(machine)
        await machine.emergency.cycle()
        await machine.plane.advance()
        await machine.emergency.cycle()
        await machine.plane.advance()
        await machine.emergency.cycle()
        await machine.emergency.cycle()

        let stillManual = machine.safetyLog.levels(
            containing: "is still manual after the thermal emergency")
        #expect(
            stillManual == [.fault, .fault],
            "one line per restore: the second emergency's restore was not reported")
    }

    // MARK: - Honoured

    /// A fan whose restore took is let go, and the next emergency does not write to it.
    ///
    /// Both assertions, because either alone is satisfied by a mutant: the register could be
    /// emptied without the read (checked by the request), and the read could run without
    /// the result being used (checked by the second episode).
    ///
    /// **Mutation:** in `ThermalEmergency.readBackAcceptedHandbacks()`, ask about
    /// `Set(asked.keys)` only, not the union. Run: red — fan 0 is never confirmed, stays in
    /// the register, and is bridged again.
    @Test("A fan that reads automatic after § 3's restore is let go")
    func aConfirmedRestoreIsLetGo() async throws {
        let machine = Self.machine(writes: .honoured)
        try await Self.firstEpisode(machine)

        #expect(await machine.emergency.fansRestoredUnconfirmed.isEmpty)
        #expect(
            machine.safetyLog.levels(containing: "reads automatic after the thermal emergency")
                == [.notice])

        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(
            await Self.bridges(machine) == 1,
            "the second emergency bridged a fan § 3 had seen back on automatic")
    }

    // MARK: - Engaged again

    /// A fan engaged again leaves the register, so the two never share it and the next
    /// emergency bridges it once, not twice.
    ///
    /// **Mutation:** delete `restoredUnconfirmed[fan.index] = nil` from
    /// `ThermalEmergency.manualControlEngaged(_:)`. Run: red — fan 0 is in both, and the
    /// second emergency bridges it twice.
    @Test("A restored fan engaged again is held once")
    func aReEngagedRestoredFanIsHeldOnce() async throws {
        let machine = Self.machine(writes: .reverted)
        try await Self.firstEpisode(machine)
        try await machine.engageManualControl(fan: 0)

        #expect(await machine.emergency.fansUnderManualControl == [0])
        #expect(await machine.emergency.fansRestoredUnconfirmed.isEmpty)

        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(await Self.bridges(machine) == 2, "one bridge per episode, not two in the second")
    }

    /// A fan engaged again while its read-back is out is not written back into the register.
    ///
    /// The firmware leaves fan 0 manual, so the parked read answers `.manual` — the branch
    /// that writes the entry back. Written back from a copy taken before the await, it would
    /// put fan 0 in both maps.
    ///
    /// **Mutation:** in `ThermalEmergency.readBackAcceptedHandbacks()`, snapshot
    /// `let before = restoredUnconfirmed` ahead of the await and replace
    /// `guard var restored = restoredUnconfirmed[fan] else { continue }` with
    /// `guard var restored = before[fan] else { continue }`. Run: red — fan 0 is in both.
    @Test("A restored fan engaged again during its read-back stays out of the register")
    func aReEngagementDuringTheReadWins() async throws {
        let machine = Self.machine(writes: .reverted)
        try await machine.engageManualControl(fan: 0)
        await machine.emergency.cycle()
        await machine.plane.advance()
        await machine.emergency.cycle()

        await machine.handbackReadBack.hold()
        let cycle = observing { await machine.emergency.cycle() }
        #expect(
            await yieldUntil("the read-back to park") { await machine.handbackReadBack.held == 1 })
        try await machine.engageManualControl(fan: 0)
        await machine.handbackReadBack.open()
        _ = try await finished("the cycle holding the read", cycle)

        #expect(await machine.emergency.fansUnderManualControl == [0])
        #expect(
            await machine.emergency.fansRestoredUnconfirmed.isEmpty,
            "a read taken before the fan was engaged again put it back in the register")
    }
}
