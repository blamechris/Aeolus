import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// What `fanctl set` says of the fans after a lapse: only what the safe-state check found.
///
/// `leaseExpired`'s own description says the fans "have returned to automatic control". The helper
/// can throw it without having restored anything yet, and nothing in `set` observed it, so
/// repeating it would claim control state nothing confirmed (`CLAUDE.md` rule 6). After a lapse
/// `set` releases and runs the safe-state check, and the closing text states that check's verdict.
/// The phrase therefore never appears unless the check confirmed every fan automatic, and `set`
/// does not quote it even then: what it says then is the check's own sentence.
@Suite("fanctl set's words after a lapse", .timeLimit(.minutes(1)))
struct FanctlSetLapseWordingTests {

    typealias Harness = SetHarness

    private static let phrase = "returned to automatic"

    /// What a check that does not confirm can be: the fans never settle (8), or another program's
    /// fan is pinned (9).
    private enum Unconfirmed: CaseIterable {
        case neverSettles
        case aFanIsPinned

        var code: FanctlExitCode {
            switch self {
            case .neverSettles: return .safeStateNotConfirmed
            case .aFanIsPinned: return .cannotReturnToAutomatic
            }
        }

        func script(_ authority: SimulatedFanAuthority) async {
            switch self {
            case .neverSettles: await authority.settling(afterReleaseSnapshots: 1_000)
            case .aFanIsPinned: await authority.markForeignManual(1)
            }
        }
    }

    /// `apply` answers `leaseExpired`, and the check then does not confirm the safe state.
    ///
    /// **Mutation:** return the fault's own description in `SetCommand.describe`. Run: red on the
    /// phrase, in both rows.
    @Test("An apply answered leaseExpired never says the fans returned to automatic, unconfirmed")
    func anApplyAnsweredLeaseExpired() async throws {
        for case let unconfirmed in Unconfirmed.allCases {
            let authority = SimulatedFanAuthority()
            await authority.refusingApply(with: .leaseExpired)
            await unconfirmed.script(authority)
            let harness = ClientListenerHarness(authority: authority)

            let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

            #expect(run.code == unconfirmed.code.rawValue, "\(unconfirmed)")
            let message = run.output.standardError
            #expect(message.hasPrefix("Control was lost before the hold began"), "\(unconfirmed)")
            #expect(message.contains("lease had expired"), "the helper's answer is said")
            #expect(!message.contains(Self.phrase), "\(unconfirmed): \(message)")
            #expect(!message.contains("Acquire a new lease"), "\(unconfirmed)")
            _ = harness.sessions
        }
    }

    /// The same when it is a **renewal** that was answered `leaseExpired` while `apply` worked.
    ///
    /// **Mutation:** the same.
    @Test("A renewal answered leaseExpired during apply never says the fans returned, unconfirmed")
    func aRenewalAnsweredLeaseExpired() async throws {
        let scene = await RenewalScene(applyTakes: .seconds(35)) {
            await $0.failingRenewals(with: .leaseExpired)
            await $0.markForeignManual(1)
        }
        let running = try scene.start()
        try await waitUntil(
            "the first renewal reached the helper", timeout: StallTolerantWait.deliveryBudget
        ) {
            await scene.authority.calls.contains("renewLease")
        }
        scene.time.finishHelperWork()
        let code = await running.value
        _ = scene.harness.sessions

        #expect(code == FanctlExitCode.cannotReturnToAutomatic.rawValue)
        let message = scene.output.standardError
        #expect(
            message.contains(
                "A renewal of it failed while the speed was being applied: The helper answered that"
            ))
        #expect(!message.contains(Self.phrase), "\(message)")
        #expect(!message.contains("Acquire a new lease"))
    }

    /// When the check **does** confirm, the text says what the check found, in the helper's voice,
    /// and still does not borrow the fault's claim.
    @Test("When the check confirms every fan automatic, it is the check that says so")
    func whenTheCheckConfirms() async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingApply(with: .leaseExpired)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.controlLost.rawValue)
        let message = run.output.standardError
        #expect(message.contains("lists no manual-control lease and every fan automatic"))
        #expect(message.contains("as the helper reports it"))
        #expect(!message.contains(Self.phrase))
        _ = harness.sessions
    }
}
