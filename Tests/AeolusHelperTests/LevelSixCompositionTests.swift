import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The composition builds one level 6 and hands the authority that one (ADR 0014's A6 PR-3
/// amendment).
///
/// Its siblings sit beside the pins they mirror: the driver's level in
/// `EngagementDriverLevelTests`, and the gate it waits on in `ExaminationGateRouteTests`, each
/// beside § 5's. This holds the identity those two read through: the `leaseApplier` the
/// composition stores is the instance `SupervisedFanAuthority` delegates to, so a pin on the
/// stored one is a pin on the one a client reaches.
@Suite("The composition builds one level 6, and the authority holds it", .timeLimit(.minutes(1)))
struct LevelSixCompositionTests {

    private static let applyInProgress = AeolusXPCFault.helperFailed(
        detail: LeaseApplyRules.Detail.applyInProgress)

    /// With an `apply` through the authority held inside its engagement step, an `apply` on the
    /// composition's `leaseApplier`, under the same lease, meets that `apply`'s claim and is
    /// refused before it reads anything. The claim is per instance, so two instances would each
    /// admit one: the second would wait for fan 0's gate instead, which on a `TestClock` runs out
    /// at once, and be answered `releaseInProgress`.
    ///
    /// **Mutation:** in `HelperComposition.init`, hand the authority a second instance, a
    /// `LeaseApplier` built with the same arguments. Run: red, answered `releaseInProgress`.
    @Test("The stored level 6 is the one the authority delegates to")
    func theStoredLevelSixIsTheAuthoritys() async throws {
        let machine = await LevelSixMachine()
        let lease = try await machine.lease()
        let engagement = HopParking()
        await machine.writes.interfere(beforeEngageStep: 1) { await engagement.park() }

        let first = observing { try await machine.apply(rpm: 2_400, under: lease) }
        #expect(await yieldUntil("the authority's apply to park") { await engagement.isParked })
        let second = await LevelSixMachine.answer {
            try await machine.helper.leaseApplier.apply(
                [FanSetting(fanIndex: 0, control: .fixed(rpm: 3_000))], leaseID: lease,
                from: machine.holder)
        }
        await engagement.release()
        try await finished("the authority's apply", first)

        #expect(
            second == Self.applyInProgress,
            """
            an apply on the composition's level 6 was answered \(String(describing: second)) \
            while the authority's was in flight: they are not the same instance.
            """)
        #expect(await machine.helper.reclamationWatchdog.lastCommanded(ofFan: 0)?.rpm == 2_400)
    }
}
