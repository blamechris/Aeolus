import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Where § 2's bounds gate sits in the grant, held to the ladder's order
/// ([#270](https://github.com/blamechris/Aeolus/issues/270)).
///
/// `acquireLease` reads every requested fan's bounds afresh after the foreign-control read and
/// above the straight-line marker, over the fans that read did not exempt. The ladder's step 8
/// states the same refusal, and step 5 and the registers already rank above it, so the two
/// sides agree only while the grant keeps that order. Each scenario here puts a second refusal
/// beside implausible bounds and requires the snapshot's reason to equal the thrown one; each
/// names the misplacement that makes them part.
///
/// **One firmware value per scenario.** `F0Mx` or `F0Mn` is scripted on the firmware's stage
/// (`ScriptedControlPlane.Stage.maximumReads`, `.minimumReads`), and the snapshot's provider
/// (`PlaneBackedProvider`) and the grant's `readEnvelope(ofFan:)` both read it, so an agreement
/// here is two reads agreeing rather than two scripts. Every scenario first proves its stage
/// applied, so a stage that stopped applying fails a precondition rather than leaving the
/// scenario asserting about plausible bounds. Where nothing outranks the bounds yet, the snapshot
/// must read `.unavailable(.boundsImplausible)` before the second refusal is set up. Where a
/// register already answers for the fan, the firmware's own bound must read the staged value.
/// `UnreadModeAvailabilityTests` has the unread-mode scenario, and
/// `SnapshotAvailabilityTests.aBoundsImplausibleFanIsStillRefusedOnABuiltSeam` the bare one.
/// The supervisors are not started, for `SnapshotAvailabilityTests`' reason.
@Suite("The grant's bounds gate answers what the snapshot states", .timeLimit(.minutes(1)))
struct GrantBoundsAgreementTests {

    private typealias Fixture = AvailabilityFixture

    /// The snapshot's reason for `fan`. `.available` maps to an `.unknown` the grant can never
    /// throw, so agreement with a granted lease is still red.
    private static func shownReason<Plane: FanControlPlane>(
        ofFanAt fan: Int, in helper: HelperComposition<Plane>
    ) async throws -> ManualControlAvailability.Reason {
        let snapshot = try await helper.authority.snapshot()
        guard case .unavailable(let reason) = try Fixture.availability(ofFanAt: fan, in: snapshot)
        else { return .unknown("available") }
        return reason
    }

    // MARK: - Above the marker

    /// A fan with implausible bounds is refused `.boundsImplausible` while § 7's grant seal is
    /// open, as the snapshot states: the ladder ranks step 8 above the seal's rung, step 10, so
    /// the grant must answer the bounds ahead of the seal's guard.
    ///
    /// The seal is held open by `sealingGrants(during:)` itself, parked on a signal, which is
    /// what § 7's verb and § 4's handback run inside.
    ///
    /// **Mutation:** in `LeaseAuthority.acquireLease`, move `try await
    /// refuseIfBoundsImplausible(connection, wanting: wanting.subtracting(exempted))` below the
    /// marker, to just above `try refuseIfExemptionLapsed(connection, exempted: exempted)`. Run:
    /// red — the grant says `.releaseInProgress`.
    @Test("Implausible bounds are the grant's answer while the machine-wide seal is open")
    func theBoundsAnswerAheadOfTheSeal() async throws {
        let helper = Fixture.composed(
            afterwards: [Fixture.fanZeroMaximum(Fixture.byteSwappedMaximum)])
        await helper.bindSafetyRegistries()
        await helper.plane.advance()
        #expect(try await Self.shownReason(ofFanAt: 0, in: helper) == .boundsImplausible)

        let sealed = AsyncSignal()
        let lift = AsyncSignal()
        let leases = helper.leases
        let seal = observing {
            await leases.sealingGrants {
                await sealed.signal()
                try? await lift.wait()
            }
        }
        try await sealed.wait()
        #expect(
            await helper.leases.activeLeaseView().machineWideRestoreInFlight,
            "the seal is not open, so nothing here is about it")

        let refused = await Fixture.refusalForGrant(over: 0, from: helper.leases)
        let shown = try await Self.shownReason(ofFanAt: 0, in: helper)

