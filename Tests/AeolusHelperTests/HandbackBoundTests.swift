import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The scripted firmware as the bounded restorer's attempt seam.
///
/// One line, and deliberately in the test target: `FanControlPlane` is the provider and
/// `FanRestoreAttempting` is the role, but *which* scope a production adapter uses — and
/// whether it clears the Apple Silicon force key on the way — is
/// [#102](https://github.com/blamechris/Aeolus/issues/102)'s decision, not this one's.
/// Bridging it here gets the shipped scripted firmware onto the bound's path without
/// pre-empting that.
extension ScriptedControlPlane: FanRestoreAttempting {
    func restoreOnce(fanAt index: Int) async throws {
        try await restoreToAutomatic(.fan(index))
    }
}

/// An attempt seam that refuses for a named set of fans and succeeds for the rest.
///
/// The scripted plane's `WriteBehaviour` is a property of the stage, so it cannot express
/// "this fan's mode write is discarded and that one's is not" — which is the one thing a
/// *per-fan* bound has to be tested against. Everything else in this file drives the real
/// mock.
actor PartiallyRefusingRestore: FanRestoreAttempting {

    private let refusing: Set<Int>
    private(set) var attempts: [Int] = []

    init(refusing: Set<Int>) {
        self.refusing = refusing
    }

    func restoreOnce(fanAt index: Int) async throws {
        attempts.append(index)
        guard !refusing.contains(index) else {
            throw AeolusXPCFault.helperFailed(detail: "the firmware discarded the mode write")
        }
    }

    func attemptCount(forFan index: Int) -> Int {
        attempts.filter { $0 == index }.count
    }
}

/// [#110](https://github.com/blamechris/Aeolus/issues/110): the handback interlock makes
/// helper liveness depend on the restorer terminating.
///
/// `LeaseAuthority` refuses a lease over a fan whose restore is still in flight, and the
/// restore is awaited from teardown paths — `connectionDidInvalidate`, and since #136 from
/// `ReclamationWatchdog.cycle()` by way of `revokeEveryLease`. A restorer that keeps trying
/// forever therefore parks a safety supervisor's loop for the life of the process, silently,
/// for every fan. The decided answer is bounded attempts, then **report**: the restorer
/// returns, and the fan it gave up on is refused with a durable reason distinct from the
/// transient `.releaseInProgress`, so a client can tell "retrying" from "gave up".
@Suite("The handback bound")
struct HandbackBoundTests {

    private static func plane(
        fans: Set<Int> = [0],
        writes: ScriptedControlPlane.WriteBehaviour
    ) -> ScriptedControlPlane {
        ScriptedControlPlane(
            fans: Dictionary(uniqueKeysWithValues: fans.map { ($0, .held(at: 3_000)) }),
            stages: [.nominal(writes: writes)]
        )
    }

    private static let refused = ScriptedControlPlane.WriteBehaviour.refused(
        reason: "the firmware refused the mode write")

    // MARK: - The bound itself

    /// The time limit is the assertion. Everything below it only says what the bound is
    /// worth once it exists; this says the call comes back at all.
    @Test(
        "A restore the firmware never accepts stops after the budget and returns",
        .timeLimit(.minutes(1))
    )
    func aRestoreThatNeverSucceedsIsBounded() async {
        let firmware = Self.plane(writes: Self.refused)
        let restorer = BoundedFanRestorer(attempting: firmware, log: LeaseFixture.log)

        let abandoned = await restorer.restoreToAutomatic(fans: [0], because: .leaseReleased)

        #expect(abandoned == [0])
        let attempts = await firmware.attempts
        #expect(attempts.count == RestoreLimits.attemptBudget)
        #expect(attempts.allSatisfy { $0 == .restoreToAutomatic(.fan(0)) })
    }

    /// The budget is spent per fan, and a fan that comes back on the first attempt does not
    /// pay for one that never does.
    @Test("The budget is per fan, and a success stops spending it", .timeLimit(.minutes(1)))
    func theBudgetIsSpentPerFan() async {
        let attempting = PartiallyRefusingRestore(refusing: [1])
        let restorer = BoundedFanRestorer(attempting: attempting, log: LeaseFixture.log)

        let abandoned = await restorer.restoreToAutomatic(fans: [0, 1], because: .leaseExpired)

        #expect(abandoned == [1])
        #expect(await attempting.attemptCount(forFan: 0) == 1)
        #expect(await attempting.attemptCount(forFan: 1) == RestoreLimits.attemptBudget)
    }

