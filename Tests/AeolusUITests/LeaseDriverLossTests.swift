import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// Every way control ends that the app did not ask for is `lost`, and `lost` is never drawn as
/// `held`. A refusal of the lease itself is `refused`: a state, not an error.
@Suite("Lease driver: loss and refusal", .timeLimit(.minutes(1)))
struct LeaseDriverLossTests {

    // MARK: - Snapshots

    /// A snapshot that `SystemSnapshot.controlLoss(leaseID:covering:)` judges lost ends the lease,
    /// with the loss carried as the judgement gave it. The same lease shown held stays held.
    ///
    /// **Mutation (ignore snapshots):** make `LeaseDriver.observe(_:readWith:)` return at once.
    /// Red on the loss.
    @Test("A snapshot controlLoss judges lost is lost")
    func aLossSnapshotIsLost() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.hold(LeaseScene.target([0: 3000])))

        let fine = await scene.driver.beginSnapshotRead()
        await scene.driver.observe(
            Self.snapshot([Self.fan(0, target: 3000)], listing: held.lease), readWith: fine)
        #expect(await scene.driver.state.isHeld, "a snapshot showing the fan held changes nothing")

        let ticket = await scene.driver.beginSnapshotRead()
        await scene.driver.observe(
            Self.snapshot([Self.fan(0, target: nil)], listing: held.lease), readWith: ticket)
        let loss = try #require(await scene.driver.state.loss)
        #expect(loss.cause == .snapshot(.fanNotHeld(fan: 0), isThermalEmergencyActive: false))
        #expect(loss.lease == held.lease)
        await scene.ledger.waitFor { $0.releases == [held.lease.id] }
        await scene.finish()
    }

    /// § 3 revokes every lease when it fires, so the snapshot during an emergency lists none and
    /// `controlLoss` answers `.leaseNotListed(listed: nil)`, not `.thermalEmergency`. The flag is
    /// kept beside the loss, and it is the only place the emergency is named.
    @Test("No lease listed with the emergency flag set is lost, and the emergency is visible")
    func anEmergencyThatRevokedTheLeaseIsNamed() async throws {
        let scene = await LeaseScene()
        try await scene.hold(LeaseScene.target([0: 3000]))
        let ticket = await scene.driver.beginSnapshotRead()

        await scene.driver.observe(
            Self.snapshot([Self.fan(0, target: nil)], listing: nil, emergency: true),
            readWith: ticket)

        let loss = try #require(await scene.driver.state.loss)
        #expect(
            loss.cause == .snapshot(.leaseNotListed(listed: nil), isThermalEmergencyActive: true))
        await scene.finish()
    }

    /// Once § 3's latch releases the flag clears (#476 NB3): the same lease gone, read then, says
    /// nothing about why, and the state does not invent a cause.
    @Test("The lease gone with the flag already clear names no emergency")
    func aClearedFlagNamesNothing() async throws {
        let scene = await LeaseScene()
        try await scene.hold(LeaseScene.target([0: 3000]))
        let ticket = await scene.driver.beginSnapshotRead()

        await scene.driver.observe(
            Self.snapshot([Self.fan(0, target: nil)], listing: nil, emergency: false),
            readWith: ticket)

        let loss = try #require(await scene.driver.state.loss)
        #expect(
            loss.cause == .snapshot(.leaseNotListed(listed: nil), isThermalEmergencyActive: false))
        await scene.finish()
    }

    /// Another client's holder text reaches the state exactly as the snapshot carried it. The
    /// renderer sanitises it; the driver formats nothing.
    @Test("Another client's holder text is carried verbatim")
    func anotherHolderIsCarriedVerbatim() async throws {
        let scene = await LeaseScene()
        try await scene.hold(LeaseScene.target([0: 3000]))
        let other = Lease(
            holderDescription: "fanctl\u{202E}\nnot really",
            expiresAt: Date(timeIntervalSince1970: 0))
        let ticket = await scene.driver.beginSnapshotRead()

        await scene.driver.observe(
            Self.snapshot([Self.fan(0, target: 3000)], listing: other), readWith: ticket)

        let loss = try #require(await scene.driver.state.loss)
        #expect(
            loss.cause == .snapshot(.leaseNotListed(listed: other), isThermalEmergencyActive: false)
        )
        if case .snapshot(.leaseNotListed(let listed?), _) = loss.cause {
            #expect(listed.holderDescription == "fanctl\u{202E}\nnot really")
        }
        await scene.finish()
    }

    /// The read connection is not ordered against the control connection, so a snapshot asked for
    /// before the first `apply` was answered can arrive after it and show the fan not yet held.
    /// Judging it would end a lease that was fine, for good, so it is not judged; one asked for
    /// afterwards is.
    ///
    /// **Mutation (judge every snapshot):** in `LeaseDriver.observe(_:readWith:)`, drop the
    /// `ticket.epoch >= judgedFrom` condition. Red on the first expectation.
    @Test("A snapshot asked for before the first apply was answered is not judged")
    func anEarlySnapshotIsNotJudged() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked)
        await scene.driver.hold(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.applies.isEmpty }
        let early = await scene.driver.beginSnapshotRead()
        let lease = try #require(await scene.helper.heldLeases.values.first)
        await scene.helper.answerParked(.apply)
        await scene.waitForState {
            if case .held(let held) = $0 { held.isConfirmed } else { false }
        }

        let notYetHeld = Self.snapshot([Self.fan(0, target: nil)], listing: lease)
        await scene.driver.observe(notYetHeld, readWith: early)
        #expect(await scene.driver.state.isHeld, "asked for before the engagement it could show")

        await scene.driver.observe(notYetHeld, readWith: await scene.driver.beginSnapshotRead())
        #expect(await scene.driver.state.isLost, "asked for after it")
        await scene.finish()
    }

    // MARK: - The connection

    /// The lease is bound to the control connection, so its health leaving `.handshaken` ends the
    /// lease.
    ///
    /// **Mutation (ignore health):** in `LeaseDriver.watch(_:for:)`, delete the `lose(…)` and its
    /// `return`, so the loop reads on. Red on the loss, for each case.
    @Test(
        "Health leaving handshaken is lost",
        arguments: [HelperConnectionHealth.interrupted, .invalidated, .unresponsive])
    func healthLeavingHandshakenIsLost(_ health: HelperConnectionHealth) async throws {
        let scene = await LeaseScene()
        try await scene.hold(LeaseScene.target([0: 3000]))
        // The driver has taken `.handshaken` and is waiting for the next value.
        await scene.ledger.waitFor { $0.healthAsks >= 2 }

        await scene.helper.pushHealth(health)
        await scene.ledger.waitFor { $0.lost != nil || $0.healthAsks >= 3 }

        let state = await scene.driver.state
        #expect(state.loss?.cause == .connection(health), "\(state)")
        await scene.finish()
    }

    /// An `acquireLease` that fails without an answer leaves whether a lease was granted unknown;
    /// the driver tears the connection down, which ends any lease on it, and says control could
    /// not be shown to have begun.
    @Test("An unanswered acquire is lost, and the connection is torn down")
    func anUnansweredAcquireTearsDown() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .fail(.replyNotDelivered))

        await scene.driver.hold(try LeaseScene.target([0: 3000]))
        await scene.waitForState { $0.isLost }

        let loss = try #require(await scene.driver.state.loss)
        #expect(loss.cause == .acquireUnanswered(.failed(.replyNotDelivered)))
        #expect(loss.lease == nil)
        #expect(await scene.entries.index(of: .disconnect) != nil)
        await scene.finish()
    }

    // MARK: - The helper says no

    /// A refusal of the lease is a state, carried in the helper's own vocabulary, and nothing is
    /// sent under a lease that was never granted.
    @Test(
        "A refused acquire is refused, not an error",
        arguments: [
            AeolusXPCFault.manualControlUnavailable(reason: .leaseHeldByAnotherClient),
            .thermalEmergencyActive,
            .manualControlUnavailable(reason: .noThermalTelemetry),
        ])
    func aRefusedAcquireIsRefused(_ fault: AeolusXPCFault) async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .refuse(fault))

        await scene.driver.hold(try LeaseScene.target([0: 3000]))
        await scene.waitForState { if case .refused = $0 { true } else { false } }
        scene.clock.advance(to: scene.at(.seconds(30)))

        #expect(await scene.driver.state == .refused(fault))
        let entries = await scene.entries
        #expect(entries.applies.isEmpty && entries.renewals.isEmpty && entries.releases.isEmpty)
        #expect(await scene.clock.parked.isEmpty, "no heartbeat for a lease never granted")
        await scene.finish()
    }

    /// A refused `apply` may already have commanded a fan, so the lease is not kept on the
    /// strength of it: lost, and released.
    @Test("A refused apply is lost, and the lease is released")
    func aRefusedApplyIsLost() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(
            .apply, .refuse(.manualControlUnavailable(reason: .supervisorBlind)))

        await scene.driver.hold(try LeaseScene.target([0: 3000]))
        await scene.waitForState { $0.isLost }

        let loss = try #require(await scene.driver.state.loss)
        #expect(loss.cause == .apply(.refused(.manualControlUnavailable(reason: .supervisorBlind))))
        await scene.ledger.waitFor { $0.releases.count == 1 }
        await scene.finish()
    }

    // MARK: - Fixtures

    static func fan(_ index: Int, target: Double?) -> FanState {
        FanState(
            index: index, actualRPM: .measured(3000), minimumRPM: .measured(1350),
            maximumRPM: .measured(5777), targetRPM: target, mode: .manualFixed,
            isReclaimedBySystem: false, manualControlAvailability: .available)
    }

    static func snapshot(
        _ fans: [FanState], listing lease: Lease?, emergency: Bool = false
    ) -> SystemSnapshot {
        SystemSnapshot(
            fans: fans, sensors: [], activeLease: lease, isThermalEmergencyActive: emergency,
            capturedAt: Date(timeIntervalSince1970: 1_000_000))
    }
}

extension [LeaseLedger.Entry] {

    /// How many times the driver asked its health subscription for a value.
    var healthAsks: Int { filter { $0.event == .healthAsked }.count }
}
