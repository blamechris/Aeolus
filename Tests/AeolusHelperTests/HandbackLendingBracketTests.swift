import AeolusXPC
import Foundation
import Testing

@testable import AeolusHelper

/// K4 (#440): a restorer lent to the lease core hands back inside the bracket every teardown
/// uses, `restore(_:because:through:)`.
///
/// § 3's revocation is the one teardown that does not restore through the lease core's own
/// `restorer`: it borrows § 3's handback for the call. What that must not cost is the handback
/// ledger. `releasing` is held from before the restore until it returns, so a grant arriving
/// meanwhile is refused `.releaseInProgress`; a refusal lands in `restoreAbandoned`, so the next
/// grant over the fan is refused durably. Both are what `handback-ledger.md` argues for every path,
/// and a lent restorer called outside the bracket would keep neither while every restore still
/// reached the firmware.
@Suite("A lent handback runs inside the handback ledger's bracket", .timeLimit(.minutes(1)))
struct HandbackLendingBracketTests {

    /// A grant arriving while the lent restorer is still handing back is refused
    /// `.releaseInProgress`, the fan is in `releasing` throughout, and the lent restorer — not the
    /// lease core's own — is the one asked, under § 3's label.
    ///
    /// **Mutation (K4):** in `revokeEveryLease(handingBackThrough:)`, call
    /// `handback.restoreToAutomatic(fans: fans, because: cause)` directly instead of
    /// `restore(fans, because: cause, through: handback)`. Run: red — the fan is not mid-handback
    /// and the grant succeeds.
    @Test("A grant during a lent handback is refused, with the fan mid-handback throughout")
    func aGrantDuringALentHandbackIsRefused() async throws {
        let standing = RecordingFanRestorer()
        let leases = LeaseFixture.authority(restorer: standing)
        _ = try await leases.acquireLease(LeaseFixture.request(fans: [0]), from: ConnectionID())

        let entered = AsyncSignal()
        let release = AsyncSignal()
        let lent = RecordingFanRestorer(entered: entered, release: release)
        let revocation = Task { await leases.revokeEveryLease(handingBackThrough: lent) }
        try await entered.wait()

        #expect(await leases.fansMidHandback == [0], "the lent handback is outside `releasing`")
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress)
        ) {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }

        await release.signal()
        await revocation.value

        #expect(await leases.fansMidHandback.isEmpty, "the fan never left `releasing`")
        #expect(
            await lent.restores
                == [RecordingFanRestorer.Restore(fans: [0], cause: .thermalEmergencyRevocation)])
        #expect(await standing.restores.isEmpty, "the lease core's own restorer was asked")
    }

    /// § 3's own handback, as the composition gave it to § 3, refused by the firmware on every
    /// attempt: the fan lands in the lease core's abandoned register, and the next grant over it
    /// is refused `.restoreToAutomaticFailed`.
    ///
    /// **Mutation (K4):** the same direct call. Run: red — nothing is recorded abandoned, and the
    /// grant succeeds.
    @Test("A refused lent handback is recorded abandoned, and refuses the next grant durably")
    func aRefusedLentHandbackIsRecordedAbandoned() async throws {
        let helper = HelperRestorerTests.composed(
            writes: .refused(reason: "the firmware refused the mode write"))
        await helper.bindSafetyRegistries()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())

        await helper.leases.revokeEveryLease(
            handingBackThrough: try HelperRestorerTests.sectionThreesHandback(in: helper))

        #expect(await helper.leases.fansWithAbandonedHandbacks == [0])
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .restoreToAutomaticFailed)
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }
}
