import Foundation
import SMCCore
import Testing

@testable import AeolusUI

@Suite("PollingStatusDisplay — a stale or failed refresh always says so")
struct PollingStatusDisplayTests {

    @Test(".notStarted renders a waiting message, never implying data exists yet")
    func notStartedRendersWaitingMessage() {
        let text = PollingStatusDisplay.text(phase: .notStarted, lastUpdated: nil)
        #expect(text.severity == .normal)
        #expect(text.message.contains("Waiting"))
    }

    @Test(".polling with no prior success renders a plain in-progress message")
    func pollingWithNoPriorSuccessRendersPlainMessage() {
        let text = PollingStatusDisplay.text(phase: .polling, lastUpdated: nil)
        #expect(text.severity == .normal)
        #expect(!text.message.isEmpty)
    }

    @Test(".ready renders a normal-severity, non-empty message referencing the update")
    func readyRendersNormalMessage() {
        let now = Date()
        let text = PollingStatusDisplay.text(phase: .ready, lastUpdated: now, now: now)
        #expect(text.severity == .normal)
        #expect(text.message.contains("Updated"))
        #expect(text.message.contains("just now"))
    }

    @Test(
        ".failed always renders warning severity and names the failure, even with no prior success"
    )
    func failedWithNoPriorDataRendersWarning() {
        let text = PollingStatusDisplay.text(phase: .failed(.noSMC), lastUpdated: nil)
        #expect(text.severity == .warning)
        #expect(text.message.contains("Refresh failed"))
        #expect(text.message.contains(PollingError.noSMC.description))
        #expect(text.message.contains("no reading yet"))
    }

    @Test(
        ".failed after a prior success says the shown data is stale, not that it is current"
    )
    func failedAfterPriorSuccessMarksDataAsStale() {
        let now = Date()
        let lastUpdated = now.addingTimeInterval(-42)
        let text = PollingStatusDisplay.text(
            phase: .failed(.readFailed(context: "poll", reason: "connection lost")),
            lastUpdated: lastUpdated, now: now)

        #expect(text.severity == .warning)
        #expect(text.message.contains("Refresh failed"))
        #expect(text.message.contains("connection lost"))
        #expect(text.message.contains("showing the last reading from"))
        #expect(text.message.contains("42s ago"))
    }

    @Test("Elapsed time is expressed in minutes once it crosses a minute")
    func elapsedTimeCrossesIntoMinutes() {
        let now = Date()
        let lastUpdated = now.addingTimeInterval(-125)
        let text = PollingStatusDisplay.text(phase: .ready, lastUpdated: lastUpdated, now: now)
        #expect(text.message.contains("2m ago"))
    }

    // MARK: - Waiting for the helper

    /// Nothing has been read and nothing is shown, so there is nothing to call old; it says what
    /// it is waiting for, and never that anything was updated.
    ///
    /// **Mutation (ST2):** return "Reading sensors…" here. **Mutation (MX8):** return "Updated
    /// just now". Run, each: red at the message expectation.
    @Test(".waitingForHelper with nothing read says what it waits for, at normal severity")
    func waitingWithNothingRead() {
        let text = PollingStatusDisplay.text(phase: .waitingForHelper, lastUpdated: nil)
        #expect(text.message == "Waiting for the helper's first snapshot…")
        #expect(text.severity == .normal)
        #expect(!text.message.contains("Updated"))
        #expect(!text.message.contains("just now"))
    }

    /// This line is the only marker that the readings on screen are not current, so it is a
    /// warning, and it never says "just now", even for a reading a moment old.
    ///
    /// **Mutation (ST1):** change its severity to `.normal`. Run: red at both severity
    /// expectations.
    @Test(".waitingForHelper with readings on screen says they are not current, as a warning")
    func waitingWithReadingsOnScreen() {
        let now = Date()
        let moment = PollingStatusDisplay.text(
            phase: .waitingForHelper, lastUpdated: now.addingTimeInterval(-0.4), now: now)
        #expect(
            moment.message
                == "Waiting for the helper — the readings shown are from less than a second ago")
        #expect(moment.severity == .warning)
        #expect(!moment.message.contains("just now"))

        let older = PollingStatusDisplay.text(
            phase: .waitingForHelper, lastUpdated: now.addingTimeInterval(-30), now: now)
        #expect(older.message == "Waiting for the helper — the readings shown are from 30s ago")
        #expect(older.severity == .warning)
    }
}
