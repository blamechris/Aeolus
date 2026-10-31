import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import fanctl

/// What `fanctl set` says of the fans after a loss, or the hold's timer failing: the safe-state
/// check's verdict, and nothing else. The rest of the words are `SetMessagesTests`.
@Suite("fanctl set's words after a loss during the hold")
struct SetHoldLossMessagesTests {

    typealias Fixtures = SafeStateTests
    typealias Shared = SetFixtures

    /// A release answered "accepted" says nothing of a restore the firmware refused, so "Nothing
    /// is held" is never said on its word. After a loss or a timer failure the text states the
    /// check's verdict and nothing else about the fans, and the release's own words (accepted, or
    /// not confirmed) stay what they are.
    ///
    /// **Mutation:** say "Nothing is held by this process now." for an accepted release in
    /// `SetMessages.lost`, or in `SetMessages.timerFailed`. Run: red on every row with an accepted
    /// release, four for each, whatever the check found: the check's verdict does not license the
    /// sentence, and neither does the release's answer.
    @Test("A loss or a timer failure never says 'Nothing is held', whatever the release said")
    func nothingIsHeldIsNotSaid() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let pinned = Fixtures.snapshot([
            Fixtures.fan(
                0, mode: .manualFixed, availability: .unavailable(.restoreToAutomaticFailed)),
            Fixtures.fan(1),
        ])
        let settlements = [
            Shared.settlement(Fixtures.automatic, verdict: .automatic),
            Shared.settlement(Fixtures.leasedManual, verdict: .notConfirmed),
            Shared.settlement(pinned, verdict: .cannotReturn(fans: [0])),
            Shared.settlement(nil, interruption: Shared.Gone()),
        ]
        for release in [SetCommand.Release.accepted, .failed("x")] {
            for settlement in settlements {
                let messages = [
                    SetMessages.lost(
                        .thermalEmergency, hold: hold, release: release, settlement: settlement),
                    SetMessages.timerFailed(hold: hold, release: release, settlement: settlement),
                ]
                for message in messages {
                    #expect(!message.contains("Nothing is held"), "\(settlement.verdict)")
                    #expect(
                        !message.contains("now reports"),
                        "a loss never says a clean ending's closing line")
                }
            }
        }
        // The check's own sentence is the only confirmation.
        let confirmed = SetMessages.lost(
            .reclaimed(fan: 0), hold: hold, release: .accepted,
            settlement: settlements[0])
        #expect(confirmed.contains("lists no manual-control lease and every fan automatic"))
        let pinnedMessage = SetMessages.lost(
            .reclaimed(fan: 0), hold: hold, release: .accepted, settlement: settlements[2])
        #expect(pinnedMessage.contains("(reason: restoreToAutomaticFailed)"))
        #expect(pinnedMessage.contains("docs/RECOVERY.md"))
    }

    /// During an emergency the helper reports its thermal protection in control of the fans, and
    /// the text says so in the helper's voice, beside what the check saw: its evidence is the
    /// emergency flag alone.
    @Test("A thermal emergency says the helper reports its thermal protection in control")
    func thermalProtectionIsInControl() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let emergency = SystemSnapshot(
            fans: [Fixtures.fan(0, mode: .manualFixed)], sensors: [], activeLease: nil,
            isThermalEmergencyActive: true, capturedAt: Fixtures.captured)

        let message = SetMessages.lost(
            .thermalEmergency, hold: hold, release: .accepted,
            settlement: Shared.settlement(emergency, verdict: .notConfirmed))

        #expect(
            message.contains(
                "The helper reports its thermal protection, not this run, in control of the fans."))
        #expect(!message.contains("is in control of the fans"), "the run's voice, not the helper's")
        #expect(message.contains("Fan 0 (reads manual) is not cleared"))
        #expect(message.contains("The helper reports a thermal emergency"))
    }
}
