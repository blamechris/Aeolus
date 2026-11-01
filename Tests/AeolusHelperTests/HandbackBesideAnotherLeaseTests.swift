import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// A fan whose handback is in flight reads `.releaseInProgress` in the snapshot that lists the
/// next lease, and is not cleared to automatic (#516).
///
/// ADR 0015 D5's *Clearance* rests on it: the app may show Automatic for a fan outside its own
/// lease once the snapshot listing that lease reports the fan `isClearedToAutomatic`, and after a
/// loss the only thing placing that snapshot after the earlier lease's handback is the helper.
/// It reads the lease and the handback registers with no suspension between them
/// (`LeaseAuthority.activeLeaseView()`), and the restatement refuses a fan in flight
/// (`ReadOnlyFanReport.firstRefusal`).
///
/// `SnapshotAvailabilityTests.aFanMidHandbackAgreesWithTheGrantPath` pins the rung with no lease
/// listed, and `SupervisedFanAuthorityTests.theLeaseIsReadAfterTheMachineNotBefore` pins the
/// order of the reads. Neither lists lease B beside lease A's handback, which is D5's case, so a
/// rung that answered only while nothing was leased passed both. This one goes red on it.
///
/// The wait for the parked handback watches the firmware, `CycleWedgingRestorePlane.restoreScopes`,
/// and not the register. A wait on `fansMidHandback` would be what went red under the second
/// mutation below, which would leave the assertions it names unexercised.
///
/// The supervisors are not started, for `SnapshotAvailabilityTests`' reason.
@Suite("A handback in flight beside the next lease", .timeLimit(.minutes(1)))
struct HandbackBesideAnotherLeaseTests {

    /// The two ways the first lease ends here: the holder lets go, or its connection dies.
    enum Ending: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case released = "releaseLease"
        case invalidated = "connectionDidInvalidate"

        var testDescription: String { "through \(rawValue)" }

        func end(
            _ lease: Lease, heldBy connection: ConnectionID,
            through authority: SupervisedFanAuthority
        ) async throws {
            switch self {
            case .released: try await authority.releaseLease(id: lease.id, from: connection)
            case .invalidated: await authority.connectionDidInvalidate(connection)
            }
        }
    }

    /// Lease A over fan 0, ended through `ending` with its restore parked in the firmware.
    private struct ParkedHandback: Sendable {
        let plane: CycleWedgingRestorePlane
        let authority: SupervisedFanAuthority
        /// Signalled once `ending` has returned, which is once the handback has.
        let ended: AsyncSignal
    }

    /// Two fans over firmware whose restore parks on demand, with lease A over fan 0 ended
    /// through `ending` and its handback parked.
    private static func parkingTheHandback(
        ofLeaseOverFanZeroEnded ending: Ending
    ) async throws -> ParkedHandback {
        let firmware = AvailabilityFixture.firmware(fanCount: 2, writes: .honoured)
        let plane = CycleWedgingRestorePlane(firmware)
        let helper = AvailabilityFixture.composed(
            plane: plane, provider: PlaneBackedProvider(over: firmware, fanCount: 2))
        await helper.bindSafetyRegistries()
        let authority = helper.authority

        let first = ConnectionID()
        let leaseA = try await authority.acquireLease(LeaseFixture.request(fans: [0]), from: first)
        await plane.wedgeTheNextRestore()
        let ended = AsyncSignal()
        Task {
            do {
                try await ending.end(leaseA, heldBy: first, through: authority)
            } catch {
                Issue.record("lease A did not end \(ending.testDescription): \(error)")
            }
            await ended.signal()
        }
        try await waitUntil("fan 0's restore parked in the firmware") {
            await plane.restoreScopes.contains(.fan(0))
        }
        return ParkedHandback(plane: plane, authority: authority, ended: ended)
    }

    /// Lease A over fan 0 ends with its handback parked in the firmware; lease B over fan 1 is
    /// granted to another connection; the snapshot lists B and restates A's fan as in flight.
    ///
    /// Fan 0's mode reads automatic throughout, because nothing engaged it, so the availability
    /// alone is what withholds the clearance. The snapshot after the handback lands is the other
    /// half: the same fan beside the same lease is cleared then, so the first snapshot's refusal
    /// was about the handback, not about lease B.
    ///
    /// **Mutation:** in `ReadOnlyFanReport.firstRefusal(of:observedMode:given:reconciliation:)`,
    /// make the rung `if leases.lease == nil, leases.handbacksInFlight.contains(index)`. Run: red
    /// here, both arguments, on the availability (`.available`) and the clearance; and red nowhere
    /// else in the suite.
    ///
    /// **Mutation:** in `LeaseAuthority.restore(_:because:through:)`, move
    /// `for fan in fans { registers.beginHandback(ofFan: fan) }` below
    /// `let abandoned = await handback.restoreToAutomatic(fans: fans, because: cause)`. Run: red
    /// here, both arguments, on the availability and the clearance.
    /// `TeardownCountTripwireTests.theRestoreCountsBeforeItSuspends` is red on it too, in the
    /// source text, and so is `TeardownRegistrationGapTests`, whose acquirer is then granted.
    @Test(
        "A fan mid-handback reads release in progress beside the next lease, and is not cleared",
        .disabled(
            """
            Unreachable while a lease must cover every fan (#670): the scenario needs a lease \
            that leaves a fan out. Re-enable when run 1d lifts the rule.
            """),
        arguments: Ending.allCases)
    func aHandbackInFlightIsRestatedBesideTheNextLease(_ ending: Ending) async throws {
        let parked = try await Self.parkingTheHandback(ofLeaseOverFanZeroEnded: ending)
        let authority = parked.authority

        let leaseB = try await authority.acquireLease(
            LeaseFixture.request(fans: [1]), from: ConnectionID())
        let beside = try await authority.snapshot()
        let inFlight = try #require(beside.fans.first { $0.index == 0 })

        #expect(beside.activeLease?.id == leaseB.id, "the snapshot does not list lease B")
        #expect(
            inFlight.mode == .automatic,
            "fan 0 reads manual, so it would be refused clearance whatever its handback did")
        #expect(
            inFlight.manualControlAvailability == .unavailable(.releaseInProgress),
            """
            fan 0's handback is still in flight, and the snapshot listing lease B does not say so. \
            An app holding lease B would be free to show fan 0 as automatic while its restore is \
            on the wire.
            """)
        #expect(
            !inFlight.isClearedToAutomatic,
            "fan 0 is cleared to automatic beside lease B while its handback is still in flight")

        await parked.plane.release()
        try await parked.ended.wait()
        let landed = try await authority.snapshot()
        let handedBack = try #require(landed.fans.first { $0.index == 0 })

        #expect(landed.activeLease?.id == leaseB.id, "lease B is no longer listed")
        #expect(
            handedBack.manualControlAvailability != .unavailable(.releaseInProgress),
            "fan 0 still reads release in progress after its handback returned")
        #expect(
            handedBack.isClearedToAutomatic,
            """
            fan 0 is not cleared beside lease B even once its handback has landed, so the refusal \
            above may have come from lease B rather than from the handback.
            """)
    }
}
