import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set` when control is lost **before** `started`: every way that step ends short of a
/// hold is a lease that was taken and a speed that may have been sent, and none says what the fans
/// are doing. So each is released, the safe state is looked at, and the exit is the worse of 6 and
/// the check's verdict (9, then 8).
///
/// The case this suite exists for is the one the first hardware run is most likely to meet: the
/// fan is engaged, the first snapshot reads its mode as automatic (a register that has not caught
/// up), the release is answered accepted and its restore is refused. `set` used to say "Nothing is
/// held by this process now" and exit 6, and the operator never saw exit 9's recovery advice.
@Suite("fanctl set when control is lost before the hold began", .timeLimit(.minutes(1)))
struct FanctlSetLostBeforeHoldTests {

    typealias Harness = SetHarness

    // MARK: - B1: an accepted apply, and a snapshot that does not show it held

    /// `apply` is accepted and engages fan 0; the snapshot after it reads the mode as automatic
    /// with no target, beside `restoreToAutomaticFailed` (the restore of the fan was refused by
    /// the firmware); the release is answered accepted. Exit 9, with its recovery.
    ///
    /// **Mutation (the check skipped on this path):** in `SetCommand.afterLapse`, hand the
    /// report a constant `.automatic` settlement when the lapse has a `confirmation`. Run: red.
    @Test("An accepted apply, a snapshot showing no hold and a restore that failed is exit 9")
    func aSnapshotShowingNoHoldAndARestoreThatFailed() async throws {
        let authority = SimulatedFanAuthority()
        let gate = AsyncSignal()
        await authority.holdingApply(until: gate)
        await authority.ignoringApply()
        let harness = ClientListenerHarness(authority: authority)
        let output = RecordingTerminal()
        let command = try Harness.command(
            Harness.thirtySeconds + ["--json"], endpoint: harness.endpoint, output: output,
            time: VirtualHoldTime(), desk: SignalDesk())

        let running = Task { await exitCode { try await command.run() } }
        try await waitUntil("the apply reached the helper") {
            await authority.calls.contains("apply")
        }
        await authority.pin(0, as: .restoreToAutomaticFailed, reading: .automatic)
        await gate.signal()
        let code = await running.value
        _ = harness.sessions

        #expect(code == FanctlExitCode.cannotReturnToAutomatic.rawValue, "\(output.standardError)")
        let events = try output.events()
        #expect(events.map { $0["event"] as? String } == ["failed"], "nothing says started")
        let failed = try #require(events.first)
        #expect(failed["endedBecause"] as? String == "controlLost")
        #expect(failed["releaseAccepted"] as? Bool == true, "the release was accepted")
        #expect(failed["snapshotFollowsRelease"] as? Bool == true, "and the check looked")
        let failure = try #require(failed["failure"] as? [String: Any])
        #expect(failure["kind"] as? String == "cannotReturnToAutomatic")
        let message = output.standardError
        #expect(message.hasPrefix("Control was lost before the hold began: "))
        #expect(message.contains("The helper accepted the request to apply the speed."))
        #expect(message.contains("states no held target for fan 0"))
        #expect(message.contains("(reason: restoreToAutomaticFailed)"))
        #expect(message.contains("docs/RECOVERY.md"))
        #expect(!message.contains("Nothing is held"), "not said unless the check confirmed it")
        #expect(!message.contains("Holding"))
        let ledger = await authority.ledger
        let beforeRelease = try #require(ledger.firstIndex(of: "releaseLease received"))
        #expect(
            ledger[..<beforeRelease].filter { $0 == "snapshot received" }.count == 2,
            "the first snapshot after apply decided: nothing waited for a better one")
    }

    /// The snapshot after an accepted `apply` cannot be read, and neither can the check's: exit 8,
    /// and the text says the state is unknown rather than describing a snapshot it did not read.
    @Test("An accepted apply, a snapshot that fails and a check that cannot read is exit 8")
    func aSnapshotThatFailsAndACheckThatCannotRead() async throws {
        let authority = SimulatedFanAuthority()
        await authority.failingSnapshots(after: 1)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        let failed = try #require(try run.output.events().first)
        #expect(failed["endedBecause"] as? String == "controlLost")
        #expect(failed["snapshotFollowsRelease"] is NSNull, "nothing was read to qualify")
        let message = run.output.standardError
        #expect(message.contains("The snapshot read after it could not be read"))
        #expect(message.contains("is unknown"))
        #expect(!message.contains("Nothing is held"))
        _ = harness.sessions
    }

    /// The same snapshot failing once and the check reading fine: control lost, exit 6, with the
    /// check's own sentence and no claim that nothing is held.
    @Test("An accepted apply and a snapshot that fails once is exit 6 when the check confirms")
    func aSnapshotThatFailsOnce() async throws {
        let authority = SimulatedFanAuthority()
        await authority.failingSnapshots(after: 1, times: 1)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.controlLost.rawValue)
        let failed = try #require(try run.output.events().first)
        #expect(failed["snapshotFollowsRelease"] as? Bool == true)
        let message = run.output.standardError
        #expect(message.contains("lists no manual-control lease and every fan automatic"))
        #expect(!message.contains("Nothing is held"), "the check said it, in its own words")
        _ = harness.sessions
    }

    // MARK: - B2: a renewal that failed while apply was outstanding

    /// A renewal that times out makes the client give up the connection, and the `apply` in
    /// flight is then answered `connectionAbandoned`. That is "no answer", and nothing more, if
    /// the renewal is never looked at; the renewal failure is what this run knows about the lease,
    /// so it comes first. Exit 6, and the text states both facts.
    ///
    /// The shipping deadlines are used: a renewal gives up after five seconds, an `apply` for one
    /// fan after fifty-seven.
    ///
    /// **Mutation (the answer judged before the renewal):** in `SetCommand.afterFailedApply`,
    /// move the `renewal` check after the `answered` guard. Run: red — exit 1, and the renewal is
    /// never mentioned.
    @Test("A renewal that timed out during apply is control lost, with both facts in the text")
    func aRenewalTimesOutDuringApply() async throws {
        let renewal = AsyncSignal()
        let scene = await RenewalScene(applyTakes: .seconds(35)) {
            await $0.holdingRenewal(number: 1, until: renewal)
        }

        let running = try scene.start(deadlines: .default)
        let code = await running.value
        await renewal.signal()
        await scene.gate.signal()
        _ = scene.harness.sessions

        #expect(code == FanctlExitCode.controlLost.rawValue, "\(scene.output.standardError)")
        let events = try scene.events()
        #expect(events.map { $0["event"] as? String } == ["failed"], "nothing says started")
        let failed = try #require(events.first)
        #expect(failed["endedBecause"] as? String == "controlLost")
        #expect(failed["snapshotFollowsRelease"] as? Bool == true, "the check looked")
        let message = scene.output.standardError
        #expect(message.hasPrefix("Control was lost before the hold began: control of lease "))
        #expect(message.contains("A renewal of it failed while the speed was being applied"))
        #expect(message.contains("did not answer within"), "the renewal's own timeout")
        #expect(message.contains("The request to apply the speed then got no answer"))
        #expect(message.contains("may have applied it"))
        #expect(!message.contains("returned to automatic"))
        #expect(await Harness.count("renewLease", in: scene.authority) == 1)
        #expect(await Harness.count("releaseLease", in: scene.authority) == 1)
    }

    // MARK: - The simulated lapse and the sweep

    /// A lookup of a lapsed lease is refused and changes nothing; a sweep is what takes the lease.
    /// Here the supervisor's sweep has already run when `apply` looks again, so the answer is
    /// `leaseUnknown` and not `leaseExpired`, and both are the lease no longer being shown held.
    @Test("An apply answered leaseUnknown after the supervisor's sweep is the same loss")
    func theLeaseWasAlreadySwept() async throws {
        let scene = await RenewalScene(applyTakes: .seconds(35)) {
            await $0.failingRenewals(with: .helperFailed(detail: "the heartbeat could not land"))
        }
        let running = try scene.start()
        try await waitUntil("the first renewal reached the helper") {
            await scene.authority.calls.contains("renewLease")
        }
        // Past the lease's thirty seconds, and short of the end of the helper's work.
        scene.time.advance(by: .seconds(21))
        await scene.authority.sweepExpiredLeases()
        #expect(await scene.authority.lapseInstants.count == 1, "swept before apply looks again")
        scene.time.finishHelperWork()
        let code = await running.value
        _ = scene.harness.sessions

        #expect(code == FanctlExitCode.controlLost.rawValue, "\(scene.output.standardError)")
        let message = scene.output.standardError
        #expect(message.hasPrefix("Control was lost before the hold began"))
        #expect(!message.contains("did not accept"))
    }
}