        await lift.signal()
        _ = try await finished("the seal to close", seal)
        #expect(refused == .boundsImplausible)
        #expect(
            shown == refused,
            """
            the snapshot says \(shown) while a grant over the same fan is refused \(refused) \
            under the machine-wide seal: the bounds gate is below the seal's guard.
            """)
    }

    /// A fan with implausible bounds is refused `.boundsImplausible` while § 4's sleep seal holds,
    /// as the snapshot states. The ladder ranks step 8 above the sleep seal's rung, step 11
    /// (#269), so the grant must answer the bounds ahead of the sleep seal's guard, which sits
    /// below the marker. **Mutation:** in `ReadOnlyFanReport.firstRefusal`, move the
    /// `sleepSealed` rung up to just above `let accountable`, between steps 6 and 8. Run: red —
    /// the snapshot says `.systemSleeping` — while
    /// `SleepSealAvailabilityTests.stepFiveOutranksTheSeal` stays green.
    ///
    /// The seal is set as `SystemPowerResponder` sets it, through `sealForSleep(generation:)`.
    /// Fan 1's bounds are plausible, so its grant shows the seal holds.
    ///
    /// **Mutation:** in `LeaseAuthority.acquireLease`, move `try await
    /// refuseIfBoundsImplausible(connection, wanting: wanting.subtracting(exempted))` below the
    /// marker, between the `sleep.isSealed` guard and the `machineWideRestoresInFlight` guard.
    /// Run: red — the grant says `.systemSleeping`.
    @Test("Implausible bounds are the grant's answer while the sleep seal holds")
    func theBoundsAnswerAheadOfTheSleepSeal() async throws {
        let helper = Fixture.composed(
            fanCount: 2, afterwards: [Fixture.fanZeroMaximum(Fixture.byteSwappedMaximum)])
        await helper.bindSafetyRegistries()
        await helper.plane.advance()
        #expect(try await Self.shownReason(ofFanAt: 0, in: helper) == .boundsImplausible)

        await helper.leases.sealForSleep(generation: 1)
        #expect(
            await Fixture.refusalForGrant(over: 1, from: helper.leases) == .systemSleeping,
            "the sleep seal is not holding, so nothing here is about it")

        let refused = await Fixture.refusalForGrant(over: 0, from: helper.leases)
        let shown = try await Self.shownReason(ofFanAt: 0, in: helper)

        #expect(refused == .boundsImplausible)
        #expect(
            shown == refused,
            """
            the snapshot says \(shown) while a grant over the same fan is refused \(refused) \
            under the sleep seal: the bounds gate is below the sleep seal's guard.
            """)
    }

    /// A fan under a lease whose bounds then read implausible reads `.releaseInProgress` while the
    /// machine-wide seal is open, as the grant refuses it: the grant exempts a fan Aeolus is
    /// accountable for from its bounds read, so the ladder's step 8 speaks only for the fans that
    /// read covers, and the seal's rung answers for this one
    /// ([#269](https://github.com/blamechris/Aeolus/issues/269)). Until the ladder was one
    /// first-match function the seal's rung re-stated only `.available`, so the snapshot kept the
    /// bounds — silent to `fanctl auto` — while the grant refused for a reason it reads as pending.
    ///
    /// The seal is opened over the live lease, as § 7's verb opens it before its sweep empties the
    /// table; the grant is another connection's.
    ///
    /// **Mutation:** in `ReadOnlyFanReport.firstRefusal(of:observedMode:given:reconciliation:)`,
    /// drop `!accountable, ` from step 8's condition. Run: red — the snapshot says
    /// `.boundsImplausible`.
    @Test("A leased fan with implausible bounds reads the seal's reason while the seal is open")
    func aLeasedFansBoundsDoNotOutrankTheSeal() async throws {
        let helper = Fixture.composed(
            afterwards: [Fixture.fanZeroMaximum(Fixture.byteSwappedMaximum)])
        await helper.bindSafetyRegistries()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        await helper.plane.advance()
        #expect(
            try await helper.plane.firmwareBound(.maximum, ofFan: 0) == Fixture.byteSwappedBound,
            "fan 0's maximum reads plausible, so the bounds have nothing to say")

        let sealed = AsyncSignal()
        let lift = AsyncSignal()
        let leases = helper.leases
        let seal = observing {
            await leases.sealingGrants {
                await sealed.signal()
                try? await lift.wait()
            }
        }
        try await sealed.wait()
        let refused = await Fixture.refusalForGrant(over: 0, from: helper.leases)
        let shown = try await Self.shownReason(ofFanAt: 0, in: helper)

        await lift.signal()
        _ = try await finished("the seal to close", seal)
        #expect(refused == .releaseInProgress)
        #expect(
            shown == refused,
            """
            the snapshot says \(shown) about a leased fan while a grant over it is refused \
            \(refused) under the machine-wide seal: step 8 answered for a fan the grant exempts.
            """)
    }

    // MARK: - After the foreign-control read

    /// A fan something else holds in manual, with implausible bounds, reads
    /// `.foreignManualControl`, as the grant refuses it: the foreign read comes first on both
    /// sides — step 5 above step 8, and the grant's § 6 read above its bounds read.
    ///
    /// **Mutation:** in `LeaseAuthority.acquireLease`, move the bounds gate above the foreign
    /// read, as `try await refuseIfBoundsImplausible(connection, wanting:
    /// wanting.subtracting(fansAeolusIsAccountableFor))` before `let exempted`. Run: red — the
    /// grant says `.boundsImplausible`.
    @Test("A fan held elsewhere with implausible bounds reads foreign control on both sides")
    func foreignControlOutranksImplausibleBounds() async throws {
        let helper = Fixture.composed(
            afterwards: [Fixture.fanZeroMaximum(Fixture.byteSwappedMaximum)])
        await helper.bindSafetyRegistries()
        await helper.plane.advance()
        #expect(try await Self.shownReason(ofFanAt: 0, in: helper) == .boundsImplausible)
        await helper.plane.setMode(.manual, ofFan: 0)

        let shown = try await Self.shownReason(ofFanAt: 0, in: helper)
        let refused = await Fixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(refused == .foreignManualControl)
        #expect(
            shown == refused,
            "the snapshot says \(shown) while the grant refuses \(refused) for a held fan")
    }

    // MARK: - Over the fans the foreign read did not exempt

    /// A fan in the durable handback register, whose bounds have since begun to read
    /// implausible, reads `.restoreToAutomaticFailed`, as the grant refuses it: an accountable
    /// fan is exempted from the bounds read as it is from the foreign read, and is answered by
    /// the register that holds it.
    ///
    /// The bounds are plausible while the lease is taken and released — the firmware refuses
    /// every restore, so the fan lands in `restoreAbandoned` — and implausible from the next
    /// stage on. The register hides the bounds from the snapshot, so `F0Mx` is read back first.
    ///
    /// **Mutation:** in `LeaseAuthority.acquireLease`, pass `wanting` to
    /// `refuseIfBoundsImplausible(_:wanting:)` without `.subtracting(exempted)`. Run: red — the
    /// grant says `.boundsImplausible`.
    @Test("A fan in a handback register with implausible bounds reads the register's reason")
    func aRegisterOutranksImplausibleBounds() async throws {
        let refused = Fixture.firmwareRefusesTheModeWrite
        let helper = Fixture.composed(
            writes: refused,
            afterwards: [Fixture.fanZeroMaximum(Fixture.byteSwappedMaximum, writes: refused)])
        try await Fixture.acquireAndRelease(fanAt: 0, in: helper)
        #expect(
            await helper.leases.fansWithAbandonedHandbacks == [0],
            "fan 0's handback was not abandoned, so no register answers for it")
        await helper.plane.advance()
        #expect(
            try await helper.plane.firmwareBound(.maximum, ofFan: 0) == Fixture.byteSwappedBound,
            "fan 0's maximum reads plausible, so the bounds have nothing to outrank")

        let shown = try await Self.shownReason(ofFanAt: 0, in: helper)
        let thrown = await Fixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(thrown == .restoreToAutomaticFailed)
        #expect(
            shown == thrown,
            """
            the snapshot says \(shown) while the grant refuses \(thrown) for a fan Aeolus is \
            accountable for: the bounds read is not exempting the fans the foreign read exempts.
            """)
    }

    // MARK: - A read that fails

    /// A fan whose `F0Mx` does not answer reads `.boundsImplausible` on both sides: the
    /// snapshot's failed read is `.notMeasured`, and so is the grant's thrown one.
    ///
    /// **Mutation:** in `refuseIfBoundsImplausible(_:wanting:)`, make the general `catch` arm's
    /// body `continue`. Run: red — "the grant path granted a lease over fan 0".
    @Test("A bound that will not read is refused as implausible on both sides")
    func aBoundThatWillNotReadIsRefused() async throws {
        let helper = Fixture.composed(afterwards: [Fixture.fanZeroMaximum(.fails)])
        await helper.bindSafetyRegistries()
        await helper.plane.advance()
        await #expect(throws: FanControlPlaneError.self, "fan 0's maximum reads") {
            try await helper.plane.firmwareBound(.maximum, ofFan: 0)
        }

        let shown = try await Self.shownReason(ofFanAt: 0, in: helper)
        let refused = await Fixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(refused == .boundsImplausible)
        #expect(
            shown == refused,
            "the snapshot says \(shown) while the grant refuses \(refused) for an unread bound")
    }

    // MARK: - The minimum half

    /// A fan whose `F0Mn` reads byte-swapped, above its declared `F0Mx`, reads `.boundsImplausible`
    /// on both sides: the grant judges the minimum it read, as the snapshot does.
    ///
    /// **Mutation:** in `refuseIfBoundsImplausible(_:wanting:)`, judge `declaredMinimum:
    /// .measured(0)` in place of `.measured(declared.minimumRPM)`. Run: red — "the grant path
    /// granted a lease over fan 0".
    @Test("An implausible minimum is refused on both sides")
    func anImplausibleMinimumIsRefused() async throws {
        let helper = Fixture.composed(
            afterwards: [Fixture.fanZeroMinimum(.reads(Fixture.byteSwappedBound))])
        await helper.bindSafetyRegistries()
        await helper.plane.advance()
        #expect(
            try await helper.plane.firmwareBound(.minimum, ofFan: 0) == Fixture.byteSwappedBound,
            "fan 0's minimum does not read the staged value")
        #expect(
            try await helper.plane.firmwareBound(.maximum, ofFan: 0) < Fixture.byteSwappedBound,
            "fan 0's maximum is staged too, so this is not about the minimum alone")

        let shown = try await Self.shownReason(ofFanAt: 0, in: helper)
        let refused = await Fixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(refused == .boundsImplausible)
        #expect(
            shown == refused,
            "the snapshot says \(shown) while the grant refuses \(refused) for an inverted range")
    }
}
