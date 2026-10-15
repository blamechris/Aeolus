import Testing

@testable import AeolusHelper

/// #353: § 5's re-assert command write refused while the lease it was held under ends and
/// another client is granted the fan. Kept out of `ReclamationWatchdogStalenessTests.swift`,
/// whose suite is at SwiftLint's `type_body_length`, as an extension of the same suite so it runs
/// under the same time limit and reads as one subject: what § 5 does across a suspension point.
extension ReclamationWatchdogStalenessTests {

    /// **#353's acceptance.** The firmware refuses the re-assert's command write, and while
    /// § 5 is suspended in that refused write the lease is released, § 5 is told, and another
    /// client is granted the fan. The catch used to re-check nothing: it reported a half-landed
    /// re-assert, and its terminal action revoked every lease — the new one — blaming the system
    /// for Aeolus's own release. It now re-fetches first and finds the fan released, so it hands
    /// the fan back as a release, and the new lease is untouched.
    ///
    /// **Mutation:** delete the `guard isHeld(index, under: lease) else { … }` from
    /// `commandWriteFailed(fanAt:heldUnder:detail:)`, the command write's `catch` in `reassert`.
    /// Run: red on the fault, the notice and the ledger —
    /// the terminal action then revokes only the ended lease, so the new lease survives either
    /// way, and the false blame is what discriminates.
    @Test("A release and re-grant during a failed command write revoke nothing")
    func aReleaseAndRegrantDuringAFailedCommandWriteRevokesNothing() async throws {
        let firmware = ScriptedControlPlane.FanCondition.held(at: 1_800)
        let plane = ScriptedControlPlane(
            fans: [0: firmware],
            stages: [.nominal(targetWrites: .refused(reason: "firmware said no"))])
        let sensing = InterferingFanStateSensing(plane, during: .refusedCommandWrite)
        let machine = ReclamationMachine(plane: plane, fans: [0: firmware], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let granted = GrantedLeases()
        await sensing.interfere { [machine] in
            await machine.endLease()
            await machine.watchdog.manualControlReleased(fanAt: 0)
            do {
                let next = try await machine.leases.acquireLease(
                    LeaseFixture.request(fans: [0]), from: ConnectionID())
                await granted.record(next.id)
            } catch {
                Issue.record("the re-grant inside the refused write failed: \(error)")
            }
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        let next = try #require(await granted.ids.first)
        #expect(await machine.leases.activeLease()?.id == next, "the new lease was revoked")
        #expect(await machine.restorer.causes.contains(.systemReclaimed) == false)
        #expect(
            machine.safetyLog.faults.contains { $0.contains("could not command a target") }
                == false,
            "a release during the refused write was reported as a half-landed re-assert")
        #expect(machine.safetyLog.lines(containing: "during its command write").count == 1)
        #expect(await machine.didRestore(fan: 0), "the released fan was not handed back")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(
            await machine.ledger.causes.isEmpty,
            "a release during the refused write left the fan reported as reclaimed")
    }

    /// The same release and re-grant, and the new lease also registers fan 0 during the refused
    /// write. The catch's re-fetch has to ask about identity: a presence check finds the new
    /// lease's record and reports a half-landed re-assert. The terminal action's own check for
    /// another lease's record would then leave the fan alone anyway, which is why this needs a
    /// test of its own — the log line is what tells the two apart.
    ///
    /// **Mutation:** make `commandWriteFailed(fanAt:heldUnder:detail:)`'s re-fetch check
    /// presence only — `guard held[index] != nil`. Run: red on the half-landed assertion.
    @Test("A record re-granted during a failed command write is left alone")
    func aRegrantedRecordDuringAFailedCommandWriteIsLeftAlone() async throws {
        let firmware = ScriptedControlPlane.FanCondition.held(at: 1_800)
        let plane = ScriptedControlPlane(
            fans: [0: firmware],
            stages: [.nominal(targetWrites: .refused(reason: "firmware said no"))])
        let sensing = InterferingFanStateSensing(plane, during: .refusedCommandWrite)
        let machine = ReclamationMachine(plane: plane, fans: [0: firmware], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try commandableFan(0, declaring: firmware)
        await sensing.interfere { [machine] in
            await machine.endLease()
            await machine.watchdog.manualControlReleased(fanAt: 0)
            do {
                let next = try await machine.leases.acquireLease(
                    LeaseFixture.request(fans: [0]), from: ConnectionID())
                try await machine.watchdog.manualControlEngaged(permit, under: next.id)
                await machine.watchdog.commandedTarget(
                    CommandedTarget(fanIndex: 0, rpm: 2_000), under: next.id)
            } catch {
                Issue.record("the re-grant inside the refused write failed: \(error)")
            }
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.didRestore(fan: 0) == false, "§ 5 handed back the new lease's fan")
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)
        #expect(
            machine.safetyLog.faults.contains { $0.contains("could not command a target") }
                == false,
            "the new lease's record was taken for the old lease's half-landed re-assert")
        #expect(machine.safetyLog.lines(containing: "left fan 0 alone").count == 1)
    }
}
