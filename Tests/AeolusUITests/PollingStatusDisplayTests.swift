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
}
