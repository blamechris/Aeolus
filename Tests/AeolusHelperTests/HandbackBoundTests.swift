import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

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

    /// That the call comes back at all. Everything below only says what the bound is worth
    /// once it exists.
    ///
    /// `breachedCeiling` is the assertion that carries the bound, not the time limit — see
    /// `AttemptCeiling` for why a time limit cannot carry it here.
    @Test(
        "A restore the firmware never accepts stops after the budget and returns",
        .timeLimit(.minutes(1))
    )
    func aRestoreThatNeverSucceedsIsBounded() async {
        let firmware = Self.plane(writes: Self.refused)
        let attempting = CeilingedRefusal(firmware)
        let restorer = BoundedFanRestorer(attempting: attempting, log: LeaseFixture.log)

        let abandoned = await restorer.restoreToAutomatic(fans: [0], because: .leaseReleased)

        #expect(
            await attempting.breachedCeiling == false,
            """
            The restorer tried fan 0 \(AttemptCeiling.perFan) times: the bound is gone, and \
            the double had to stop the loop the restorer should have stopped itself.
            """)
        #expect(abandoned == [0])
        let attempts = await firmware.attempts
        #expect(attempts.count == RestoreLimits.attemptBudget)
        #expect(attempts.allSatisfy { $0 == .restoreToAutomatic(.fan(0)) })
    }

    /// The budget is a number a reviewer has to be able to find and argue with, so it is
    /// pinned from both sides.
    ///
    /// Nothing in `Sources/` bounds it from above: raising it to 500 compiles, keeps every
    /// other test in this file green — they all assert *equality* with it — and turns a
    /// teardown path into a stall on `ReclamationSupervisor`'s cycle, for every fan, with no
    /// delay between attempts to make the stall visible as anything but a hang. That is
    /// [#139](https://github.com/blamechris/Aeolus/issues/139)'s class of defect, and this is
    /// the same answer.
    @Test("The attempt budget is bounded above, and is § 5's number")
    func theAttemptBudgetIsBoundedAbove() {
        #expect(RestoreLimits.attemptBudget >= 1)
        #expect(RestoreLimits.attemptBudget <= 5)
        // `RestoreLimits`' own documentation claims this equality is deliberate — the same
        // firmware, the same kind of mode write, and no reason for a reader to have to
        // remember two numbers. A change to one that leaves the other alone should fail here
        // rather than quietly make that comment false.
        #expect(RestoreLimits.attemptBudget == ReclamationLimits.reassertAttemptBudget)
    }

    /// The budget is spent per fan, and a fan that comes back on the first attempt does not
    /// pay for one that never does.
    @Test("The budget is per fan, and a success stops spending it", .timeLimit(.minutes(1)))
    func theBudgetIsSpentPerFan() async {
        let attempting = PartiallyRefusingRestore(refusing: [1])
        let restorer = BoundedFanRestorer(attempting: attempting, log: LeaseFixture.log)

        let abandoned = await restorer.restoreToAutomatic(fans: [0, 1], because: .leaseExpired)

        #expect(await attempting.breachedCeiling == false)
        #expect(abandoned == [1])
        #expect(await attempting.attemptCount(forFan: 0) == 1)
        #expect(await attempting.attemptCount(forFan: 1) == RestoreLimits.attemptBudget)
    }

    /// A firmware that refuses and then comes good is the case the retry loop exists for,
    /// and until now nothing asserted it: `lastFailure = nil` could be deleted and the whole
    /// suite stayed green. The mutant turns a fan that **did** come back into one refused for
    /// the life of the helper process — the exact inversion `.restoreToAutomaticFailed` is
    /// supposed to be the honest report of.
    ///
    /// Both ends of the budget: the first retry, and the last attempt it allows.
    @Test(
        "A fan the firmware takes back on a later attempt is not abandoned",
        .timeLimit(.minutes(1)),
        arguments: [1, RestoreLimits.attemptBudget - 1]
    )
    func aLateSuccessIsNotAbandoned(refusals: Int) async {
        let attempting = RefusesThenSucceeds(refusals: refusals)
        let restorer = BoundedFanRestorer(attempting: attempting, log: LeaseFixture.log)

        let abandoned = await restorer.restoreToAutomatic(fans: [0], because: .leaseReleased)

        #expect(abandoned.isEmpty)
        #expect(await attempting.attemptCount(forFan: 0) == refusals + 1)
    }

    /// The same property through the lease core, where it is user-visible: the fan is
    /// leasable again.
    ///
    /// Driven at the last attempt the budget allows, because that is the case a restorer
    /// carrying a stale failure gets wrong most quietly — the write did land, on the wire and
    /// in the firmware, and only the helper's bookkeeping says otherwise.
    @Test(
        "A fan that came back on the last allowed attempt stays leasable",
        .timeLimit(.minutes(1))
    )
    func aLateSuccessLeavesTheFanLeasable() async throws {
        let attempting = RefusesThenSucceeds(refusals: RestoreLimits.attemptBudget - 1)
        let authority = LeaseFixture.authority(
            restorer: BoundedFanRestorer(attempting: attempting, log: LeaseFixture.log))
        let connection = ConnectionID()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        try await authority.releaseLease(id: lease.id, from: connection)
        #expect(await attempting.attemptCount(forFan: 0) == RestoreLimits.attemptBudget)

        let regranted = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        #expect(await authority.leaseCount == 1)
        try await authority.releaseLease(id: regranted.id, from: connection)
    }

    /// A teardown that runs on a cancelled task still lands the write.
    ///
    /// `restoreToAutomatic` is the safe-direction write — ADR 0007's keystone, the terminal
    /// action every other mechanism falls back to — so it must not be abandonable by whoever
    /// happened to cancel the task it was called on. A `CancellationError` says the caller
    /// went away; it says nothing about the firmware, which is `refuseIfBlind`'s distinction
    /// applied to the write rather than to a read.
    ///
    /// **What the gate guarantees: cancellation is already pending when `restoreToAutomatic`
    /// is entered.** The teardown task cannot get past `cancelled.wait()` until either
    /// `teardown.cancel()` or `cancelled.signal()` releases it, and both of those happen
    /// after the main task has observed `ready` — so `Task.isCancelled` is true on entry in
    /// every interleaving. Without the gate the task could run the whole restore before
    /// `cancel()` ever landed, and the test would pass green having exercised nothing.
    ///
    /// `AsyncSignal.wait()` is cancellation-aware since #174, so the parked `wait()` is the
    /// call that observes the cancellation first: it throws `CancellationError`. That is
    /// swallowed with `try?` on purpose — the gate's only job is the ordering above, and the
    /// property under test is what the *restorer* does next, not what the gate reports.
    ///
    /// No caller runs a teardown on a cancellable task today. This is what lets one.
    @Test("A teardown on a cancelled task still lands the write", .timeLimit(.minutes(1)))
    func cancellationIsNotAFirmwareRefusal() async throws {
        let attempting = CancellationSensitiveRestore()
        let restorer = BoundedFanRestorer(attempting: attempting, log: LeaseFixture.log)
        let ready = AsyncSignal()
        let cancelled = AsyncSignal()

        let teardown = Task {
            await ready.signal()
            try? await cancelled.wait()
            return await restorer.restoreToAutomatic(fans: [0], because: .connectionInvalidated)
        }
        try await ready.wait()
        teardown.cancel()
        await cancelled.signal()
        let abandoned = await teardown.value

        #expect(abandoned.isEmpty)
        #expect(await attempting.landed == 1)
        // One attempt, not three: a cancellation counted against the budget would spend the
        // whole of it without a write ever reaching the firmware, and then write a fault line
        // naming three refusals that never happened.
        #expect(await attempting.attempts == 1)
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
        let attempting = CeilingedRefusal(Self.plane(writes: Self.refused))
        let authority = LeaseFixture.authority(
            restorer: BoundedFanRestorer(attempting: attempting, log: LeaseFixture.log))
        let connection = ConnectionID()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        try await authority.releaseLease(id: lease.id, from: connection)
        #expect(await attempting.breachedCeiling == false)

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
        #expect(await attempting.breachedCeiling == false)

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
        #expect(await attempting.breachedCeiling == false)

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
