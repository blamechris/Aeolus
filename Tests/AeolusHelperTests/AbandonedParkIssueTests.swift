import Foundation
import Testing

@testable import AeolusHelper

/// The issue a park records when nobody lets it through says how long it waited, how much stall
/// it rode out, and whether the cap ended it
/// ([#559](https://github.com/blamechris/Aeolus/issues/559)).
///
/// `AsyncSignal.wait(atMost:)` is a `StallTolerantWait` poll since #549, so a park that gives up
/// after a stall has waited for neither the `parkCeiling` it was given nor a time the constant
/// says: a 40 s stall lands, the park reaches the 50 s cap, and an issue that printed the ceiling
/// would call that 10 s and name no cause. The `Expiry` the poll returns is what the issue is
/// written from, the same wording `waitUntil` uses for a wait that gave up.
///
/// Each test parks on a signal nobody sends, on a `VirtualWaitClock` that stalls as the test
/// chose, and records the issue as a double would (`recordAbandonedPark`). A 50 s cap costs
/// microseconds on that clock and blocks no thread.
///
/// **Mutation (1):** in `recordAbandonedPark`, replace the `expiry.message(waitingFor:)`
/// interpolation with "for \(parkCeiling)" and leave `expiry` unused, which is the message that
/// printed the ceiling constant. Run: red in all three tests, on the "timed out …" fragment.
/// **Mutation (2):** in `wait(atMost:clock:)`, hand `gaveUp.abandon(after:)` an `Expiry` built from
/// the constants (`waited: ceiling`, `stall: .zero`, `capHit: false`) in place of the poll's. Run:
/// red in the stall test and the cap test, which the constants cannot say, and green in the
/// no-stall test, which they can.
@Suite(
    "An abandoned park's issue says what it waited and what it rode out",
    .timeLimit(.minutes(1)))
struct AbandonedParkIssueTests {

    /// Parks on a signal nobody sends, on `clock`, and records the issue a double records when
    /// the park is abandoned. Anything else the park does is an issue of its own.
    private static func abandonAPark(on clock: VirtualWaitClock) async throws {
        switch try await AsyncSignal().wait(atMost: parkCeiling, clock: clock) {
        case .abandoned(let expiry):
            recordAbandonedPark(by: "ParkingDouble", of: .everyFan, after: expiry)
        case .signalled:
            Issue.record("a park nobody released reported that it was signalled")
        }
    }

    /// "No stall" is a statement and not an omission, as it is in `waitUntil`'s timeout.
    @Test("A park with no stall in it says it waited the ceiling, and rode out nothing")
    func aParkWithNoStallSaysSo() async throws {
        try await expectTimeout(
            saying: "ParkingDouble held a restore of .everyFan and nobody let it through",
            "timed out after 10.0 s of waiting (plus 0.0 s of runner stall compensated)"
        ) {
            try await Self.abandonAPark(on: VirtualWaitClock())
        }
    }

    /// The stall is 3 s, on the third sleep: short of the cap, so the park waits out its whole
    /// ceiling on top of it, and the issue names both.
    @Test("A park that rode out a stall says how much, beside the time it waited")
    func aParkSaysWhatItRodeOut() async throws {
        let clock = VirtualWaitClock(lateness: { $0 == 3 ? .seconds(3) : .zero })

        try await expectTimeout(
            saying: "ParkingDouble held a restore of .everyFan and nobody let it through",
            "timed out after 10.0 s of waiting (plus 3.0 s of runner stall compensated)"
        ) {
            try await Self.abandonAPark(on: clock)
        }
        #expect(await clock.elapsed > .seconds(12), "the stall really happened on the clock")
    }

    /// Every sleep a second late, so each is a stall and the ceiling never arrives by itself: the
    /// 50 s cap ends the park after half a second of waiting, which is not the ceiling.
    @Test("A park the cap ended says so, and says how little of it was waiting")
    func aParkTheCapEndedSaysSo() async throws {
        let clock = VirtualWaitClock(lateness: { _ in .seconds(1) })

        try await expectTimeout(
            saying: "ParkingDouble held a restore of .everyFan and nobody let it through",
            "timed out at the 50.0 s cap (cap hit) after 0.5 s of waiting",
            "(plus 50.0 s of runner stall compensated)"
        ) {
            try await Self.abandonAPark(on: clock)
        }
    }
}
