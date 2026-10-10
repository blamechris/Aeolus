import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// How a `fanctl set` hold that ended in the ordinary way is judged: by the same safe-state
/// check `fanctl auto` ends on (`SafeState`), after the release, with 0, 8 or 9.
///
/// One implementation serves both commands, so they cannot disagree about "confirmed". These
/// tests prove `set` really calls it — the polls, the window, the verdicts — and that no outcome
/// but 0 ever says the helper reports the fans returned.
@Suite("fanctl set's ending", .timeLimit(.minutes(1)))
struct FanctlSetEndingTests {

    typealias Harness = SetHarness

    // MARK: - 0: the helper reports the safe state

    /// The release lands after three polls: the check waits for it, a virtual second at a time,
    /// and then says so. The same `SafeState.settle` as `auto`.
    ///
    /// **Mutation:** in `SetCommand.finish`, replace the `SafeState.settle` call with a constant
    /// `.automatic` verdict. Run: red — no polls, and the snapshot count.
    @Test("A release that lands after three polls exits 0, having polled once a second")
    func theReleaseSettles() async throws {
        let authority = SimulatedFanAuthority()
        await authority.settling(afterReleaseSnapshots: 3)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds, over: harness)

        #expect(run.code == nil)
        #expect(
            run.time.sleeps == Array(repeating: .seconds(10), count: 3)
                + Array(repeating: .seconds(1), count: 3))
        // First, confirm, two heartbeats, and four reads after the release.
        #expect(await authority.snapshotsServed == 8)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(await Harness.count("restoreAllToAutomatic", in: authority) == 0)
        #expect(
            run.output.standardOutput.contains(
                "The helper now reports every fan automatic and no manual-control lease"))
        _ = harness.sessions
    }

    /// A signal during the release and the check is ignored: the loop is no longer looking, the
    /// polls run their course, and the exit is the check's.
    ///
    /// **Mutation:** in `SetCommand.finish`, skip the safe-state check when
    /// `session.interrupt.pending` is set. Run: red — the three polls never happen.
    @Test("A signal while waiting for the release changes nothing", .timeLimit(.minutes(1)))
    func aSignalDuringTheReleaseIsIgnored() async throws {
        let authority = SimulatedFanAuthority()
        await authority.settling(afterReleaseSnapshots: 3)
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let time = VirtualHoldTime(script: { number, _ in
            if number == 5 { desk.send(.interrupt) }
        })

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, desk: desk)

        #expect(run.code == nil)
        #expect(time.sleeps.count == 6, "the three polls ran: \(time.sleeps)")
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        let ended = try #require(try run.output.events().last)
        #expect(ended["endedBecause"] as? String == "durationElapsed", "the signal came too late")
        _ = harness.sessions
    }

    // MARK: - 8: not confirmed

    /// The release was refused, so the lease is still listed: this run's own, and the message
    /// says so. Not 5: `set` has no use for it, and the lease is its own.
    ///
    /// **Mutation:** map `.notConfirmed` to `.heldByAnotherClient` when a lease is listed, in
    /// `SetCommand.Report.ended`. Run: red.
    @Test("A release the helper refuses leaves the lease listed: exit 8, and whose it is")
    func theReleaseIsRefused() async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingRelease(with: .helperFailed(detail: "x"))
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        #expect(await Harness.count("releaseLease", in: authority) == 1, "released once, no more")
        #expect(
            run.time.sleeps.filter { $0 == .seconds(1) }.count == 10,
            "the whole window was waited out")
        let events = try run.output.events()
        #expect(events.last?["event"] as? String == "failed")
        let failed = try #require(events.last)
        #expect(failed["endedBecause"] as? String == "durationElapsed")
        #expect(failed["releaseAccepted"] as? Bool == false)
        #expect(failed["listedLeaseID"] as? String == events.first?["leaseID"] as? String)
        let message = run.output.standardError
        #expect(message.contains("did not confirm the release"))
        #expect(message.contains("this run's lease, which the release did not end"))
        #expect(message.contains("within 10 seconds of the release"))
        #expect(message.contains("fanctl auto"))
        #expect(message.contains("launchctl bootout system/"))
        _ = harness.sessions
    }

    @Test("Another client taking the fans after the release is exit 8, and names the holder")
    func anotherClientTakesTheFans() async throws {
        let authority = SimulatedFanAuthority()
        await authority.reacquiringAfterRelease(as: "Other 1.0")
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds, over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        let message = run.output.standardError
        #expect(message.contains("held by \"Other 1.0\""))
        #expect(message.contains("another client's lease, taken after this run's"))
        _ = harness.sessions
    }

    /// The helper stopped answering after the release: not the safe state, whatever the last
    /// snapshot said.
    ///
    /// **Mutation:** in `SafeState.settle`, return `.automatic` from the read's `catch`. Run:
    /// red — exit 0.
    @Test("A snapshot that fails after the release is exit 8")
    func theCheckCannotRead() async throws {
        let authority = SimulatedFanAuthority()
        await authority.failingSnapshots(after: 4)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        let failed = try #require(try run.output.events().last)
        #expect(failed["snapshotFollowsRelease"] as? Bool == false)
        #expect(
            run.output.standardError.contains(
                "The helper accepted the release and then stopped answering"))
        #expect(run.output.standardError.contains("No snapshot was read after the release"))
        _ = harness.sessions
    }

    /// **The review's probe, C2.** The helper accepts the release and then stops answering. The
    /// run exits 8, and the helper's own state says the lease is gone (`currentLease` is `nil`,
    /// because the release took) — so a text that went on to list the lease and a fan reading
    /// manual, from the snapshot taken *before* the release, told the user the opposite of what
    /// the helper had just accepted. It must say the state is unknown, and nothing of the old.
    ///
    /// **Mutation:** in `SetCommand.Report.ended`, hand the notConfirmed text the hold's last
    /// snapshot when the check read none (`SafeState.Settlement(verdict: settlement.verdict,
    /// snapshot: settlement.snapshot ?? before, polls: 0, interruption: settlement.interruption)`).
    /// Run: red on every negative assertion.
    @Test("After an accepted release and silence, the text does not describe the lease or the fans")
    func theCheckCannotReadSaysUnknown() async throws {
        let authority = SimulatedFanAuthority()
        await authority.failingSnapshots(after: 4)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds, over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        #expect(await authority.currentLease == nil, "the release took")
        let message = run.output.standardError
        #expect(message.contains("The helper accepted the release and then stopped answering"))
        #expect(message.contains("is unknown"))
        // The sentences of the first version, each a claim about the snapshot from before it.
        #expect(!message.contains("still listed"))
        #expect(!message.contains("which the release did not end"))
        #expect(!message.contains("is not cleared"))
        #expect(!message.contains("reads manual"))
        _ = harness.sessions
    }

    @Test("A fan still reading manual after the release is exit 8, and listed")
    func aFanStaysManual() async throws {
        let authority = SimulatedFanAuthority()
        await authority.settling(afterReleaseSnapshots: 1_000)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds, over: harness)

        #expect(run.code == 8)
        #expect(run.output.standardError.contains("Fan 0 (reads manual) is not cleared"))
        #expect(run.output.standardError.contains("This run renews nothing now"))
        _ = harness.sessions
    }

    // MARK: - 9: the helper reports a reason release cannot change

    /// Fan 1 is held by another program. The hold covers fan 0 only, ends, and the check sees
    /// fan 1: a reason releasing this lease will not change, whatever mode it reads.
    ///
    /// **Mutation:** map `.cannotReturn` to `.safeStateNotConfirmed` in `SetCommand.Report.ended`.
    /// Run: red.
    @Test("A fan another program holds is exit 9 after the hold, with the reason and its advice")
    func aForeignFanIsNine() async throws {
        let authority = SimulatedFanAuthority()
        await authority.markForeignManual(1)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.cannotReturnToAutomatic.rawValue)
        #expect(await Harness.count("acquireLease", in: authority) == 1)
        let reason = ManualControlAvailability.Reason.foreignManualControl
        let message = run.output.standardError
        #expect(message.contains("Fan 1"))
        #expect(message.contains(reason.userFacingSummary))
        #expect(message.contains(reason.recoveryAdvice))
        #expect(message.contains("(reason: foreignManualControl)"))
        #expect(message.contains("docs/RECOVERY.md"))
        #expect(!message.contains("launchctl bootout"), "stopping the helper does not free it")
        let failed = try #require(try run.output.events().last)
        #expect(failed["event"] as? String == "failed")
        let failure = try #require(failed["failure"] as? [String: Any])
        #expect(failure["kind"] as? String == "cannotReturnToAutomatic")
        _ = harness.sessions
    }

    @Test("A fan the firmware refused to hand back is exit 9 and points at the way out")
    func aRefusedHandbackIsNine() async throws {
        let authority = SimulatedFanAuthority()
        await authority.pin(1, as: .restoreToAutomaticFailed)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds, over: harness)

        #expect(run.code == 9)
        #expect(run.output.standardError.contains("(reason: restoreToAutomaticFailed)"))
        #expect(run.output.standardError.contains("launchctl bootout system/"))
        _ = harness.sessions
    }

    // MARK: - Nothing but 0 says the fans are fine

    /// Every outcome that is not the safe state, in both streams and in both formats, never says
    /// the helper reports the fans returned.
    ///
    /// **Mutation:** return `closingLine`'s sentence for every verdict from `Report.ended`.
    /// Run: red on the 8 and 9 rows.
    @Test("No outcome but exit 0 says the helper reports the fans automatic")
    func noFailureClaimsSuccess() async throws {
        struct Scenario {
            let name: String
            let code: Int32
            let script: @Sendable (SimulatedFanAuthority) async -> Void
        }
        let scenarios = [
            Scenario(name: "release refused", code: 8) {
                await $0.refusingRelease(with: .helperFailed(detail: "x"))
            },
            Scenario(name: "never settles", code: 8) {
                await $0.settling(afterReleaseSnapshots: 1_000)
            },
            Scenario(name: "another client", code: 8) {
                await $0.reacquiringAfterRelease(as: "Other 1.0")
            },
            Scenario(name: "pinned", code: 9) { await $0.markForeignManual(1) },
            Scenario(name: "lost", code: 6) { await $0.reclaiming(after: 1) },
            Scenario(name: "renewal refused", code: 6) { await $0.refusingRenewal(after: 0) },
        ]
        let claims = ["now reports", "in a snapshot it captured"]
        for scenario in scenarios {
            for json in [false, true] {
                let authority = SimulatedFanAuthority()
                await scenario.script(authority)
                let harness = ClientListenerHarness(authority: authority)

                let run = try await Harness.run(
                    Harness.thirtySeconds + (json ? ["--json"] : []), over: harness)

                #expect(run.code == scenario.code, "\(scenario.name) json=\(json)")
                let everything = run.output.lines.map(\.text).joined(separator: "\n")
                for claim in claims {
                    #expect(
                        !everything.contains(claim),
                        "\(scenario.name) json=\(json) says `\(claim)`")
                }
                _ = harness.sessions
            }
        }
    }
}
