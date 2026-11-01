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

    // MARK: - Control lost before the hold began

    /// Control was lost before the hold began. That is said in its own words: not a refusal, not
    /// "did not accept the speed", not a claim about the fans, and **not a claim that the lease
    /// ended**, which nobody saw: a reply that is not delivered leaves the lease live, and a
    /// renewal still in flight leaves it unknown. It could no longer be *shown* to be held.
    ///
    /// **Mutation:** say the lease "ended while the helper was applying the speed" again in
    /// `SetMessages.lapsed`. Run: red on the opening and on the absence of "ended".
    @Test("Control lost before the hold began says it could no longer be shown, not that it ended")
    func lapseWording() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let lapses = [
            SetCommand.Lapse(renewalFailure: "the renewal was refused", apply: .accepted),
            SetCommand.Lapse(
                renewalFailure: "the renewal was refused", apply: .answered("the lease expired")),
            SetCommand.Lapse(renewalFailure: nil, apply: .answered("the lease expired")),
            SetCommand.Lapse(
                renewalFailure: "the renewal timed out", apply: .unanswered("no answer")),
            SetCommand.Lapse(
                renewalFailure: nil, apply: .accepted, confirmation: .snapshotFailed("timed out")),
            SetCommand.Lapse(
                renewalFailure: nil, apply: .accepted, confirmation: .notHeld(.fanNotHeld(0))),
            SetCommand.Lapse(renewalFailure: nil, apply: .accepted, confirmation: .timerFailed),
        ]
        for lapse in lapses {
            for verdict in [SafeState.Verdict.automatic, .notConfirmed] {
                let message = SetMessages.lapsed(
                    lapse, hold: hold, release: .failed("no such lease"),
                    settlement: Shared.settlement(Fixtures.automatic, verdict: verdict))
                let opening =
                    "Control was lost before the hold began: control of lease "
                    + "\(hold.leaseID.uuidString) could no longer be shown to be held."
                #expect(message.hasPrefix(opening), "\(lapse)")
                #expect(!message.contains("ended"), "no end was seen: \(message)")
                #expect(message.contains("not renewed within 30 seconds"))
                #expect(message.contains("cannot say what it did to the fans"))
                #expect(!message.contains("did not accept"))
                #expect(!message.lowercased().contains("refused the speed"))
                #expect(!message.lowercased().contains("nothing was applied"))
                #expect(!message.contains("Nothing is held"))
            }
        }
    }

    /// What this run saw is said once each, in the helper's words, in the order it happened.
    @Test("Control lost before the hold began says each thing it saw, once")
    func lapseSaysWhatWasSeen() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let settlement = Shared.settlement(Fixtures.automatic, verdict: .automatic)
        func words(_ lapse: SetCommand.Lapse) -> String {
            SetMessages.lapsed(lapse, hold: hold, release: .accepted, settlement: settlement)
        }

        let accepted = words(SetCommand.Lapse(renewalFailure: "refused", apply: .accepted))
        #expect(
            accepted.contains("A renewal of it failed while the speed was being applied: refused"))
        #expect(accepted.contains("The helper accepted the request to apply the speed."))

        let both = words(SetCommand.Lapse(renewalFailure: "refused", apply: .answered("gone")))
        #expect(both.contains("A renewal of it failed while the speed was being applied: refused"))
        #expect(both.contains("answered the request to apply the speed with: gone"))

        let alone = words(SetCommand.Lapse(renewalFailure: nil, apply: .answered("XYZZY")))
        #expect(!alone.contains("A renewal of it failed"))
        #expect(
            alone.contains("answered the request to apply the speed that the lease was gone: XYZZY")
        )
        #expect(alone.components(separatedBy: "XYZZY").count == 2, "said once, not twice")

        // A renewal that failed and an `apply` that then went unanswered: both facts.
        let unanswered = words(
            SetCommand.Lapse(renewalFailure: "RENEWAL-TIMEOUT", apply: .unanswered("NO-ANSWER")))
        #expect(unanswered.contains("A renewal of it failed while the speed was being applied"))
        #expect(unanswered.contains("RENEWAL-TIMEOUT"))
        #expect(unanswered.contains("then got no answer, so the helper may have applied it"))
        #expect(unanswered.contains("NO-ANSWER"))

        // The snapshot after an accepted `apply`, in each way it can fail to show a hold.
        let unread = words(
            SetCommand.Lapse(
                renewalFailure: nil, apply: .accepted, confirmation: .snapshotFailed("TIMED-OUT")))
        #expect(unread.contains("The snapshot read after it could not be read: TIMED-OUT"))
        let notHeld = words(
            SetCommand.Lapse(
                renewalFailure: nil, apply: .accepted, confirmation: .notHeld(.fanNotHeld(3))))
        #expect(notHeld.contains("The snapshot read after it did not show control held: "))
        #expect(notHeld.contains("states no held target for fan 3"))
        let timer = words(
            SetCommand.Lapse(renewalFailure: nil, apply: .accepted, confirmation: .timerFailed))
        #expect(timer.contains("fanctl's timer failed"))
    }

    /// A signal that landed while the speed was being applied or confirmed is not lost from a
    /// failure that follows it. The pending signal is looked at once `apply` **and** the snapshot
    /// confirming it are answered, so it may have landed during either.
    @Test("A signal during apply is named in the text of the failure that follows")
    func signalNote() {
        #expect(SetMessages.signalNote(nil).isEmpty)
        #expect(
            SetMessages.signalNote(.interrupt)
                == "\n\nSIGINT was received while the speed was being applied or confirmed.")
    }

    /// `leaseExpired`'s own description says the fans "have returned to automatic control"; a
    /// restarted helper's says "any manual control it was holding ended with it; ask for the fans
    /// again"; a request nobody answered, and a connection given up, say the helper "returns those
    /// fans to automatic control when it handles that". Nobody observed any of that, and advice
    /// to ask again is no use to a run that never re-acquires, so `set` does not repeat them: it
    /// says what it saw.
    ///
    /// The negative assertions are the client's own words, checked against
    /// `HelperClientError.errorDescription` below, so a reworded description cannot leave them
    /// matching nothing.
    ///
    /// **Mutations**, each red: return the error's own description in `SetCommand.describe`;
    /// move `.helperNeverAnswered` to the `break` arm; move `.connectionAbandoned` to it.
    @Test(
        "A transport failure or an expired lease is described by what was seen, not by its claim"
    )
    func describedByWhatWasSeen() {
        let seen: [any Error] = [
            AeolusXPCFault.leaseExpired, HelperClientError.helperRestarted,
            HelperClientError.helperNeverAnswered(after: .seconds(57)),
            HelperClientError.connectionAbandoned,
        ]
        let claims = [
            "returned to automatic", "returns those fans", "when it handles that",
            "ended with it", "ask for the fans again", "Acquire a new lease",
        ]
        for error in seen {
            let words = SetCommand.describe(error)
            for claim in claims {
                #expect(!words.contains(claim), "\(error): \(words)")
            }
        }
        // Each claim is in the description it rules out, so none of the assertions above can
        // pass by matching nothing.
        let own = seen.map { ($0 as? LocalizedError)?.errorDescription ?? "" }.joined()
        for claim in claims {
            #expect(own.contains(claim), "no client description says \"\(claim)\" any more")
        }
        #expect(SetCommand.describe(AeolusXPCFault.leaseExpired).contains("expired"))
        #expect(
            SetCommand.describe(HelperClientError.helperRestarted).contains("interrupted"))
        // fanctl's words, which the client's own ("This copy of Aeolus …") do not contain.
        #expect(
            SetCommand.describe(HelperClientError.helperNeverAnswered(after: .seconds(57)))
                .contains("did not answer within 57"))
        #expect(
            SetCommand.describe(HelperClientError.helperNeverAnswered(after: .seconds(57)))
                .contains("this copy of fanctl gave up on the connection"))
        #expect(
            SetCommand.describe(HelperClientError.connectionAbandoned)
                .contains("This copy of fanctl gave up on its connection to the helper"))
        // Every other error is still its own words.
        let other = AeolusXPCFault.leaseUnknown
        #expect(SetCommand.describe(other) == other.errorDescription)
        let unread = HelperClientError.replyNotDelivered
        #expect(SetCommand.describe(unread) == unread.errorDescription)
    }
}
