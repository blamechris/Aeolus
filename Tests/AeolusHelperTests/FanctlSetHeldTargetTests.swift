import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set` says "holding" only when the helper says the fan is held.
///
/// The helper states a fan's `targetRPM` only while the same snapshot shows the fan in manual
/// under the live lease, with no reclamation and no thermal override (#426). That is its evidence
/// that a fan is held, so it is `set`'s: at the snapshot that confirms `apply`, and at every
/// heartbeat after it. The mode is never the evidence on its own (#178). The pure judgement is
/// `SetLossTests`; these are the same judgement run end to end.
@Suite("fanctl set needs the helper's held target", .timeLimit(.minutes(1)))
struct FanctlSetHeldTargetTests {

    typealias Harness = SetHarness

    /// What every loss for want of a held target shares: exit 6, one lease taken and given back,
    /// a fan the helper reports automatic with no target, and the words that say so.
    private static func expectNotHeld(
        _ run: Harness.Run, authority: SimulatedFanAuthority,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> [[String: Any]] {
        #expect(
            run.code == FanctlExitCode.controlLost.rawValue, sourceLocation: sourceLocation)
        #expect(
            await Harness.count("acquireLease", in: authority) == 1, "never re-acquires",
            sourceLocation: sourceLocation)
        #expect(
            await Harness.count("releaseLease", in: authority) == 1, "a best-effort release",
            sourceLocation: sourceLocation)
        let events = try run.output.events()
        let failed = try #require(events.last, sourceLocation: sourceLocation)
        #expect(failed["event"] as? String == "failed", sourceLocation: sourceLocation)
        #expect(
            failed["endedBecause"] as? String == "controlLost", sourceLocation: sourceLocation)
        let fan = try #require(
            (failed["fans"] as? [[String: Any]])?.first, sourceLocation: sourceLocation)
        let observed = try #require(
            fan["observed"] as? [String: Any], sourceLocation: sourceLocation)
        #expect(observed["mode"] as? String == "automatic", sourceLocation: sourceLocation)
        #expect(observed["targetRPM"] is NSNull, sourceLocation: sourceLocation)
        #expect(
            observed["isReclaimedBySystem"] as? Bool == false, "not marked, and still a loss",
            sourceLocation: sourceLocation)
        let message = run.output.standardError
        #expect(message.contains("states no held target for fan 0"), sourceLocation: sourceLocation)
        #expect(!message.contains("Holding"), sourceLocation: sourceLocation)
        return events
    }

    /// `apply` is accepted, the helper lists the lease, and the fan reads automatic with **no held
    /// target**: the firmware took it back and the reclamation watchdog has not marked it yet.
    /// That used to be `started`, and then `holding` every ten seconds, over a fan nothing was
    /// driving; a test held that to be right. Without a held target the hold is not said to exist.
    ///
    /// **Mutation:** delete the `fan.targetRPM` guard in `SetCommand.loss(in:leaseID:covering:)`.
    /// Run: red — the run holds, and exits 0.
    @Test("A fan the helper states no held target for is not holding, however the lease reads")
    func aFanWithoutAHeldTargetIsNotHeld() async throws {
        let authority = SimulatedFanAuthority()
        await authority.ignoringApply()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        let events = try await Self.expectNotHeld(run, authority: authority)
        #expect(
            events.map { $0["event"] as? String } == ["failed"],
            "`started` is not said over a fan the helper does not hold")
        #expect(await Harness.count("renewLease", in: authority) == 0, "the hold never began")
        // The planning snapshot and the confirming one, and no third: the snapshot after `apply`
        // cannot predate the engagement (ADR 0013, 2026-10-18), so the first one decides and
        // nothing waits for a better one.
        #expect(await authority.snapshotsServed == 2, "the first snapshot after apply decided")
        _ = harness.sessions
    }

    /// The lease is still listed, every renewal lands, and the fan stops carrying the helper's
    /// held target: the firmware took it back and nothing has marked it yet. The hold ends at
    /// that heartbeat, with no `holding` for it. This is the direction that ends a hold earlier.
    ///
    /// **Mutation:** delete the `fan.targetRPM` guard in `SetCommand.loss`. Run: red — the hold
    /// runs to its end and exits 0.
    @Test("A covered fan that stops carrying the helper's held target ends the hold")
    func theHeldTargetGoesAway() async throws {
        let authority = SimulatedFanAuthority()
        await authority.losingHeldTarget(afterRenewals: 1)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        let events = try await Self.expectNotHeld(run, authority: authority)
        #expect(events.map { $0["event"] as? String } == ["started", "failed"])
        #expect(await authority.renewals == 1)
        _ = harness.sessions
    }
}
