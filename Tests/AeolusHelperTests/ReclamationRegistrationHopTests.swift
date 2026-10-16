import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5's registration across its own lease hop (#361's review): a registration told its lease is
/// live can resume after the fan was released, registered again, or given up by § 5's terminal
/// action. Kept out of `ReclamationLeaseIdentityTests.swift`, which is at SwiftLint's
/// `file_length`, as an extension of the same suite. Each scenario holds the lease answer open
/// with `ParkableHeldLeases`, which suspends on a continuation.
extension ReclamationLeaseIdentityTests {

    /// **A registration delayed across its own lease hop** (#357's review, C1). L1's
    /// registration asks the lease core and is told L1 is live; before it resumes, L1 ends, and
    /// L2 may be granted, engage and register fan 0 at 2,000 RPM. L1's registration then resumes
    /// holding a true answer about an instant that has passed. Acting on it replaced L2's record
    /// with a fresh one under L1, and the next cycle judged that record `.leaseLapsed` and handed
    /// back the fan L2 holds.
    ///
    /// Three arrivals, one per guard: the release notice alone, L2's registration alone (a lease
    /// ended with § 5 never told, D2's premise), and both, the shipping order. `ParkableHeldLeases`
    /// holds the answer open on a continuation.
    ///
    /// **Mutation:** drop the generation half of the refusal in
    /// `ReclamationWatchdog.Registry.register(_:fanAt:live:since:)`, leaving `guard live,
    /// givenUp[index] != lease`. Run: red in all three.
    /// **Mutation:** delete the `registrations[index, default: 0] &+= 1` in
    /// `Registry.register(_:fanAt:live:since:)`, after `held[index] = HeldFan.registering(…)`.
    /// Run: red when L2 registers unannounced.
    /// **Mutation:** delete the one in `Registry.release(fanAt:)`, after `held[index] = nil`.
    /// Run: red on the notice alone.
    @Test(
        "A registration whose lease ends during its lease hop records nothing, evicts nothing",
        arguments: [
            (notice: true, regrant: true), (notice: false, regrant: true),
            (notice: true, regrant: false),
        ])
    func aRegistrationWhoseLeaseEndsDuringItsLeaseHopEvictsNothing(
        notice: Bool, regrant: Bool
    ) async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_000)], parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        let ended = try await machine.lease()
        let permit = try Self.permit(machine)
        await hops.parkNextAnswer()
        let late = observing {
            try await machine.watchdog.manualControlEngaged(permit, under: ended.id)
        }
        #expect(await yieldUntil("L1's lease answer to park") { await hops.isParked })

        await machine.endLease()
        if notice { await machine.watchdog.manualControlReleased(fanAt: 0) }
        let next = regrant ? try await Self.regrant(machine) : nil
        if let next {
            try await machine.watchdog.manualControlEngaged(permit, under: next.id)
            await machine.watchdog.commandedTarget(
                CommandedTarget(fanIndex: 0, rpm: 2_000), under: next.id)
        }
        await hops.release()

        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await finished("L1's delayed registration", late)
        }
        #expect(await hops.answers.first == true, "L1's answer was not the parked true one")
        guard let next else {
            #expect(
                await machine.watchdog.fansUnderManualControl.isEmpty,
                "a registration resuming after its lease's release recorded the fan")
            return
        }
        #expect(
            await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000,
            "a registration resuming on a stale answer replaced the live lease's record")
        await machine.watchdog.cycle()
        #expect(await machine.didRestore(fan: 0) == false, "§ 5 handed back the live lease's fan")
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        #expect(await machine.leases.activeLease()?.id == next.id)
    }

    /// **A registration in flight when § 5's terminal action begins** (#361's review, C3).
    /// Fan 0 is held under L1 and reads automatic with nothing commanded, so its third cycle is
    /// the terminal action. A second registration under the same L1 — a re-apply — is told L1 is
    /// live and parked before that cycle. Resuming inside the hand-back, before the revocation,
    /// or after the terminal action returned with § 5 never told of the revocation (this
    /// fixture's restorer sends no notice), it was accepted and cleared the `.systemReclaimed`
    /// mark the terminal action keeps (#346): the fan handed back, its lease revoked, and the
    /// user told the system no longer holds it — rule 6.
    ///
    /// Two guards refuse it, and since #366 both do at each resumption point: the generation bump
    /// at the terminal action's entry, and the same-lease `givenUp` refusal, which outlives the
    /// call. Before #366 the same-lease refusal was `finalising`'s, clear again once the call
    /// returned, so only the bump refused the resumption after it. The ledger is what the
    /// snapshot's `isReclaimedBySystem` reads; the composed helper has no lease-hop seam, so this
    /// asserts the ledger itself.
    ///
    /// **Mutation:** delete the `registrations[index, default: 0] &+= 1` in
    /// `Registry.beginFinalising(fanAt:for:)`, the terminal action's entry in
    /// `finaliseRelease(fanAt:heldUnder:because:)`, **and** drop `givenUp[index] != lease` from
    /// `Registry.register`'s refusal. Run: red on both resumptions: the refusal, the ledger and
    /// the "resolved" line. Either alone leaves this green, because the other refuses.
    @Test(
        "A registration in flight when the terminal action begins clears nothing",
        arguments: [true, false])
    func aRegistrationInFlightAtTheTerminalActionClearsNothing(
        resumesInsideTheHandBack: Bool
    ) async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 2_400)])
        let sensing = InterferingFanStateSensing(plane, during: .restoreWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 2_400)], interfering: sensing,
            parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        try await machine.holdWithoutCommanding(fan: 0)
        let held = try await Self.activeLease(machine)
        let permit = try Self.permit(machine)
        await hops.parkNextAnswer()
        let reapply = observing {
            try await machine.watchdog.manualControlEngaged(permit, under: held)
        }
        #expect(await yieldUntil("the re-apply's lease answer to park") { await hops.isParked })
        if resumesInsideTheHandBack {
            await sensing.interfere {
                await hops.release()
                await yieldUntil("the re-apply to resume inside the hand-back") {
                    await reapply.isFinished.isSet
                }
            }
        }

        for _ in 1...ReclamationLimits.blindCyclesBeforeDivergence {
            await machine.watchdog.cycle()
        }
        await hops.release()

        #expect(await sensing.didFire == resumesInsideTheHandBack)
        #expect(machine.safetyLog.lines(containing: "no speed to re-assert").count == 1)
        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await finished("the re-apply's registration", reapply)
        }
        #expect(
            await machine.ledger.isReclaimed(fanAt: 0),
            "a registration in flight across the terminal action erased the mark it keeps")
        #expect(machine.safetyLog.lines(containing: "is no longer reported as taken").isEmpty)
        #expect(await machine.leases.leaseCount == 0, "the terminal action did not revoke L1")
        #expect(await machine.restorer.causes == [.systemReclaimed])
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }
}
