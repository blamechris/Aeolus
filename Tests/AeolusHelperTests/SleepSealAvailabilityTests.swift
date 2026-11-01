import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The snapshot states § 4's sleep seal where `acquireLease` checks it: the ladder's step 11
/// ([#269](https://github.com/blamechris/Aeolus/issues/269)).
///
/// The grant checks the seal third in its straight-line region — after its fresh read of the
/// fan, its bounds read, and the abandoned and unconfirmed handback registers, and before the
/// machine-wide restore seal and `releasing`. `SafeState` classes `.systemSleeping` pending, so
/// the rung follows that order exactly, and each scenario here puts one rung of the order beside
/// the seal and requires the snapshot's reason to equal the thrown one. Each names the misplaced
/// rung that makes them part.
///
/// The seal is set as `SystemPowerResponder` sets it, through `sealForSleep(generation:)`, with
/// no teardown running: the window after § 4's handback has returned and before the wake, where
/// the snapshot said `.available` until #269 while every grant was refused. `SleepGrantSealTests`
/// has the seal beside a teardown still running. The supervisors are not started, for
/// `SnapshotAvailabilityTests`' reason.
@Suite("The snapshot states the sleep seal where the grant checks it", .timeLimit(.minutes(1)))
struct SleepSealAvailabilityTests {

    private typealias Fixture = AvailabilityFixture
    typealias Reason = ManualControlAvailability.Reason

    /// The two readers, compared: the snapshot's reason for `fan` and the grant's. `.available`
    /// maps to an `.unknown` the grant can never throw, so agreement with a granted lease is red.
    static func reasons<Plane: FanControlPlane>(
        forFanAt fan: Int, in helper: HelperComposition<Plane>
    ) async throws -> (shown: Reason, thrown: Reason) {
        let snapshot = try await helper.authority.snapshot()
        let thrown = await Fixture.refusalForGrant(over: fan, from: helper.leases)
        guard case .unavailable(let shown) = try Fixture.availability(ofFanAt: fan, in: snapshot)
        else { return (.unknown("available"), thrown) }
        return (shown, thrown)
    }

    // MARK: - The rung itself

