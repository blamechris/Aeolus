import SMCCore
import Testing

@testable import AeolusUI

/// The words a direct read's failure puts on screen. `PollingStatusDisplay` shows
/// `PollingError.description` as "Refresh failed: …", so the reason inside it must be
/// `SMCError.readableDescription` text, never the enum-case dump of an `SMCError` (#536).
///
/// Each provider here throws a real `SMCError`, because the words are what is under test.
@Suite("Direct-read pollers — failure reasons are words, not SMCError cases")
struct PollerFailureReasonTests {

    /// What `readAll()` throws for a misdecoded `#KEY`: `Mac16,5`'s `#KEY` read little-endian
    /// is 957,153,280. Before #536 the app showed
    /// "enumerate sensors: implausibleKeyCount(declared: 957153280)".
    @Test("A sensor discovery that throws an SMCError is described in words")
    func discoveryThrowIsDescribed() async {
        let provider = FakeSensorProvider(
            allError: SMCError.implausibleKeyCount(declared: 957_153_280))

        let error = await #expect(throws: PollingError.self) {
            _ = try await SensorPoller.discover(provider: provider)
        }
        #expect(
            error
                == .readFailed(
                    context: "enumerate sensors",
                    reason: "#KEY decoded to an implausible value (957153280)"))
    }

    @Test("A sensor refresh that throws an SMCError is described in words")
    func refreshThrowIsDescribed() async {
        let provider = FakeSensorProvider(
            keysError: SMCError.connectionFailed(kernReturn: -536_870_212))
        let discovered = [DiscoveredSensor(key: "Tp09", kind: .unknown)]

        let error = await #expect(throws: PollingError.self) {
            _ = try await SensorPoller.refresh(
                discovered: discovered, provider: provider, labelSource: NoSensorLabels())
        }
        #expect(
            error?.description
                == "refresh sensors: connection to AppleSMC failed (kernel result -536870212)")
    }

    /// The reason comes from `SMCFanEnumeration`, which `FanPoller` passes through. Pinned
    /// here too, because this is the text the app shows.
    @Test("A fan poll whose FNum read throws an SMCError is described in words")
    func fanCountThrowIsDescribed() async {
        let provider = FakeSensorProvider(keysError: SMCError.firmware(code: 0x82))

        let error = await #expect(throws: PollingError.self) {
            _ = try await FanPoller.poll(provider: provider, untracked: .noHelperInThisBuild)
        }
        #expect(
            error?.description == "read FNum: firmware rejected the request (SMC result 0x82)")
    }
}
