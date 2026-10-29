import Foundation
import SMCCore
import Testing

@testable import AeolusUI

/// What the "Refresh failed:" status line shows of a failure's own words (#544).
///
/// The direct read path puts firmware-declared bytes into a `PollingError`. A `#KEY` that
/// declares a type this project does not recognise is described with its four-character code,
/// verbatim (`SMCError.nonNumericKeyCount`, through `SMCError.readableDescription`). A code
/// holding a line feed would draw a second, forged line under the warning. Never observed:
/// `#KEY` is a `ui32` on `Mac16,5`.
///
/// Driven from a provider that throws the real `SMCError`, through `SensorPoller.discover`, and
/// each test first checks that the line feed reaches the display. Without that check, a layer
/// below that dropped the byte would leave these tests green with nothing for the display to
/// remove.
@Suite("PollingStatusDisplay — a failure's words are cleaned before they are shown")
struct PollingStatusFailureReasonTests {

    /// `a`, line feed, `b`, `c`: an unrecognised type code holding `0x0A`.
    private static let codeWithLineFeed: UInt32 = 0x610A_6263

    /// The failure's words once cleaned: the line feed dropped, the rest as described.
    private static let cleanedReason =
        "enumerate sensors: #KEY declares abc (raw bytes 00000d39), which is not a numeric "
        + "type, so it holds no key count"

    /// The `PollingError` a direct discovery throws for that `#KEY`, checked to still carry the
    /// raw line feed when it reaches the display.
    private func discoveryFailure() async throws -> PollingError {
        let provider = FakeSensorProvider(
            allError: SMCError.nonNumericKeyCount(
                type: .unknown(Self.codeWithLineFeed), bytes: [0x00, 0x00, 0x0D, 0x39]))
        let thrown = await #expect(throws: PollingError.self) {
            _ = try await SensorPoller.discover(provider: provider)
        }
        let error = try #require(thrown)
        try #require(error.description.contains("\n"))
        return error
    }

    /// **Mutation (N3a):** show `error.description` in this branch instead of the sanitised
    /// reason. Run: red at the message expectation and the removed-scalar expectation.
    @Test("A line feed in a failure's words never reaches the line when nothing has been read")
    func lineFeedIsDroppedWithNoReading() async throws {
        let error = try await discoveryFailure()

        let text = PollingStatusDisplay.text(phase: .failed(error), lastUpdated: nil)

        #expect(text.message == "Refresh failed: \(Self.cleanedReason) — no reading yet")
        #expect(!text.message.unicodeScalars.contains(where: HelperAuthoredText.isRemoved))
        #expect(text.severity == .warning)
    }

    /// **Mutation (N3b):** show `error.description` in this branch instead of the sanitised
    /// reason. Run: red at the message expectation and the removed-scalar expectation.
    @Test("A line feed in a failure's words never reaches the line beside an older reading")
    func lineFeedIsDroppedAfterAReading() async throws {
        let error = try await discoveryFailure()
        let now = Date()

        let text = PollingStatusDisplay.text(
            phase: .failed(error), lastUpdated: now.addingTimeInterval(-42), now: now)

        #expect(
            text.message
                == "Refresh failed: \(Self.cleanedReason) — showing the last reading from 42s ago")
        #expect(!text.message.unicodeScalars.contains(where: HelperAuthoredText.isRemoved))
        #expect(text.severity == .warning)
    }

    /// The menu bar's "Last refresh failed:" line shows the same words through the same
    /// function. Pinned here at the function; the view body that calls it has no test.
    @Test("The shared failure reason drops the line feed and keeps the rest")
    func sharedFailureReasonIsCleaned() async throws {
        let error = try await discoveryFailure()
        #expect(PollingStatusDisplay.failureReason(error) == Self.cleanedReason)
    }
}
