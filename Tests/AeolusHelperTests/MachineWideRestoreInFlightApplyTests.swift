import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 4's sleep handback and § 7's panic verb with level 6's `apply` in flight, composed (ADR 0014's
/// #410 ticket-and-seal amendment, item 1a).
///
/// Each machine-wide path ends every lease before it requests its restore. An engagement whose
/// entitlement answered before that took its ticket before the entitlement, so its first step,
/// admitted after the restore was requested, is refused inside its own turn with nothing written.
/// These hold that through the composed helper, where the restore is the real one, and the one
/// that holds what the exit's seal must not do: seal the plane at a sleep.
@Suite("A machine-wide restore with an apply in flight", .timeLimit(.minutes(1)))
struct MachineWideRestoreInFlightApplyTests {

    // MARK: - § 4, a sleep

    /// `.willSleep` arrives while an `apply` is past its entitlement and before its engagement's
    /// first step. The handback releases the lease and restores `.everyFan`, then acknowledges;
    /// the first step that follows is refused at its admission, and its retry on the ended lease.
    /// So the machine is let sleep with every fan automatic and the force key clear, and nothing
    /// is written after the handback's restore: ADR 0014's question-3 restatement, that § 4's
    /// handback leaves raw `F<n>Md = 0` and `Ftst = 0` at wake, holds with an engagement in
    /// flight.
    ///
    /// The clock is `HandbackFirstClock`, so the acknowledgement is the handback's, as on a healthy
    /// machine: on `TestClock` the five-second budget would expire at once, and the system would
    /// be let sleep before the handback had run.
    ///
    /// **Mutation:** in `PlaneWriteLedger.admitStep(fanAt:)`, admit a first step whatever its
    /// ticket, recording the epoch at admission — the rule before the ticket. Run: red, at the
    /// forward-write assertion on both paths, and at the undo assertion: the step writes after
    /// the handback and the after-check undoes it.
    @Test(
        "A sleep with an apply in flight leaves no forward write after the handback",
        arguments: [
            ScriptedControlPlane.UnlockBehaviour.naive, .heldUntilForced(stepsToYield: 2),
        ])
    func aSleepWithAnApplyInFlightLeavesNoForwardWriteAfterTheHandback(
        unlock: ScriptedControlPlane.UnlockBehaviour
    ) async throws {
        let machine = await LevelSixMachine(unlock: unlock, clock: HandbackFirstClock())
        let lease = try await machine.lease()
        let firmware = machine.firmware
        let atAcknowledgement = FirmwareAtAcknowledgement()
        await machine.writes.interfere(beforeEngageStep: 1) {
            await machine.helper.powerResponder.respond(
                to: SystemPowerNotification(event: .willSleep, generation: 1) {
                    await atAcknowledgement.record(firmware)
                })
        }

        let answer = await LevelSixMachine.answer {
            try await machine.apply(rpm: 2_400, under: lease)
        }

        let state = await atAcknowledgement.state
        let writes = await firmware.keyWrites
        let after = await firmware.attempts.dropFirst(state?.attempts ?? 0)
        #expect(await machine.writes.didFire, "the sleep never arrived inside the engagement")
        #expect(state?.fanZero == .automatic, "fan 0 was not automatic when the sleep was allowed")
        #expect(state?.forceKeySet == false, "the force key was set when the sleep was allowed")
        #expect(
            state?.writes.suffix(2) == [.mode(fan: 0, value: 0), .forceKey(0)],
            "the handback's machine-wide restore was not the last write before the sleep")
        #expect(
            !writes.contains(.mode(fan: 0, value: 1)) && !writes.contains(.forceKey(1)),
            "a forward write reached the firmware with a sleep in progress: \(writes)")
        #expect(
            !after.contains(.restoreToAutomatic(.fan(0))),
            "fan 0 was undone after the sleep was allowed, so a step had written")
        #expect(answer == .leaseUnknown, "the apply was answered \(String(describing: answer))")
    }

    /// A sleep, a wake, and then an `apply` engages normally: § 4's restore is `.everyFan`, which
    /// seals nothing, so the plane admits the engagement once the wake has lifted the grant seal.
    /// Only the exit's restore seals the write path, because only the exit leaves no process.
    ///
    /// **Mutation:** in `PlaneWriteLedger.restoreRequested(_:)`, seal on `.everyFan` as well. Run:
    /// red, at the `#expect(throws: Never.self)`: the plane refuses every step after the sleep.
    @Test("A sleep and a wake leave the plane able to engage")
    func aSleepAndAWakeLeaveThePlaneAbleToEngage() async throws {
        let machine = await LevelSixMachine()
        await machine.helper.powerResponder.respond(
            to: SystemPowerNotification(event: .willSleep, generation: 1) {})
        await machine.helper.powerResponder.respond(
            to: SystemPowerNotification(event: .didWake, generation: 2) {})
        let lease = try await machine.lease()

        await #expect(throws: Never.self) {
            try await machine.apply(rpm: 2_400, under: lease)
        }

        #expect(await machine.firmware.keyWrites.contains(.mode(fan: 0, value: 1)))
        #expect(try await machine.firmware.firmwareMode(ofFan: 0) == .manual)
    }

    // MARK: - § 7, the panic verb

    /// The panic verb arrives while an `apply` is past its entitlement and before its engagement's
    /// first step. It releases every lease, issues `.everyFan` on this `.built` plane, and reads
    /// back; the first step that follows is refused at its admission, so nothing is written after
    /// the restore, no undo follows, and fan 0 stays automatic (ADR 0014's #410 ticket-and-seal
    /// amendment: § 7's transient does not happen).
    ///
    /// **Mutation:** the rule before the ticket, as above. Run: red, at the forward-write
    /// assertion and the undo assertion, on both paths: the step writes and the after-check undoes
    /// it, on the force-key path one poll interval later on the test clock.
    @Test(
        "A panic with an apply in flight writes nothing after its restore",
        arguments: [
            ScriptedControlPlane.UnlockBehaviour.naive, .heldUntilForced(stepsToYield: 2),
        ])
    func aPanicWithAnApplyInFlightWritesNothingAfterItsRestore(
        unlock: ScriptedControlPlane.UnlockBehaviour
    ) async throws {
        let machine = await LevelSixMachine(unlock: unlock)
        let lease = try await machine.lease()
        let atReply = FirmwareAtAcknowledgement()
        await machine.writes.interfere(beforeEngageStep: 1) {
            do {
                try await machine.helper.authority.restoreAllToAutomatic(from: machine.holder)
            } catch {
                Issue.record("the panic verb was refused: \(error)")
            }
            await atReply.record(machine.firmware)
        }

        let answer = await LevelSixMachine.answer {
            try await machine.apply(rpm: 2_400, under: lease)
        }

        let state = await atReply.state
        let writes = await machine.firmware.keyWrites
        let after = await machine.firmware.attempts.dropFirst(state?.attempts ?? 0)
        #expect(await machine.writes.didFire, "the panic never arrived inside the engagement")
        #expect(
            state?.writes.suffix(2) == [.mode(fan: 0, value: 0), .forceKey(0)],
            "the panic's machine-wide restore was not issued")
        #expect(
            !writes.contains(.mode(fan: 0, value: 1)) && !writes.contains(.forceKey(1)),
            "a forward write reached the firmware after the panic's restore: \(writes)")
        #expect(
            !after.contains(.restoreToAutomatic(.fan(0))),
            "fan 0 was undone after the panic, so a step had written")
        #expect(try await machine.firmware.firmwareMode(ofFan: 0) == .automatic)
        #expect(answer == .leaseUnknown, "the apply was answered \(String(describing: answer))")
    }
}

/// `TestClock`'s virtual time for every sleep but § 4's acknowledgement budget, which parks until
/// its task is cancelled, as the handback cancels it once it has returned. So § 4 acknowledges on
/// its handback, and the driver's poll sleeps still pass at once.
final class HandbackFirstClock: MonotonicClock, Sendable {
    private let base = TestClock()

    var now: ContinuousClock.Instant { base.now }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        guard base.now.duration(to: deadline) >= SystemPowerLimits.acknowledgementBudget else {
            return try await base.sleep(until: deadline)
        }
        try await AsyncSignal().wait()
    }
}

/// What the firmware held when a machine-wide path finished: at § 4's acknowledgement, or as
/// § 7's verb returned.
actor FirmwareAtAcknowledgement {

    struct State: Sendable {
        let fanZero: FirmwareFanMode?
        let forceKeySet: Bool
        let writes: [ScriptedControlPlane.KeyWrite]
        let attempts: Int
    }

    private(set) var state: State?

    func record(_ firmware: ScriptedControlPlane) async {
        state = State(
            fanZero: try? await firmware.firmwareMode(ofFan: 0),
            forceKeySet: await firmware.isForceKeySet,
            writes: await firmware.keyWrites,
            attempts: await firmware.attempts.count)
    }
}
