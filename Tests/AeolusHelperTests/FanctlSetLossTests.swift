import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set` when control is lost: exit 6, a best-effort release first, and **never a retry,
/// never a second `acquireLease`**.
///
/// A lease is the proof that something still wants the fans. A process that took it back after
/// losing it would be deciding, alone, that it still does, over a machine the helper may have
/// taken the fans from for a reason. Every test here asserts the one `acquireLease` as well as
/// the exit, because the exit alone would be satisfied by a command that re-acquired and then
/// failed anyway.
@Suite("fanctl set when control is lost", .timeLimit(.minutes(1)))
struct FanctlSetLossTests {

    typealias Harness = SetHarness

    /// The assertions every loss shares. Returns the `failed` event.
    private static func expectLost(
        _ run: Harness.Run, authority: SimulatedFanAuthority,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> [String: Any] {
        #expect(run.code == 6, "exit 6", sourceLocation: sourceLocation)
        #expect(
            await Harness.count("acquireLease", in: authority) == 1,
            "never re-acquires", sourceLocation: sourceLocation)
        #expect(
            await Harness.count("apply", in: authority) == 1,
            "never applies a second time", sourceLocation: sourceLocation)
        #expect(
            await Harness.count("releaseLease", in: authority) == 1,
            "a best-effort release, once", sourceLocation: sourceLocation)
        #expect(
            await Harness.count("restoreAllToAutomatic", in: authority) == 0,
            "set never sends the panic verb", sourceLocation: sourceLocation)
        let events = try run.output.events()
        let closing = events.filter { ["ended", "failed"].contains($0["event"] as? String) }
        #expect(closing.count == 1, "exactly one closing event", sourceLocation: sourceLocation)
        let failed = try #require(closing.first, sourceLocation: sourceLocation)
        #expect(failed["event"] as? String == "failed", sourceLocation: sourceLocation)
        #expect(failed["endedBecause"] as? String == "controlLost", sourceLocation: sourceLocation)
        let failure = try #require(
            failed["failure"] as? [String: Any], sourceLocation: sourceLocation)
        #expect(failure["exitCode"] as? Int == 6, sourceLocation: sourceLocation)
        #expect(failure["kind"] as? String == "controlLost", sourceLocation: sourceLocation)
        #expect(failed["releaseAccepted"] is Bool, sourceLocation: sourceLocation)
        #expect(
            !run.output.standardError.contains("The helper now reports"),
            "a loss never says the fans are fine", sourceLocation: sourceLocation)
        return failed
    }

    private static func run(
        _ authority: SimulatedFanAuthority, arguments: [String] = Harness.thirtySeconds,
        time: VirtualHoldTime = VirtualHoldTime(), desk: SignalDesk = SignalDesk()
    ) async throws -> Harness.Run {
        let harness = ClientListenerHarness(authority: authority)
        let run = try await Harness.run(
            arguments + ["--json"], over: harness, time: time, desk: desk)
        #expect(!harness.sessions.isEmpty)
        return run
    }

    // MARK: - What the helper reports

    /// **Mutation:** in `SetCommand.heartbeats`, `try?` the renewal and carry on. Run: red — the
    /// hold runs to the end and exits 0.
    @Test("A renewal the helper refuses is exit 6, after the heartbeat before it")
    func aRenewalIsRefused() async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingRenewal(after: 1)

        let run = try await Self.run(authority)

        let failed = try await Self.expectLost(run, authority: authority)
        #expect(await authority.renewals == 1)
        #expect(Harness.event("holding", in: try run.output.events()).count == 1)
        #expect(run.output.standardError.contains("did not renew lease"))
        #expect(failed["leaseID"] is String)
    }

    /// Whatever the error, once a lease is held: a renewal that went unanswered or failed in
    /// some other way leaves this client unable to say it holds the fans.
    @Test("A renewal that fails in any other way is exit 6 too")
    func anyRenewalError() async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingRenewal(after: 0, with: .helperFailed(detail: "x"))

        let run = try await Self.run(authority)

        _ = try await Self.expectLost(run, authority: authority)
        #expect(await authority.renewals == 0)
    }

    /// The renewal succeeds and the snapshot does not list our lease: the helper ended it and
    /// said so nowhere else.
    ///
    /// **Mutation:** in `SetCommand.loss(in:leaseID:covering:)`, drop the lease-ID comparison
    /// (`guard snapshot.activeLease != nil`). Run: red on the second test, where another
    /// client's lease is listed.
    @Test("A snapshot that lists no lease is exit 6")
    func theLeaseIsNotListed() async throws {
        let authority = SimulatedFanAuthority()
        await authority.listingNoLease(afterRenewals: 1)

        let run = try await Self.run(authority)

        _ = try await Self.expectLost(run, authority: authority)
        #expect(run.output.standardError.contains("no longer lists lease"))
        #expect(run.output.standardError.contains("It lists no lease."))
    }

    @Test("A snapshot that lists someone else's lease is exit 6, and names the holder")
    func anotherLeaseIsListed() async throws {
        let authority = SimulatedFanAuthority()
        let other = Lease(holderDescription: "Aeolus.app 0.3.0", expiresAt: Date())
        await authority.listingNoLease(afterRenewals: 1, showing: other)

        let run = try await Self.run(authority)

        _ = try await Self.expectLost(run, authority: authority)
        #expect(run.output.standardError.contains("a lease held by \"Aeolus.app 0.3.0\""))
        #expect(run.output.standardError.contains(other.id.uuidString))
    }

    /// `isReclaimedBySystem` on a fan the lease covers. The text says Aeolus is not driving it,
    /// whatever the target says.
    ///
    /// **Mutation:** delete the `isReclaimedBySystem` check in `SetCommand.loss`. Run: red.
    @Test("A covered fan reclaimed by the system is exit 6")
    func aFanIsReclaimed() async throws {
        let authority = SimulatedFanAuthority()
        await authority.reclaiming(after: 1)

        let run = try await Self.run(authority)

        _ = try await Self.expectLost(run, authority: authority)
        #expect(run.output.standardError.contains("fan 0 reclaimed by the system"))
        #expect(run.output.standardError.contains("whatever the target says"))
        #expect(run.output.standardOutput.contains("\"isReclaimedBySystem\":true"))
    }

    /// **Mutation:** delete the `isThermalEmergencyActive` check in `SetCommand.loss`. Run: red.
    @Test("A thermal emergency is exit 6")
    func aThermalEmergency() async throws {
        let authority = SimulatedFanAuthority()
        await authority.emergency(afterRenewals: 1)

        let run = try await Self.run(authority)

        _ = try await Self.expectLost(run, authority: authority)
        #expect(run.output.standardError.contains("thermal emergency"))
    }

    /// An emergency that is already active when the lease is confirmed: the helper's override
    /// outranks the hold before it has begun, and `started` is never said.
    @Test("A thermal emergency already active at the confirming snapshot is exit 6")
    func anEmergencyAtConfirmation() async throws {
        let authority = SimulatedFanAuthority()
        await authority.setThermalEmergency(true)

        let run = try await Self.run(authority)

        _ = try await Self.expectLost(run, authority: authority)
        #expect(try run.output.events().map { $0["event"] as? String } == ["failed"])
        #expect(run.output.standardError.contains("thermal emergency"))
    }

    /// A snapshot that cannot be read leaves this run unable to say it holds the fans.
    ///
    /// **Mutation:** in `SetCommand.heartbeats`, `try?` the snapshot. Run: red.
    @Test("A snapshot that fails mid-hold is exit 6")
    func aSnapshotFails() async throws {
        let authority = SimulatedFanAuthority()
        await authority.failingSnapshots(after: 2)

        let run = try await Self.run(authority)

        _ = try await Self.expectLost(run, authority: authority)
        #expect(run.output.standardError.contains("snapshot could not be read"))
    }

    /// Control is held from the moment `apply` is accepted, so a snapshot that cannot confirm it
    /// is a loss, and `started` is never said.
    ///
    /// **Mutation:** in `SetCommand.perform`, skip the loss check on the confirming snapshot.
    /// Run: red on the second test.
    @Test("A confirming snapshot that fails is exit 6, and nothing says started")
    func theConfirmingSnapshotFails() async throws {
        let authority = SimulatedFanAuthority()
        await authority.failingSnapshots(after: 1)

        let run = try await Self.run(authority)

        _ = try await Self.expectLost(run, authority: authority)
        #expect(try run.output.events().map { $0["event"] as? String } == ["failed"])
        #expect(await authority.renewals == 0)
    }

    @Test("A confirming snapshot that lacks our lease is exit 6, and nothing says started")
    func theConfirmingSnapshotLacksTheLease() async throws {
        let authority = SimulatedFanAuthority()
        await authority.listingNoLease(afterRenewals: 0)

        let run = try await Self.run(authority)

        _ = try await Self.expectLost(run, authority: authority)
        #expect(try run.output.events().map { $0["event"] as? String } == ["failed"])
    }

    // MARK: - A helper that restarts under the hold

    /// The helper restarts mid-hold. The lease is bound to the connection that acquired it, so
    /// the new session knows nothing of it; the client reconnects, and the command must not take
    /// that as leave to ask again.
    ///
    /// **This is the simulated-helper gap #317 names:** exactly one `acquireLease`, and exit 6.
    ///
    /// **Mutation:** in `SetCommand.perform`, call `acquireLease` and `apply` again when a
    /// renewal fails. Run: red — two acquires.
    @Test("A helper that restarts mid-hold is exit 6 with exactly one acquireLease")
    func theHelperRestarts() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let atTheSecondHeartbeat = AsyncSignal()
        let restarted = AsyncSignal()
        let time = VirtualHoldTime(script: { number, _ in
            guard number == 2 else { return }
            await atTheSecondHeartbeat.signal()
            try await restarted.wait()
        })
        let output = RecordingTerminal()
        let command = try Harness.command(
            Harness.thirtySeconds + ["--json"], endpoint: harness.endpoint, output: output,
            time: time, desk: SignalDesk())

        let running = Task { await exitCode { try await command.run() } }
        try await atTheSecondHeartbeat.wait()
        harness.killHelperSideOfEveryConnection()
        try await waitUntil("the helper noticed the connection went away") {
            await authority.calls.contains("connectionDidInvalidate")
        }
        await restarted.signal()
        let code = await running.value

        #expect(code == 6)
        #expect(await Harness.count("acquireLease", in: authority) == 1)
        #expect(await Harness.count("apply", in: authority) == 1)
        #expect(await authority.renewals == 1, "the second renewal never reached a lease")
        let events = try output.events()
        let closing = events.filter { ["ended", "failed"].contains($0["event"] as? String) }
        #expect(closing.count == 1)
        #expect(closing.first?["endedBecause"] as? String == "controlLost")
        #expect(output.standardError.contains("This process renews nothing now"))
        #expect(harness.sessions.count >= 2, "libxpc reconnected to a new session")
    }

    // MARK: - Refused

    /// The helper took the lease and refused the speed: release it, and leave with the code
    /// `apply`'s failure classifies to.
    ///
    /// **Mutation:** delete the release on the `apply` failure path in `SetCommand.perform`.
    /// Run: red — no `releaseLease`.
    @Test("A refused apply releases the lease and exits with apply's own code")
    func applyIsRefused() async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingApply(with: .boundsImplausible(fanIndex: 0, detail: "x"))
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.manualControlRefused.rawValue)
        #expect(await Harness.count("acquireLease", in: authority) == 1)
        #expect(await Harness.count("apply", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(await Harness.count("renewLease", in: authority) == 0)
        #expect(await authority.currentLease == nil)
        let events = try run.output.events()
        #expect(events.map { $0["event"] as? String } == ["failed"], "nothing says started")
        let failed = try #require(events.first)
        #expect(failed["endedBecause"] as? String == "refused")
        #expect(failed["leaseID"] is String)
        #expect(failed["releaseAccepted"] as? Bool == true)
        let failure = try #require(failed["failure"] as? [String: Any])
        #expect(failure["kind"] as? String == "manualControlRefused")
        #expect(run.output.standardError.contains("did not accept the speed"))
        _ = harness.sessions
    }

    @Test("apply's code is whatever its failure classifies to")
    func applyCodes() async throws {
        let cases: [(AeolusXPCFault, FanctlExitCode)] = [
            (.invalidParameter(name: "x", detail: "y"), .requestDoesNotFit),
            (.manualControlUnavailable(reason: .writePathNotBuilt), .manualControlRefused),
            (.leaseExpired, .controlLost),
            (.helperFailed(detail: "x"), .failure),
        ]
        for (fault, expected) in cases {
            let authority = SimulatedFanAuthority()
            await authority.refusingApply(with: fault)
            let harness = ClientListenerHarness(authority: authority)

            let run = try await Harness.run(Harness.thirtySeconds, over: harness)

            #expect(run.code == expected.rawValue, "\(fault)")
            #expect(await Harness.count("releaseLease", in: authority) == 1, "\(fault)")
            #expect(await Harness.count("acquireLease", in: authority) == 1, "\(fault)")
            _ = harness.sessions
        }
    }

    /// An `apply` the helper took and never answered. The helper may have written the speed, so
    /// "did not accept the speed" and `refused` would say something nothing observed. The lease
    /// is given back, the safe-state check looks, and the exit is the code the failure
    /// classifies to (a restart: 1), reported as `controlLost`.
    ///
    /// **Mutation:** treat every `apply` error as an answer in `SetCommand.helperAnswered`
    /// (`true`). Run: red — the run says it was refused and does not look.
    @Test("An apply nobody answers is released and checked, and is not called a refusal")
    func applyGetsNoAnswer() async throws {
        let authority = SimulatedFanAuthority()
        let gate = AsyncSignal()
        await authority.holdingApply(until: gate)
        let harness = ClientListenerHarness(authority: authority)
        let output = RecordingTerminal()
        let command = try Harness.command(
            Harness.thirtySeconds + ["--json"], endpoint: harness.endpoint, output: output,
            time: VirtualHoldTime(), desk: SignalDesk())

        let running = Task { await exitCode { try await command.run() } }
        try await waitUntil("the apply reached the helper") {
            await authority.calls.contains("apply")
        }
        harness.killHelperSideOfEveryConnection()
        let code = await running.value
        await gate.signal()

        #expect(code == FanctlExitCode.failure.rawValue, "the failure's own code, not 0")
        #expect(await Harness.count("acquireLease", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1, "given back, best effort")
        let events = try output.events()
        #expect(events.map { $0["event"] as? String } == ["failed"], "nothing says started")
        let failed = try #require(events.first)
        #expect(failed["endedBecause"] as? String == "controlLost")
        #expect(failed["leaseID"] is String)
        #expect(failed["snapshotFollowsRelease"] as? Bool == true, "the safe-state check looked")
        let message = output.standardError
        #expect(message.contains("did not answer the request to apply the speed"))
        #expect(message.contains("may have applied it"))
        #expect(!message.contains("did not accept the speed"))
        #expect(!message.contains("refused"))
        #expect(!message.contains("Nothing is held"))
        #expect(harness.sessions.count >= 2, "libxpc reconnected to a new session")
    }
}
