import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// A loss once the hold is under way is released and **checked**, as everything before `started`
/// is: exit 6, or the check's verdict where that is worse (9, then 8).
///
/// It used to skip the check. A fan can be engaged, the release answered "accepted", its restore
/// refused, and "nothing is held" said over a fan that is still pinned: a claim nothing observed
/// (`CLAUDE.md` rule 6), by the tool the first hardware run relies on. The thermal emergency is
/// included: waiting out the check's ten seconds costs the fans nothing, because § 3 is driving
/// them either way, and an honest 8 or 9 is worth ten seconds.
///
/// Each kind of loss the hold can report is run twice. Once with a restore that failed, which
/// must be exit 9 with its recovery advice. Once with a lease the release did not end, which must
/// be exit 8. Where the check confirms every fan automatic the exit stays 6, and those tests are
/// `FanctlSetLossTests`.
@Suite("fanctl set checks the safe state after a loss during the hold", .timeLimit(.minutes(1)))
struct FanctlSetHoldLossCheckTests {

    typealias Harness = SetHarness

    /// The ways the hold can report a loss, each scripted to happen at the second heartbeat (the
    /// first renewal lands, and the fans are pinned there when asked to be).
    enum HoldLoss: CaseIterable, CustomStringConvertible {
        case renewalRefused
        case leaseNotListed
        case fanReclaimed
        case noHeldTarget
        case thermalEmergency

        var description: String {
            switch self {
            case .renewalRefused: return "renewalRefused"
            case .leaseNotListed: return "leaseNotListed"
            case .fanReclaimed: return "fanReclaimed"
            case .noHeldTarget: return "noHeldTarget"
            case .thermalEmergency: return "thermalEmergency"
            }
        }

        /// Whether the lease is still there after the loss, for the kinds that leave it so.
        var leavesTheLeaseListed: Bool {
            switch self {
            case .renewalRefused, .leaseNotListed: return false
            case .fanReclaimed, .noHeldTarget, .thermalEmergency: return true
            }
        }

        func script(_ authority: SimulatedFanAuthority) async {
            switch self {
            case .renewalRefused: await authority.refusingRenewal(after: 1)
            case .leaseNotListed: await authority.listingNoLease(afterRenewals: 2)
            case .fanReclaimed: await authority.reclaiming(after: 2)
            case .noHeldTarget: await authority.losingHeldTarget(afterRenewals: 2)
            case .thermalEmergency: await authority.emergency(afterRenewals: 2)
            }
        }
    }

