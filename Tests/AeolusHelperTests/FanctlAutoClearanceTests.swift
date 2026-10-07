import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl auto` against a helper whose snapshot says one thing in `mode` and another in the
/// availability beside it, and against a helper whose snapshot cannot be read at all — end to
/// end, the shipping `run()` over a real listener, as `FanctlAutoTests`.
///
/// **The combination under test is an ordinary helper output.** The helper reports an unreadable
/// `F<n>Md` as `automatic` (#178) and on Intel the register does not exist, while the
/// availability ladder restates `restoreToAutomaticFailed`, `handbackUnconfirmed` and
/// `supervisorBlind` with no guard on the mode. A fan can therefore read `automatic` and carry a
/// reason that says the helper has not cleared it, and reading the mode alone said exit 0 and,
/// on the first snapshot, sent no restore — the request that carries the `restoreAbandoned`
/// sweep, which is such a fan's only route out.
@Suite("fanctl auto: a reason beside a mode of automatic, and a snapshot that cannot be read")
struct FanctlAutoClearanceTests {

    private static func run(
        _ arguments: [String] = [], over harness: ClientListenerHarness
    ) async throws -> FanctlAutoTests.Run {
        try await FanctlAutoTests.run(arguments, over: harness)
    }

    // MARK: - 9, whatever the mode reads

    /// **Mutation:** compute the pinned fans in `SafeState.verdict(for:)` over the fans whose mode
    /// is not automatic only. Run: red — the exit is 8, not 9. The restore is still sent (so the
    /// restore assertion below stays green), because `isCleared` also refuses a fan that carries
    /// a reason; the exit-9 assertions are what hold the pinned filter.
    @Test("A durable reason beside a mode of automatic exits 9, and the one restore is sent")
    func aDurableReasonBesideAutomaticExitsNine() async throws {
        for reason: ManualControlAvailability.Reason in [
            .restoreToAutomaticFailed, .foreignManualControl,
        ] {
            let authority = SimulatedFanAuthority()
            await authority.pin(0, as: reason, reading: .automatic)
            let harness = ClientListenerHarness(authority: authority)

            let run = try await Self.run(over: harness)

            #expect(run.code == FanctlExitCode.cannotReturnToAutomatic.rawValue, "\(reason)")
            #expect(await authority.restoreRequests == 1, "\(reason): the restore was not sent")
            #expect(await authority.snapshotsServed == 12, "\(reason)")
            #expect(run.time.elapsed == .seconds(10), "\(reason)")
            #expect(await authority.modes().first == .automatic, "the fan still reads automatic")
            let diagnosis = run.output.standardError
            #expect(diagnosis.contains("Fan 0 (reads automatic)"), "\(reason)")
            #expect(diagnosis.contains("(reason: \(reason.wireValue))"), "\(reason)")
            #expect(!run.output.standardOutput.contains("now reports"), "\(reason)")
            #expect(!run.output.standardOutput.contains("No restore request was sent"))
        }
    }

    // MARK: - 8, whatever the mode reads

    /// **Mutation:** classify `.handbackUnconfirmed` as `silent` in `SafeState.clearance(of:)`.
    /// Run: red — exit 0, and no restore is sent.
    @Test("A pending reason beside a mode of automatic exits 8, and the one restore is sent")
    func aPendingReasonBesideAutomaticExitsEight() async throws {
        for reason: ManualControlAvailability.Reason in [
            .handbackUnconfirmed, .releaseInProgress, .restoreToAutomaticUnconfirmed,
        ] {
            let authority = SimulatedFanAuthority()
            await authority.pin(1, as: reason, reading: .automatic)
            let harness = ClientListenerHarness(authority: authority)

            let run = try await Self.run(over: harness)

            #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue, "\(reason)")
            #expect(await authority.restoreRequests == 1, "\(reason): the restore was not sent")
            #expect(run.time.elapsed == .seconds(10), "\(reason)")
            #expect(
                run.output.standardError.contains("Fan 1 (reads automatic) is not cleared"),
                "\(reason)")
            #expect(run.output.standardError.contains("(reason: \(reason.wireValue))"))
            #expect(!run.output.standardOutput.contains("now reports"), "\(reason)")
        }
    }

    /// A blind fan's state is unknown, not manual: 8, with the reason and its advice, and the
    /// restart that advice leads to.
    @Test("A blind fan exits 8, naming the reason and the restart")
    func aBlindFanExitsEight() async throws {
        let authority = SimulatedFanAuthority()
        await authority.pin(0, as: .supervisorBlind, reading: .automatic)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        #expect(await authority.restoreRequests == 1)
        let diagnosis = run.output.standardError
        let reason = ManualControlAvailability.Reason.supervisorBlind
        #expect(diagnosis.contains("(reason: supervisorBlind)"))
        #expect(diagnosis.contains(reason.recoveryAdvice))
        #expect(diagnosis.contains("launchctl bootout system/"))
        // Every fan reads automatic, so "did not report every fan automatic" would be untrue.
        #expect(diagnosis.contains("The helper has not cleared fan 0 (supervisorBlind)"))
        #expect(!diagnosis.contains("did not report every fan automatic"))
    }

    // MARK: - Exit 0, against today's helper

    /// **Today's real helper:** every fan reports `writePathNotBuilt`, and none is held. That
    /// must still be the safe state, with zero writes, or `auto` would exit non-zero on every
    /// machine that can be tested today.
    ///
    /// **Mutation:** classify `.writePathNotBuilt` as `pending` in `SafeState.clearance(of:)`.
    /// Run: red — a restore is sent and the run ends in 8.
    @Test("writePathNotBuilt on every fan, all automatic, exits 0 and sends nothing")
    func theShippingHelperExitsZeroWithNoWrites() async throws {
        let authority = SimulatedFanAuthority(fans: [
            SimulatedFanAuthority.fan(0, availability: .unavailable(.writePathNotBuilt)),
            SimulatedFanAuthority.fan(1, availability: .unavailable(.writePathNotBuilt)),
        ])
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == nil)
        #expect(await authority.restoreRequests == 0)
        #expect(await authority.snapshotsServed == 1)
        #expect(run.time.sleeps.isEmpty)
        #expect(run.output.standardOutput.contains("No restore request was sent."))
        #expect(run.output.standardError.isEmpty)
    }

    // MARK: - A snapshot that cannot be read after a handshake

    /// The handshake succeeded and the snapshot did not: the helper is identified, and its
    /// state is inconsistent — what `docs/SAFETY.md` § 7 says the panic verb must still serve.
    /// The one restore is sent, the wait runs, and a helper that still cannot give a snapshot
    /// ends in 8 with the way out that needs none.
    ///
    /// **Mutation:** return the classified failure without sending in
    /// `AutoCommand.afterUnreadableFirstSnapshot` (delete the `requestRestore` call there). Run:
    /// red — no restore reaches the authority, and the exit is not 8.
    @Test("A first snapshot that fails after a handshake still sends the restore once, then 8")
    func aFailedFirstSnapshotStillSendsTheRestore() async throws {
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.failingSnapshots(after: 0)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        #expect(await authority.restoreRequests == 1)
        #expect(await authority.snapshotsServed == 2, "the first, and the first of the wait")
        #expect(run.output.standardOutput.isEmpty)
        let diagnosis = run.output.standardError
        #expect(diagnosis.contains("completed its handshake but could not give a snapshot"))
        #expect(diagnosis.contains("`fanctl reset --all`"))
        #expect(diagnosis.contains("sent the request once"))
        #expect(diagnosis.contains("launchctl bootout system/"))
        let session = try #require(harness.sessions.first)
        #expect(await session.handshakeState != nil)
    }

    /// The failure was one snapshot long: the wait reads the helper again and decides.
    @Test("A first snapshot that fails once, then a wait that settles, exits 0 and says why")
    func aFailedFirstSnapshotCanStillSettle() async throws {
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.failingSnapshots(after: 0, times: 1)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(["--json"], over: harness)

        #expect(run.code == nil)
        #expect(await authority.restoreRequests == 1)
        #expect(await authority.modes() == [.automatic, .automatic])
        let document = try FanctlAutoTests.json(run)
        #expect(document["restoreRequested"] as? Bool == true)
        #expect(document["snapshotFollowsRestore"] as? Bool == true)
        #expect(document["endedLease"] is NSNull, "there was no first snapshot to compare with")
        #expect(document["failure"] is NSNull)
    }

    @Test("The text of that run names the first failure and the request")
    func aFailedFirstSnapshotIsSaidInText() async throws {
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.failingSnapshots(after: 0, times: 1)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == nil)
        let text = run.output.standardOutput
        #expect(text.contains("The helper's first snapshot failed"))
        #expect(text.contains("Asked the helper once"))
        #expect(text.contains("The helper now reports every fan automatic"))
    }

    // MARK: - A snapshot after the restore that cannot be read

    /// `fans` and `lease` are the pre-restore snapshot when the wait could not read another, and
    /// the document says so in a field rather than in `failure.message` alone.
    ///
    /// **Mutation:** encode `true` for `snapshotFollowsRestore` whatever the observation says.
    /// Run: red.
    @Test("--json says the snapshot predates the request when the wait could not read another")
    func documentSaysTheSnapshotPredatesTheRequest() async throws {
        let authority = SimulatedFanAuthority()
        await authority.grantForeignLease(over: [0], holder: "Aeolus.app 0.3.0")
        await authority.settling(afterSnapshots: 1_000)
        await authority.failingSnapshots(after: 1)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(["--json"], over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        #expect(await authority.restoreRequests == 1)
        let document = try FanctlAutoTests.json(run)
        #expect(document["restoreRequested"] as? Bool == true)
        #expect(document["snapshotFollowsRestore"] as? Bool == false)
        let lease = try #require(document["lease"] as? [String: Any])
        #expect(lease["holderDescription"] as? String == "Aeolus.app 0.3.0")
        // The prose beside the flag agrees with it.
        let message = try failureMessage(document)
        #expect(message.contains("was read before the restore request"))
        #expect(!message.contains("after the restore request, and is the last"))
    }

    /// The other mid-wait case: the helper answered two polls after the request and then went
    /// quiet. The snapshot shown *follows* the request, so the flag is true and the prose says
    /// so; it must not say the snapshot "may predate" a restore the run knows it read after.
    ///
    /// **Mutation:** in `AutoCommand.perform`, compute the flag as
    /// `settlement.interruption == nil`. Run: red — it is false here.
    @Test("--json keeps a post-request snapshot as one when the helper stops answering later")
    func aMidWaitFailureKeepsAPostRequestSnapshot() async throws {
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.settling(afterSnapshots: 1_000)
        await authority.failingSnapshots(after: 3)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(["--json"], over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        let document = try FanctlAutoTests.json(run)
        #expect(document["restoreRequested"] as? Bool == true)
        #expect(document["snapshotFollowsRestore"] as? Bool == true)
        let message = try failureMessage(document)
        #expect(message.contains("was read after the restore request, and is the last"))
        #expect(!message.contains("predate"))
        #expect(!message.contains("before the restore request"))
    }

    private func failureMessage(_ document: [String: Any]) throws -> String {
        let failure = try #require(document["failure"] as? [String: Any])
        return try #require(failure["message"] as? String)
    }

    // MARK: - A snapshot that times out after a handshake

    /// **Nothing is sent here, and the message says so first.** A snapshot the helper accepts and
    /// never answers makes the client give the connection up, and the handshake goes with it, so
    /// there is no identified helper to send a restore to. The cause the client reports is
    /// "the helper accepted this request and did not answer" — the *snapshot* — and read first it
    /// sounds like the return-to-automatic request, which a user would wait on.
    ///
    /// **Mutation:** put the cause before the first sentence in `AutoCommand.nothingSentMessage`
    /// (or drop "No restore request was sent."). Run: red on the prefix.
    @Test("A first snapshot that times out sends nothing, and the message opens by saying so")
    func aFirstSnapshotThatTimesOutSendsNothingAndSaysSo() async throws {
        let signal = AsyncSignal()
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.holdingSnapshots(until: signal)
        let harness = ClientListenerHarness(authority: authority)
        // Two seconds, and no upper bound asserted: a slow runner cannot make this shorter.
        let deadlines = HelperClientDeadlines(
            gatedVerb: .seconds(2), panicVerb: .seconds(10),
            handshakeVerb: HelperClientDeadlines.handshakeVerb)

        let run = try await FanctlAutoTests.run(over: harness, deadlines: deadlines)
        await signal.signal()

        #expect(run.code == FanctlExitCode.failure.rawValue)
        #expect(await authority.restoreRequests == 0, "a restore was sent to a dropped connection")
        let session = try #require(harness.sessions.first)
        #expect(await session.handshakeState != nil, "the handshake had succeeded")
        #expect(run.output.standardOutput.isEmpty)
        let message = run.output.standardError
        #expect(message.hasPrefix("No restore request was sent."), "\(message)")
        #expect(message.contains("did not answer"), "the cause is still given")
        #expect(message.contains("Run `fanctl reset --all`"))
    }
}
