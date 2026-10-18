import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import fanctl

/// The words `fanctl set` uses when `apply` did not become a hold and the lease was released and
/// the safe state looked at: the helper answered with a fault, or the lease ended while the speed
/// was being applied. The rest of the words are `SetMessagesTests`.
@Suite("fanctl set's words after an apply that did not hold")
struct SetApplyMessagesTests {

    typealias Fixtures = SafeStateTests
    typealias Shared = SetFixtures

    // MARK: - An apply the helper answered with a fault

    /// "Did not accept the speed" is a statement about the fans, and the check that follows is
    /// what earns it. Level 6 can engage a fan, fail on the next, have the undo refused and answer
    /// only the original fault, so the words are said **only** for a verdict of `.automatic`.
    ///
    /// **Mutation:** return the `.automatic` lead for every verdict in
    /// `SetMessages.faultedApplyLead`. Run: red on the `notConfirmed` and `cannotReturn` rows.
    @Test("'Did not accept the speed' is said only when the check found every fan automatic")
    func faultedApplyWording() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let failure = HelperCommandFailure(
            .manualControlRefused, "Fan 0 cannot be controlled: its bounds are not usable.")
        let pinned = Fixtures.snapshot([
            Fixtures.fan(0, availability: .unavailable(.restoreToAutomaticFailed)),
            Fixtures.fan(1),
        ])
        let rows: [(SafeState.Settlement, expectsClean: Bool)] = [
            (Shared.settlement(Fixtures.automatic, verdict: .automatic), true),
            (Shared.settlement(Fixtures.leasedManual, verdict: .notConfirmed), false),
            (Shared.settlement(pinned, verdict: .cannotReturn(fans: [0])), false),
            (Shared.settlement(nil, interruption: Shared.Gone()), false),
        ]
        for (settlement, expectsClean) in rows {
            let message = SetMessages.faultedApply(
                failure, hold: hold, release: .accepted, settlement: settlement)
            #expect(message.contains("its bounds are not usable"), "the helper's words survive")
            #expect(message.contains("The helper accepted the release"))
            #expect(!message.contains("Nothing is held"))
            #expect(!message.lowercased().contains("nothing was applied"))
            #expect(
                message.contains("did not accept the speed") == expectsClean,
                "\(settlement.verdict): \(message)")
            #expect(
                message.contains("does not say whether the speed reached a fan") == !expectsClean)
        }
    }

    @Test("A fault followed by a pinned fan reports the pinned fan and its recovery")
    func faultedApplyThenPinned() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let pinned = Fixtures.snapshot([
            Fixtures.fan(
                0, mode: .manualFixed, availability: .unavailable(.restoreToAutomaticFailed)),
            Fixtures.fan(1),
        ])

        let message = SetMessages.faultedApply(
            HelperCommandFailure(.manualControlRefused, "refused"), hold: hold,
            release: .accepted,
            settlement: Shared.settlement(pinned, verdict: .cannotReturn(fans: [0])))

        #expect(message.contains("(reason: restoreToAutomaticFailed)"))
        #expect(message.contains("docs/RECOVERY.md"))
        #expect(message.contains("launchctl bootout system/"))
    }

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