    private static func run(
        _ authority: SimulatedFanAuthority
    ) async throws -> (Harness.Run, ClientListenerHarness) {
        let harness = ClientListenerHarness(authority: authority)
        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)
        return (run, harness)
    }

    /// The loss, then a release that is accepted while the restore of the fan failed: exit 9, the
    /// reason and its recovery advice, from a snapshot read after the release, and never "Nothing
    /// is held".
    ///
    /// **Mutation (a hold-phase loss skips the check):** in `SetCommand.finish`, hand a `.lost`
    /// end a constant `.automatic` settlement. Run: red — exit 6 and no look, for every kind.
    @Test(
        "A loss during the hold, with a restore that failed, is exit 9",
        arguments: HoldLoss.allCases)
    func aLossAndARestoreThatFailed(loss: HoldLoss) async throws {
        let authority = SimulatedFanAuthority()
        await authority.failingToRestore(afterRenewals: 1)
        await loss.script(authority)

        let (run, harness) = try await Self.run(authority)

        #expect(
            run.code == FanctlExitCode.cannotReturnToAutomatic.rawValue,
            "\(loss): \(run.output.standardError)")
        let events = try run.output.events()
        #expect(
            events.map { $0["event"] as? String } == ["started", "holding", "failed"],
            "the hold began, held for one heartbeat and then lost control: \(loss)")
        let failed = try #require(events.last)
        #expect(failed["endedBecause"] as? String == "controlLost", "\(loss)")
        #expect(failed["releaseAccepted"] as? Bool == true || !loss.leavesTheLeaseListed, "\(loss)")
        #expect(failed["snapshotFollowsRelease"] as? Bool == true, "the check looked: \(loss)")
        let failure = try #require(failed["failure"] as? [String: Any])
        #expect(failure["kind"] as? String == "cannotReturnToAutomatic", "\(loss)")
        let message = run.output.standardError
        #expect(message.hasPrefix("Control was lost: "), "\(loss)")
        #expect(message.contains("(reason: restoreToAutomaticFailed)"), "\(loss)")
        #expect(message.contains("docs/RECOVERY.md"), "\(loss)")
        #expect(!message.contains("Nothing is held"), "\(loss): \(message)")
        #expect(await Harness.count("acquireLease", in: authority) == 1, "never re-acquires")
        #expect(await Harness.count("releaseLease", in: authority) == 1, "\(loss)")
        _ = harness.sessions
    }

    /// The loss, then a release the helper did not take: the lease is still listed after the
    /// whole window, which is 8, and the text says whose lease it is. Not run for the two kinds
    /// that end the lease themselves (a renewal refused, a lease not listed).
    @Test(
        "A loss during the hold, with a lease still listed, is exit 8",
        arguments: HoldLoss.allCases.filter(\.leavesTheLeaseListed))
    func aLossAndALeaseStillListed(loss: HoldLoss) async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingRelease(with: .helperFailed(detail: "x"))
        await loss.script(authority)

        let (run, harness) = try await Self.run(authority)

        #expect(
            run.code == FanctlExitCode.safeStateNotConfirmed.rawValue,
            "\(loss): \(run.output.standardError)")
        #expect(
            run.time.sleeps.filter { $0 == .seconds(1) }.count == 10,
            "the whole window was waited out: \(loss)")
        let failed = try #require(try run.output.events().last)
        #expect(failed["endedBecause"] as? String == "controlLost", "\(loss)")
        #expect(failed["releaseAccepted"] as? Bool == false, "\(loss)")
        #expect(failed["snapshotFollowsRelease"] as? Bool == true, "\(loss)")
        let message = run.output.standardError
        #expect(message.hasPrefix("Control was lost: "), "\(loss)")
        #expect(message.contains("did not confirm the release"), "\(loss)")
        #expect(message.contains("this run's lease, which the release did not end"), "\(loss)")
        #expect(!message.contains("Nothing is held"), "\(loss): \(message)")
        _ = harness.sessions
    }

    /// During an emergency the helper's thermal protection is in control of the fans, and the
    /// text says so beside what the check saw: the lease still listed, and the emergency.
    @Test("A thermal emergency says the helper's thermal protection is in control")
    func theEmergencyText() async throws {
        let authority = SimulatedFanAuthority()
        await authority.emergency(afterRenewals: 2)
        await authority.refusingRelease(with: .helperFailed(detail: "x"))

        let (run, harness) = try await Self.run(authority)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        let message = run.output.standardError
        #expect(message.contains("thermal protection, not this run, is in control of the fans"))
        #expect(message.contains("The helper reports a thermal emergency, and its override"))
        _ = harness.sessions
    }

    /// The heartbeat's snapshot cannot be read, and neither can the check's: the state after the
    /// release is unknown, which is 8, and the text says so rather than describing a snapshot it
    /// did not read (`FanctlSetLossTests.aSnapshotFails` has the one the check can read: 6).
    @Test("A snapshot that fails mid-hold, with a check that cannot read, is exit 8")
    func aSnapshotFailsAndTheCheckCannotRead() async throws {
        let authority = SimulatedFanAuthority()
        await authority.failingSnapshots(after: 2)

        let (run, harness) = try await Self.run(authority)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        let failed = try #require(try run.output.events().last)
        #expect(failed["endedBecause"] as? String == "controlLost")
        #expect(
            failed["snapshotFollowsRelease"] as? Bool == false, "the hold's last, not the check's")
        let message = run.output.standardError
        #expect(message.contains("snapshot could not be read"))
        #expect(message.contains("is unknown"))
        #expect(!message.contains("Nothing is held"))
        _ = harness.sessions
    }

    /// Another client's lease is listed in place of ours, and the check after the release still
    /// sees it listed: the safe state is not confirmed, so the exit is 8 and not 6, and the
    /// holder is named by the loss and again by the check.
    @Test("A snapshot that lists someone else's lease is exit 8, and names the holder")
    func anotherLeaseIsListed() async throws {
        let authority = SimulatedFanAuthority()
        let other = Lease(holderDescription: "Aeolus.app 0.3.0", expiresAt: Date())
        await authority.listingNoLease(afterRenewals: 1, showing: other)

        let (run, harness) = try await Self.run(authority)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        let failed = try #require(try run.output.events().last)
        #expect(failed["endedBecause"] as? String == "controlLost")
        let message = run.output.standardError
        #expect(message.contains("a lease held by \"Aeolus.app 0.3.0\""))
        #expect(message.contains(other.id.uuidString))
        #expect(!message.contains("Nothing is held"))
        _ = harness.sessions
    }
}
