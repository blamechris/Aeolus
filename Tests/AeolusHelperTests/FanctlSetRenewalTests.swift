import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set` keeps its lease alive from the moment it asks for it, including while `apply` is
/// outstanding, and says so honestly when it cannot.
///
/// The helper's thirty seconds start **at the grant**, and an `apply` may now lawfully take 57
/// seconds for one fan and 109 for two (#414). A `set` that renewed only after `apply` and its
/// confirming snapshot let the lease lapse in the middle of an `apply` that was working, and then
/// said it was holding a lease that had ended, or that the helper had refused a speed it may have
/// applied. Nothing in the suite could see it, because the simulated helper's leases never lapsed
/// (`SimulatedFanAuthority.expiringLeases(after:on:)` is what changes that).
///
/// **Time is virtual, and the helper's work is on the same clock.** `VirtualHoldTime.helperBusy`
/// says the helper takes N seconds of it to answer `apply`; the keeper's waits elapse until then
/// and no further, and a wait made while the helper is not working parks until the run stops it.
/// That is what lets a run that holds an `apply` for 35 virtual seconds renew at 10, 20 and 30
/// without a real second passing.
@Suite("fanctl set renews its lease while apply is outstanding", .timeLimit(.minutes(1)))
struct FanctlSetRenewalTests {

    typealias Harness = SetHarness

    // MARK: - The lease is renewed on the heartbeat while apply works

    /// An `apply` of 25 seconds. The first renewal has to land well before the helper's thirty
    /// seconds are up, and the schedule has to carry on across the hand-over to the hold's own
    /// loop.
    ///
    /// **Mutation (the original defect):** in `SetCommand.establish`, seed `heartbeats` with
    /// `session.clock.now()` instead of `kept.renewedAt`. Run: red on the longest silence — the
    /// hold's loop starts its own schedule, so the renewals are 10, 20 and then 35.
    @Test("An apply of 25 seconds sees a renewal at 10 and 20, and the schedule carries on")
    func anApplyOfTwentyFiveSeconds() async throws {
        let scene = await RenewalScene(applyTakes: .seconds(25))

        let code = try await scene.run()

        #expect(code == nil)
        let offsets = await scene.renewalOffsets()
        try #require(offsets.count >= 3, "\(offsets)")
        #expect(Array(offsets.prefix(2)) == [.seconds(10), .seconds(20)], "\(offsets)")
        #expect(await scene.authority.lapseInstants.isEmpty, "the lease never lapsed")
        #expect(await scene.authority.releaseInstants.count == 1, "the last interval has an end")
        #expect(
            await scene.longestSilence() <= .seconds(10),
            "one renewal schedule, across the hand-over, to the release: \(offsets)")
        let events = try scene.events().map { $0["event"] as? String }
        #expect(
            events == ["started", "holding", "holding", "holding", "ended"],
            "the hold runs its own thirty seconds from the moment it begins: \(events)")
    }

    /// An `apply` of 35 seconds is longer than the lease's lifetime. With renewals working the
    /// lease is kept the whole way, `started` is said, and the hold runs its course.
    ///
    /// **Mutation (the concurrent task removed):** in `SetCommand.establish`, delete the
    /// `await keeper.start()`. Run: red — nothing is waiting for the helper, so no renewal is ever
    /// sent and this clock stands still; `RenewalScene.run` reports a run that does not finish,
    /// and every test that waits for a renewal times out waiting for it. (In production time
    /// passes anyway, the lease lapses at 30 and `apply` is answered `leaseExpired`.)
    @Test("An apply of 35 seconds, with renewals working, keeps the lease and holds")
    func anApplyLongerThanTheLease() async throws {
        let scene = await RenewalScene(applyTakes: .seconds(35))

        let code = try await scene.run()

        #expect(code == nil, "\(scene.output.standardError)")
        let offsets = await scene.renewalOffsets()
        #expect(
            Array(offsets.prefix(3)) == [.seconds(10), .seconds(20), .seconds(30)], "\(offsets)")
        #expect(await scene.authority.lapseInstants.isEmpty, "the lease never lapsed")
        #expect(await scene.longestSilence() <= .seconds(10), "\(offsets)")
        let events = try scene.events()
        #expect(events.map { $0["event"] as? String }.first == "started")
        #expect(events.last?["event"] as? String == "ended")
        #expect(events.last?["endedBecause"] as? String == "durationElapsed")
        // The confirming snapshot is read after `apply` was answered, never while it works.
        let ledger = await scene.authority.ledger
        let answered = try #require(ledger.firstIndex(of: "apply answered"))
        let snapshots = ledger.enumerated().filter { $0.element == "snapshot received" }
        try #require(snapshots.count >= 2)
        #expect(snapshots[1].offset > answered, "the confirming snapshot follows the apply")
    }

    /// The same 35 seconds with a renewal that cannot land. The lease lapses, `apply` is answered
    /// that it has, and the run says **control was lost** — not that the helper refused the
    /// speed, which is a claim about a fan nothing observed. The safe state is looked at.
    ///
    /// **Mutation (a lapse routed as a refusal):** in `SetCommand.afterFailedApply`, skip the
    /// `lapse(afterApplyFault:)` branch. Run: red on `endedBecause` and the opening words
    /// (the exit is 6 either way: a lease fault classifies to `controlLost` on its own).
    @Test("An apply of 35 seconds whose renewals cannot land is a lapse, not a refusal")
    func aLapseIsNotARefusal() async throws {
        let scene = await RenewalScene(applyTakes: .seconds(35)) {
            await $0.failingRenewals(with: .helperFailed(detail: "the heartbeat could not land"))
        }
        let running = try scene.start()
        try await waitUntil("the first renewal reached the helper") {
            await scene.authority.calls.contains("renewLease")
        }
        // The keeper gave up on its first failed renewal, so nothing else moves this clock: the
        // helper works on for the rest of its 35 seconds.
        scene.time.finishHelperWork()
        let code = await running.value
        _ = scene.harness.sessions

        #expect(code == FanctlExitCode.controlLost.rawValue, "\(scene.output.standardError)")
        let events = try scene.events()
        #expect(events.map { $0["event"] as? String } == ["failed"], "nothing says started")
        let failed = try #require(events.first)
        #expect(failed["endedBecause"] as? String == "controlLost")
        #expect(failed["releaseAccepted"] is Bool, "the lease was given back, best effort")
        #expect(failed["snapshotFollowsRelease"] as? Bool == true, "the safe state was looked at")
        // The lease lapsed by time and nothing has swept it: a lookup is refused and changes
        // nothing, so the release is refused too, and it is the check's snapshot that sweeps.
        #expect(failed["releaseAccepted"] as? Bool == false)
        let message = scene.output.standardError
        #expect(message.hasPrefix("Control was lost before the hold began: control of lease "))
        #expect(message.contains("could no longer be shown to be held"))
        #expect(message.contains("the heartbeat could not land"))
        #expect(!message.contains("did not accept the speed"))
        #expect(!message.contains("refused"))
        #expect(!message.contains("Holding"))
        #expect(await scene.authority.lapseInstants.count == 1)
        #expect(
            await Harness.count("renewLease", in: scene.authority) == 1,
            "the first renewal that fails is final: nothing retries")
        #expect(await Harness.count("acquireLease", in: scene.authority) == 1, "never re-acquires")
        #expect(await Harness.count("apply", in: scene.authority) == 1)
        #expect(await Harness.count("releaseLease", in: scene.authority) == 1)
    }

    /// A renewal that failed while `apply` was working, with an `apply` that was then accepted
    /// and a snapshot that looks fine: the lease cannot be shown to be held, so it is not.
    @Test("A renewal that failed during an accepted apply is a lapse too")
    func aFailedRenewalAloneIsALapse() async throws {
        let scene = await RenewalScene(applyTakes: .seconds(20)) {
            await $0.failingRenewals(with: .helperFailed(detail: "the heartbeat could not land"))
        }
        let running = try scene.start()
        try await waitUntil("the first renewal reached the helper") {
            await scene.authority.calls.contains("renewLease")
        }
        scene.time.finishHelperWork()
        let code = await running.value
        _ = scene.harness.sessions

        #expect(code == FanctlExitCode.controlLost.rawValue, "\(scene.output.standardError)")
        let events = try scene.events()
        #expect(events.map { $0["event"] as? String } == ["failed"], "nothing says started")
        let message = scene.output.standardError
        #expect(message.hasPrefix("Control was lost before the hold began"))
        #expect(message.contains("The helper accepted the request to apply the speed."))
        #expect(await Harness.count("renewLease", in: scene.authority) == 1, "and final")
        #expect(await Harness.count("releaseLease", in: scene.authority) == 1)
        #expect(await scene.authority.lapseInstants.isEmpty, "the lease was still alive at 20")
    }

    // MARK: - A lease the helper says is gone

    /// A lease the helper says is gone is not a refusal of the speed, whichever way it says so.
    ///
    /// **Mutation (a lapse routed as a refusal):** in `SetCommand.lapse(afterApplyFault:renewal:)`
    /// return `nil` for the three lease faults. Run: red on every row.
    @Test(
        "An apply answered that the lease is gone is control lost, never a refusal",
        arguments: [
            AeolusXPCFault.leaseExpired, .leaseUnknown, .leaseNotHeldByThisConnection,
        ])
    func aLeaseThatIsGone(fault: AeolusXPCFault) async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingApply(with: fault)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.controlLost.rawValue, "\(fault)")
        let failed = try #require(try run.output.events().first)
        #expect(failed["endedBecause"] as? String == "controlLost", "\(fault)")
        let message = run.output.standardError
        #expect(message.hasPrefix("Control was lost before the hold began"), "\(fault)")
        #expect(!message.contains("did not accept"), "\(fault)")
        #expect(!message.contains("refused"), "\(fault)")
        _ = harness.sessions
    }

    // MARK: - The first renewal is scheduled from before acquireLease was sent

    /// The helper granted the lease at the start and its answer took 25 seconds to arrive. A
    /// schedule seeded when the answer came back would put the first renewal at 35, after the
    /// lease had lapsed at 30; one seeded when the request was sent has it due at 10, long
    /// overdue, and renews at once.
    ///
    /// **Mutation (`renewedAt` taken after the request):** in `SetCommand.perform`, move
    /// `let requestedAt = session.clock.now()` to after `acquireLease` returns. Run: red — the
    /// lease lapses at 30 and the run is a loss at the first heartbeat.
    @Test("The schedule starts when acquireLease was sent, not when its answer arrived")
    func theStampIsTakenBeforeTheRequest() async throws {
        let authority = SimulatedFanAuthority()
        let time = VirtualHoldTime()
        await authority.expiringLeases(after: RenewalScene.lifetime, on: time.clock)
        let reply = AsyncSignal()
        await authority.holdingAcquireReply(until: reply)
        let harness = ClientListenerHarness(authority: authority)
        let output = RecordingTerminal()
        let command = try Harness.command(
            Harness.thirtySeconds + ["--json"], endpoint: harness.endpoint, output: output,
            time: time, desk: SignalDesk())

        let running = Task { await exitCode { try await command.run() } }
        try await waitUntil("the lease was granted") { await authority.grantInstants.count == 1 }
        time.advance(by: .seconds(25))
        await reply.signal()
        let code = await running.value
        _ = harness.sessions

        #expect(code == nil, "\(output.standardError)")
        #expect(await authority.lapseInstants.isEmpty, "the lease never lapsed")
        let grant = try #require(await authority.grantInstants.first)
        let first = try #require(await authority.renewalInstants.first)
        #expect(first - grant <= .seconds(30), "the first renewal beat the helper's deadline")
    }

    // MARK: - A timer that cannot pace the heartbeat

    private struct TimerFailure: Error {}

    /// The keeper's wait fails with something that is not a cancellation while `apply` is
    /// outstanding. It cannot pace the heartbeat, so it stops renewing, and the run says so once
    /// `apply` has been answered. Control could no longer be shown to be held, before the hold
    /// began: released, the safe state looked at, and exit 6 or worse.
    ///
    /// **Mutation:** treat any failed wait as a stop in `LeaseKeeper.wait` (`return false`
    /// without recording it). Run: red — the run holds as if the timer had worked.
    @Test("A keeper whose timer fails is control lost before the hold, released and checked")
    func theKeepersTimerFails() async throws {
        let authority = SimulatedFanAuthority()
        let time = VirtualHoldTime()
        let apply = AsyncSignal()
        await authority.holdingApply(until: apply)
        let harness = ClientListenerHarness(authority: authority)
        let output = RecordingTerminal()
        var command = try Harness.command(
            Harness.thirtySeconds + ["--json"], endpoint: harness.endpoint, output: output,
            time: time, desk: SignalDesk())
        let parked = OSAllocatedUnfairLock(initialState: false)
        let failWait = AsyncSignal()
        let virtual = time.clock
        command.clock = SettleClock(
            now: virtual.now, sleep: virtual.sleep,
            waitOnHelper: { _ in
                parked.withLock { $0 = true }
                try await failWait.wait()
                throw TimerFailure()
            })

        let running = Task { await exitCode { try await command.run() } }
        try await waitUntil("the keeper waited for the helper") { parked.withLock { $0 } }
        await failWait.signal()
        await apply.signal()
        let code = await running.value
        _ = harness.sessions

        #expect(code == FanctlExitCode.controlLost.rawValue, "\(output.standardError)")
        let events = try output.events()
        #expect(events.map { $0["event"] as? String } == ["failed"], "nothing says started")
        #expect(events.first?["endedBecause"] as? String == "controlLost")
        #expect(events.first?["snapshotFollowsRelease"] as? Bool == true, "the check looked")
        #expect(output.standardError.contains("timer failed"))
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(await Harness.count("renewLease", in: authority) == 0)
    }

    // MARK: - Stopped in a coordinated way

    /// The apply is answered while a renewal is on the wire. The run waits for that renewal's
    /// answer before it releases anything, so the release can never be overtaken by a renewal,
    /// and no renewal is sent after it.
    ///
    /// **Mutation (the keeper not waited for):** in `LeaseKeeper.stop()`, delete
    /// `await loop?.value`. Run: red — the release arrives while the renewal is still parked.
    @Test(
        "A renewal on the wire when apply is answered is waited for, and none follows the release")
    func theKeeperIsStoppedInACoordinatedWay() async throws {
        // Renewals at 10, 20 and 30; the third is parked at the helper while the apply, which
        // takes 35, is answered.
        let renewal = AsyncSignal()
        let scene = await RenewalScene(applyTakes: .seconds(35)) {
            await $0.holdingRenewal(number: 3, until: renewal)
        }
        let running = try scene.start()
        try await waitUntil("the third renewal reached the helper") {
            await scene.authority.ledger.filter { $0 == "renewLease received" }.count == 3
        }
        scene.time.finishHelperWork()
        try await waitUntil("the apply was answered and the confirming snapshot read") {
            let ledger = await scene.authority.ledger
            return ledger.contains("apply answered")
                && ledger.filter { $0 == "snapshot received" }.count == 2
        }
        // Nothing may be released while the renewal is still on the wire. A mutant that does not
        // wait releases within milliseconds; this one has nothing to do but wait.
        try await Task.sleep(for: .milliseconds(300))
        let early = await scene.authority.ledger
        #expect(!early.contains("releaseLease received"), "released over a renewal in flight")
        await renewal.signal()
        let code = await running.value
        _ = scene.harness.sessions

        #expect(code == nil, "\(scene.output.standardError)")
        let ledger = await scene.authority.ledger
        let answered = ledger.enumerated().filter { $0.element == "renewLease answered" }
        let received = ledger.enumerated().filter { $0.element == "renewLease received" }
        let release = try #require(ledger.firstIndex(of: "releaseLease received"))
        try #require(answered.count >= 3)
        #expect(answered[2].offset < release, "the third renewal was answered before the release")
        #expect(
            received.allSatisfy { $0.offset < release },
            "no renewal was sent after the release")
        #expect(answered.count == received.count, "every renewal sent was answered")
    }
}
