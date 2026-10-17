import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The engagement's ticket around the driver (ADR 0014's #410 amendment): the driver takes the
/// restore epoch from the plane before it asks the entitlement, and its first-step retry takes a
/// fresh one before its own. `PlaneWriteLedgerTests` holds the ledger's rows; these hold the
/// driver's order, and the after-check the ticket leaves standing.
@Suite("The engagement's ticket", .timeLimit(.minutes(1)))
struct EngagementTicketTests {

    // MARK: - The ticket comes before the entitlement

    /// § 4's handback lands just before the engagement takes its ticket: the lease ends, then the
    /// machine-wide restore is requested. Taken after both, the ticket is current, so it is the
    /// entitlement that must see the handback, and it does, because it is asked after the ticket:
    /// the engagement is refused on the lease with nothing written.
    ///
    /// **What runs in the hook, and why it is not the handback itself.** `beginEngagement(fanAt:)`
    /// is synchronous, so its hook can run only what a path does without suspending, and the real
    /// handback's release is an actor's. So the hook runs the handback's two effects in its order,
    /// each as it is felt synchronously: the lease is no longer live on the lease clock, advanced
    /// past its TTL — nothing sleeps on that clock in a naive engagement, so no sleeper is woken —
    /// and the restore is requested on the ledger, as a plane does before the restore waits for its
    /// turn.
    ///
    /// **Mutation:** in `EngagementDriver.engageManualControl(of:)`, swap the ticket and the
    /// `requireEntitlement(for:)` after it. Run: red, at the key-write assertion: the entitlement
    /// passes before the hook, the ticket taken after it is current, and the step writes.
    @Test("A handback before the ticket is seen by the entitlement, and nothing is written")
    func aHandbackBeforeTheTicketIsSeenByTheEntitlement() async throws {
        let rig = try await EngagementRig(unlock: .naive)
        let clock = rig.clock.base
        let ledger = rig.plane.ledger
        rig.writes.runBeforeBeginEngagement {
            clock.advance(by: .seconds(Lease.defaultTimeToLive + 1))
            ledger.restoreRequested(.everyFan)
        }

        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(rig.writes.didFireBeforeBeginEngagement, "the handback never ran before the ticket")
        #expect(
            await rig.plane.keyWrites.isEmpty,
            "a step was written for an engagement whose entitlement came after the handback")
        #expect(await rig.plane.attempts.isEmpty, "a step was asked for at all")
        #expect(await rig.registry.engaged.isEmpty)
    }

    /// A restore of another fan lands between fan 0's ticket and its first step's admission, with
    /// the lease still live. The step is superseded having written nothing; the retry takes a fresh
    /// ticket, asks the entitlement, which still holds, and engages fan 0.
    ///
    /// **Mutation:** in `EngagementDriver.firstStep(of:)`, drop the retry's
    /// `writer.beginEngagement(fanAt:)`. Run: red, at the `#expect(throws: Never.self)`: the
    /// retry has no ticket and is refused `.superseded`, and the engagement fails.
    @Test("The first step's retry takes a fresh ticket")
    func theRetryTakesAFreshTicket() async throws {
        let rig = try await EngagementRig(unlock: .naive, fans: [0, 1])
        await rig.writes.interfere(beforeEngageStep: 1) {
            _ = try? await rig.plane.restoreToAutomatic(.fan(1))
        }

        await #expect(throws: Never.self) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the scenario never arranged the interleaving")
        #expect(rig.log.lines(containing: "retrying it once (attempt 2)").count == 1)
        #expect(rig.plane.ledger.engagedFans == [0])
        #expect(await rig.plane.keyWrites == [.mode(fan: 1, value: 0), .mode(fan: 0, value: 1)])
    }

    // MARK: - What the ticket leaves to the after-check

    /// § 3 latches after the first step's turn has returned and before the after-check, with no
    /// restore requested: nothing the ticket can see. The after-check asks the entitlement again,
    /// refuses on the latch, and the fan — registered with § 3 first — is undone.
    ///
    /// The scenarios that held the after-check before the ticket — a restore, or a release and a
    /// re-grant, before the first step — are now refused at the step's admission, so a deleted
    /// after-check survived all of them: a downstream guard masking an upstream one. This is the
    /// order the ticket cannot see, and D1's narrower residual: a lease that ends, or a latch that
    /// sets, once the step is admitted.
    ///
    /// **Mutation:** in `EngagementDriver.engageManualControl(of:)`, delete the after-check, the
    /// `try await requireEntitlement(for: fan)` after `emergency.manualControlEngaged(fan)`. Run:
    /// red, at the `#expect(throws:)`: the engagement returns over a latched § 3.
    @Test("The after-check still undoes a latch that comes after the step's admission")
    func theAfterCheckStillUndoesALatchAfterAdmission() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal], unlock: .naive)
        let rig = try await EngagementRig(
            plane: plane, writes: InterferingFanStateSensing(plane, during: .engageWrite))
        await rig.writes.interfere { await rig.engageThermalEmergency() }

        await #expect(throws: EngagementRefusal.preempted(fan: 0, by: .thermalEmergency)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the latch never set after the step's turn")
        #expect(await rig.plane.keyWrites == [.mode(fan: 0, value: 1), .mode(fan: 0, value: 0)])
        #expect(try await rig.plane.readControlState(ofFan: 0).mode == .automatic)
        #expect(await rig.registry.engaged == [0], "the fan was not registered before its undo")
        #expect(await rig.registry.accepted == [0])
    }
}