    /// A fan nothing else refuses reads `.systemSleeping` while the seal stands, as the grant
    /// refuses it. This is the one change `fanctl auto` can see: the reason is pending, so `auto`
    /// in this window exits 8 where it exited 0.
    ///
    /// **Mutation:** delete `if leases.sleepSealed { return .unavailable(.systemSleeping) }` from
    /// `ReadOnlyFanReport.firstRefusal(of:observedMode:given:reconciliation:)`. Run: red — the
    /// snapshot says `.available`.
    @Test("A fan nothing else refuses reads the sleep seal while it stands, as the grant refuses")
    func aSealedSleepReadsSystemSleeping() async throws {
        let helper = Fixture.composed()
        await helper.bindSafetyRegistries()
        await helper.leases.sealForSleep(generation: 1)

        let (shown, thrown) = try await Self.reasons(forFanAt: 0, in: helper)

        #expect(thrown == .systemSleeping, "the seal is not standing, so nothing here is about it")
        #expect(
            shown == thrown,
            """
            the snapshot says \(shown) while every grant is refused \(thrown): a client is \
            offered control the sleep seal refuses.
            """)
    }

    /// A fan mid-handback while the seal stands reads `.systemSleeping`, as the grant refuses it:
    /// the grant checks the seal before `releasing`, so step 3 sits below step 11. The point
    /// #369's delta review raised: a leased fan mid-restore during a sealed teardown.
    ///
    /// **Mutation:** in `firstRefusal`, move `if leases.handbacksInFlight.contains(index) { … }`
    /// above the `leases.sleepSealed` line. Run: red — the snapshot says `.releaseInProgress`.
    @Test("A fan mid-handback under the seal reads the seal, as the grant refuses it")
    func aFanMidHandbackUnderTheSealReadsSystemSleeping() async throws {
        let helper = Fixture.wedging()
        let parked = try await Fixture.parkedHandback(ofFanAt: 0, in: helper)
        await helper.leases.sealForSleep(generation: 1)
        #expect(await helper.leases.fansMidHandback == [0], "fan 0 is not mid-handback")

        let (shown, thrown) = try await Self.reasons(forFanAt: 0, in: helper)

        await helper.plane.release()
        await parked.value
        #expect(thrown == .systemSleeping)
        #expect(
            shown == thrown,
            "the snapshot says \(shown) about a fan mid-handback while the grant says \(thrown)")
    }

    // MARK: - Beside a live lease

    /// A free fan beside another client's lease reads `.systemSleeping` while the seal stands, as
    /// a grant over it is refused: the grant checks the seal before its lease table, so it never
    /// reaches the `.leaseHeldByAnotherClient` a snapshot cannot state, and the two agree on
    /// whether it is refused as well as why. A lease live under the seal is § 4's own order — the
    /// seal, then the release — so this is the teardown's first window.
    ///
    /// **Mutation:** in `firstRefusal`, make step 11 `if leases.sleepSealed, leases.lease == nil`.
    /// Run: red — the snapshot says `.available` — and red in the leased-bounds test below.
    @Test(
        "A free fan beside another client's lease reads the seal, as the grant refuses it",
        .disabled(
            """
            Unreachable while a lease must cover every fan (#670): the scenario needs a lease \
            that leaves a fan out. Re-enable when run 1d lifts the rule.
            """))
    func aFreeFanBesideALeaseReadsSystemSleeping() async throws {
        let helper = Fixture.composed(fanCount: 2)
        await helper.bindSafetyRegistries()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [1]), from: ConnectionID())
        await helper.leases.sealForSleep(generation: 1)

        let (shown, thrown) = try await Self.reasons(forFanAt: 0, in: helper)

        #expect(thrown == .systemSleeping, "the grant reached the lease table, not the seal")
        #expect(
            shown == thrown,
            """
            the snapshot says \(shown) about a free fan while every grant over it is refused \
            \(thrown): a client is offered control the sleep seal refuses.
            """)
    }

    /// A leased fan whose bounds read implausible while the seal stands reads `.systemSleeping`, as
    /// another connection's grant over it is refused: step 8 speaks only for the fans Aeolus is not
    /// accountable for, so a leased fan's bounds are step 9's answer, below the seal. The sleep
    /// seal's twin of `GrantBoundsAgreementTests.aLeasedFansBoundsDoNotOutrankTheSeal`.
    ///
    /// **Mutation:** in `firstRefusal`, drop `!accountable, ` from step 8's condition. Run: red —
    /// the snapshot says `.boundsImplausible`, which `fanctl auto` reads as silent.
    @Test("A leased fan with implausible bounds reads the sleep seal, as the grant refuses it")
    func aLeasedFansBoundsDoNotOutrankTheSleepSeal() async throws {
        let helper = Fixture.composed(
            afterwards: [Fixture.fanZeroMaximum(Fixture.byteSwappedMaximum)])
        await helper.bindSafetyRegistries()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        await helper.plane.advance()
        #expect(
            try await helper.plane.firmwareBound(.maximum, ofFan: 0) == Fixture.byteSwappedBound,
            "fan 0's maximum does not read the staged value, so its bounds are not in question")
        await helper.leases.sealForSleep(generation: 1)

        let (shown, thrown) = try await Self.reasons(forFanAt: 0, in: helper)

        #expect(thrown == .systemSleeping)
        #expect(
            shown == thrown,
            "the snapshot says \(shown) about a leased fan while the grant says \(thrown)")
    }

    // MARK: - What the seal does not overwrite

    /// Which more durable refusal stands beside the seal.
    enum Durable: String, CaseIterable, Sendable {
        /// Step 1: the firmware refused every restore of the fan.
        case abandoned
        /// Step 2: § 4's budget gave up waiting for the fan's restore.
        case unconfirmed
    }

    /// A fan in the abandoned or the unconfirmed register reads that register's reason while the
    /// seal stands, as the grant refuses it: steps 1 and 2 are above step 11 on both sides.
    ///
    /// **Mutation:** in `firstRefusal`, move the `leases.sleepSealed` line above the
    /// `abandonedHandbacks` one. Run: red on both arguments — the snapshot says `.systemSleeping`.
    /// **Mutation:** move it between the `abandonedHandbacks` and `unconfirmedHandbacks` lines.
    /// Run: red on `unconfirmed` only.
    @Test(
        "A fan in a handback register reads the register's reason under the seal",
        arguments: Durable.allCases)
    func aRegisterOutranksTheSeal(_ register: Durable) async throws {
        switch register {
        case .abandoned:
            let helper = Fixture.composed(writes: Fixture.firmwareRefusesTheModeWrite)
            try await Fixture.acquireAndRelease(fanAt: 0, in: helper)
            #expect(await helper.leases.fansWithAbandonedHandbacks == [0])
            await helper.leases.sealForSleep(generation: 1)

            let (shown, thrown) = try await Self.reasons(forFanAt: 0, in: helper)
            #expect(thrown == .restoreToAutomaticFailed)
            #expect(shown == thrown, "the snapshot says \(shown) where the grant says \(thrown)")
        case .unconfirmed:
            let helper = Fixture.wedging()
            let parked = try await Fixture.parkedHandback(ofFanAt: 0, in: helper)
            #expect(await helper.leases.recordUnconfirmedHandbacks() == [0])
            await helper.leases.sealForSleep(generation: 1)

            let (shown, thrown) = try await Self.reasons(forFanAt: 0, in: helper)
            await helper.plane.release()
            await parked.value
            #expect(thrown == .handbackUnconfirmed)
            #expect(shown == thrown, "the snapshot says \(shown) where the grant says \(thrown)")
        }
    }

    /// What step 5 judges beside the seal.
    enum FreshRead: String, CaseIterable, Sendable {
        /// Another program holds the fan in manual.
        case foreign
        /// The fan's `F<n>Md` does not answer.
        case unread
    }

    /// A fan another program holds, or one whose mode will not read, reads step 5's answer while
    /// the seal stands, as the grant refuses it: the grant reads the fan above its straight-line
    /// region, so step 5 is above step 11 on both sides.
    ///
    /// **Mutation:** in `firstRefusal`, insert `if leases.sleepSealed, readPath !=
    /// .unavailable(.writePathNotBuilt) { return .unavailable(.systemSleeping) }` above `let
    /// judged`, which puts step 11 above step 5 and still below step 6. Run: red on both.
    @Test(
        "A fan held elsewhere, or whose mode will not read, reads step 5's answer under the seal",
        arguments: FreshRead.allCases)
    func stepFiveOutranksTheSeal(_ read: FreshRead) async throws {
        let unread = ScriptedControlPlane.Stage(
            temperatures: LeaseFixture.nominalDieTemperatures, unreadableModes: [0])
        let helper = Fixture.composed(afterwards: read == .unread ? [unread] : [])
        await helper.bindSafetyRegistries()
        switch read {
        case .foreign: await helper.plane.setMode(.manual, ofFan: 0)
        case .unread: await helper.plane.advance()
        }
        await helper.leases.sealForSleep(generation: 1)

        let (shown, thrown) = try await Self.reasons(forFanAt: 0, in: helper)

        #expect(thrown == (read == .foreign ? .foreignManualControl : .supervisorBlind))
        #expect(shown == thrown, "the snapshot says \(shown) where the grant says \(thrown)")
    }

    // MARK: - Not over the build

    /// On a seam that cannot write, a sealed sleep reads `.writePathNotBuilt`, as every grant there
    /// is refused: step 6 masks step 11, which is why nothing changes on any build on `main`.
    ///
    /// **Mutation:** in `firstRefusal`, move the `leases.sleepSealed` line to its first
    /// statement. Run: red — the snapshot says `.systemSleeping`.
    @Test("On a seam that cannot write, a sealed sleep reads the build, as the grant refuses")
    func aSealOnASeamThatCannotWriteReadsTheBuild() async throws {
        let firmware = Fixture.firmware(fanCount: 1, writes: .honoured)
        let helper = Fixture.composed(
            plane: ControlStateGatePlane(firmware, capability: .notBuilt),
            provider: PlaneBackedProvider(over: firmware, fanCount: 1))
        await helper.leases.sealForSleep(generation: 1)

        let (shown, thrown) = try await Self.reasons(forFanAt: 0, in: helper)

        #expect(thrown == .writePathNotBuilt)
        #expect(
            shown == thrown,
            "a build that cannot write states \(shown), a reason about the machine no grant returns"
        )
    }
}
