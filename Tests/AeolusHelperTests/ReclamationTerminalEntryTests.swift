import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5's terminal action entered for a lease whose fan a newer lease now holds (#361's panel).
/// Kept out of `ReclamationLeaseIdentityTests.swift`, which is near SwiftLint's `file_length`, as
/// an extension of the same suite.
extension ReclamationLeaseIdentityTests {

    /// How the re-assert's envelope read fails after the newer lease registered during it.
    enum EnvelopeFailure: Sendable, CaseIterable {
        /// The read answers, and the bounds it reads cannot mint a permit.
        case implausibleBounds
        /// The read itself throws.
        case readFails
    }

    /// **The terminal action's entry guard.** Fan 0 diverges under L1, and while § 5's re-assert
    /// reads the envelope L1 ends, § 5 is told, and L2 is granted, engages and registers the fan.
    /// Then the envelope fails, which is the terminal action — for L1. The fan now belongs to
    /// L2's engagement and L2's record watches it, so the terminal action leaves it alone: no
    /// hand-back, no drop and no revocation. Both ways the envelope can fail reach it.
    ///
    /// **Mutation:** drop the other-lease check from `ReclamationWatchdog.Registry.beginFinalising(
    /// fanAt:for:)`, which the guard at the top of `finaliseRelease(fanAt:heldUnder:because:)`
    /// asks. Run: red on the restore and the log line in both cases.
    @Test(
        "A terminal action entered for an ended lease leaves the newer lease's fan alone",
        arguments: EnvelopeFailure.allCases)
    func aTerminalActionEnteredForAnEndedLeaseLeavesTheNewerLeasesFanAlone(
        failure: EnvelopeFailure
    ) async throws {
        let condition: ScriptedControlPlane.FanCondition =
            failure == .implausibleBounds
            ? .init(
                mode: .automatic, targetRPM: 1_800, actualRPM: 1_800,
                minimumRPM: 5_777, maximumRPM: 1_350)
            : .automatic(at: 1_800)
        let plane = ScriptedControlPlane(fans: [0: condition], stages: [.nominal(), .blind()])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(plane: plane, fans: [0: condition], interfering: sensing)
        let lease = try await machine.lease(fans: [0])
        let permit = try commandableFan(0, declaring: .held(at: 2_400))
        try await machine.watchdog.manualControlEngaged(permit, under: lease.id)
        await machine.watchdog.commandedTarget(
            CommandedTarget(fanIndex: 0, rpm: 2_400), under: lease.id)
        let granted = GrantedLeases()
        await sensing.interfere { [machine] in
            await machine.endLease()
            await machine.watchdog.manualControlReleased(fanAt: 0)
            do {
                let next = try await Self.regrant(machine)
                await granted.record(next.id)
                await machine.plane.setMode(.manual, ofFan: 0)
                try await machine.watchdog.manualControlEngaged(permit, under: next.id)
            } catch {
                Issue.record("the re-grant inside the envelope read failed: \(error)")
            }
            if failure == .readFails { await machine.plane.advance() }
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            machine.safetyLog.faults.contains { $0.contains("envelope") },
            "the re-assert never failed on its envelope, so the terminal action was not reached")
        let next = try #require(await granted.ids.first)
        #expect(await machine.didRestore(fan: 0) == false, "§ 5 handed back the newer lease's fan")
        #expect(machine.safetyLog.lines(containing: "left fan 0 alone").count == 1)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        #expect(await machine.leases.activeLease()?.id == next)
    }
}
