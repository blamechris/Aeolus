import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import fanctl

/// The words `fanctl set` uses when the lease ended while the speed was being applied, and it was
/// released and the safe state looked at. The rest of the words are `SetMessagesTests`.
@Suite("fanctl set's words after an apply that did not hold")
struct SetApplyMessagesTests {

    typealias Fixtures = SafeStateTests
    typealias Shared = SetFixtures

    // MARK: - A lease that ended while the speed was being applied

    /// The lease lapsed during `apply`. That is control lost, in its own words: not a refusal,
    /// not "did not accept the speed", and not a claim about the fans.
    ///
    /// **Mutation:** build a lapse's message from `faultedApply`. Run: red.
    @Test("A lapse says control was lost, and never that the speed was refused")
    func lapseWording() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let lapses = [
            SetCommand.Lapse(renewalFailure: "the renewal was refused", apply: .accepted),
            SetCommand.Lapse(
                renewalFailure: "the renewal was refused", apply: .answered("the lease expired")),
            SetCommand.Lapse(renewalFailure: nil, apply: .answered("the lease expired")),
        ]
        for lapse in lapses {
            for verdict in [SafeState.Verdict.automatic, .notConfirmed] {
                let message = SetMessages.lapsed(
                    lapse, hold: hold, release: .failed("no such lease"),
                    settlement: Shared.settlement(Fixtures.automatic, verdict: verdict))
                #expect(message.hasPrefix("Control was lost before the hold began: lease "))
                #expect(message.contains(hold.leaseID.uuidString))
                #expect(message.contains("not renewed within 30 seconds"))
                #expect(message.contains("this run cannot say what it did to the fans"))
                #expect(!message.contains("did not accept"))
                #expect(!message.lowercased().contains("refused the speed"))
                #expect(!message.lowercased().contains("nothing was applied"))
                #expect(!message.contains("Nothing is held"))
            }
        }
    }

    /// What ended the lease is said once, in the helper's words, and whichever way this run
    /// learned of it: a renewal that failed, or `apply` saying so itself.
    @Test("A lapse says how this run learned the lease was gone, once")
    func lapseSaysHowItWasLearned() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let settlement = Shared.settlement(Fixtures.automatic, verdict: .automatic)

        let accepted = SetMessages.lapsed(
            SetCommand.Lapse(renewalFailure: "refused", apply: .accepted), hold: hold,
            release: .accepted, settlement: settlement)
        #expect(accepted.contains("A renewal of it failed: refused"))
        #expect(accepted.contains("The helper accepted the request to apply the speed."))

        let both = SetMessages.lapsed(
            SetCommand.Lapse(renewalFailure: "refused", apply: .answered("gone")), hold: hold,
            release: .accepted, settlement: settlement)
        #expect(both.contains("A renewal of it failed: refused"))
        #expect(both.contains("answered the request to apply the speed with: gone"))

        let alone = SetMessages.lapsed(
            SetCommand.Lapse(renewalFailure: nil, apply: .answered("XYZZY")), hold: hold,
            release: .accepted, settlement: settlement)
        #expect(!alone.contains("A renewal of it failed"))
        #expect(
            alone.contains("answered the request to apply the speed that the lease was gone: XYZZY")
        )
        #expect(alone.components(separatedBy: "XYZZY").count == 2, "said once, not twice")
    }
}