    /// A firmware that takes the write reports nothing abandoned — the property that keeps
    /// the durable refusal below from being a blanket one.
    @Test("A restore the firmware accepts abandons nothing", .timeLimit(.minutes(1)))
    func anHonouredRestoreAbandonsNothing() async {
        let firmware = Self.plane(fans: [0, 1], writes: .honoured)
        let restorer = BoundedFanRestorer(attempting: firmware, log: LeaseFixture.log)

        let abandoned = await restorer.restoreToAutomatic(fans: [0, 1], because: .leaseReleased)

        #expect(abandoned.isEmpty)
        #expect(await firmware.attempts.count == 2)
    }

    // MARK: - What the lease core does with it

    /// The whole contract, end to end, through the shipped types: the release returns, and
    /// the fan the firmware would not take back is refused with the reason that says so.
    @Test(
        "A fan the restorer gave up on is refused durably, and the release returns",
        .timeLimit(.minutes(1))
    )
    func aGivenUpFanIsRefusedWithTheDurableReason() async throws {
        let firmware = Self.plane(writes: Self.refused)
        let authority = LeaseFixture.authority(
            restorer: BoundedFanRestorer(attempting: firmware, log: LeaseFixture.log))
        let connection = ConnectionID()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        try await authority.releaseLease(id: lease.id, from: connection)

        // The transient reason would be the wrong answer: the restore is not in flight any
        // more, it is over and it failed. A client told "retry in a moment" retries forever.
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .restoreToAutomaticFailed)
        ) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [0]), from: connection)
        }
    }

    /// The refusal is per fan, not per machine: a sibling the firmware did take back stays
    /// leasable. Without this, "durable" could be implemented as a latch that closes the
    /// whole machine down the first time any restore fails.
    @Test("Only the fan that was given up on is refused", .timeLimit(.minutes(1)))
    func onlyTheAbandonedFanIsRefused() async throws {
        let attempting = PartiallyRefusingRestore(refusing: [1])
        let authority = LeaseFixture.authority(
            restorer: BoundedFanRestorer(attempting: attempting, log: LeaseFixture.log))
        let connection = ConnectionID()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: connection)
        try await authority.releaseLease(id: lease.id, from: connection)

        let regranted = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        #expect(await authority.leaseCount == 1)
        try await authority.releaseLease(id: regranted.id, from: connection)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .restoreToAutomaticFailed)
        ) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [1]), from: connection)
        }
    }

    /// Refusals are ordered by how long they last, and this is the one that outlasts them
    /// all. A client told `leaseHeldByAnotherClient` waits for the holder to go away and
    /// then meets this refusal anyway — the same argument the lease core already made for
    /// putting the concurrent-lease refusal ahead of `.releaseInProgress`, one rung further
    /// up.
    @Test("The durable refusal outranks a lease another client holds", .timeLimit(.minutes(1)))
    func theDurableRefusalOutranksAConcurrentLease() async throws {
        let attempting = PartiallyRefusingRestore(refusing: [1])
        let authority = LeaseFixture.authority(
            restorer: BoundedFanRestorer(attempting: attempting, log: LeaseFixture.log))
        let holder = ConnectionID()
        let other = ConnectionID()

        let first = try await authority.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: holder)
        try await authority.releaseLease(id: first.id, from: holder)
        // Fan 1 is abandoned; fan 0 went back, and is taken again so the table is not empty.
        _ = try await authority.acquireLease(LeaseFixture.request(fans: [0]), from: holder)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .restoreToAutomaticFailed)
        ) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [1]), from: other)
        }
    }

    // MARK: - The vocabulary

    /// Additive within v1: `Reason(wireValue:)` is forward-tolerant by construction, so an
    /// older client renders this generically rather than failing to decode.
    @Test("The durable reason needs no protocol bump")
    func theDurableReasonIsForwardTolerant() {
        #expect(AeolusXPCVersion.current == 1)
        let reason = ManualControlAvailability.Reason(wireValue: "restoreToAutomaticFailed")
        #expect(reason == .restoreToAutomaticFailed)
        #expect(
            ManualControlAvailability.Reason.restoreToAutomaticFailed.wireValue
                == "restoreToAutomaticFailed")
        #expect(reason != .releaseInProgress)
    }
}
