import SMCCore
import Testing

/// The reason `SMCFanEnumeration` gives when the provider throws, which the app shows as its
/// poll failure and `fanctl list` and `fanctl watch` print as their error (#536).
///
/// Each test throws a real `SMCError`, because the words are what is under test. Before #536
/// both reasons were `String(describing:)` of the error, so the user read, for example,
/// "read FNum: connectionFailed(kernReturn: -536870212)".
@Suite("Fan enumeration, failure reasons")
struct FanEnumerationFailureReasonTests {

    @Test("An SMCError thrown by the FNum read is described in words, not as its enum case")
    func fanCountReadThrowIsDescribed() async {
        let provider = FakeSensorProvider(
            keysError: SMCError.connectionFailed(kernReturn: -536_870_212))

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        #expect(
            error?.description
                == "read FNum: connection to AppleSMC failed (kernel result -536870212)")
    }

    /// `FNum` reads, and says there are two fans. Then the request for their keys throws.
    @Test("An SMCError thrown by the fan-key read is described in words, not as its enum case")
    func fanKeyReadThrowIsDescribed() async {
        let provider = FakeSensorProvider(
            keyedResults: machine(fanCount: 2), keysError: SMCError.firmware(code: 0x82),
            requestsBeforeKeysError: 1)

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        #expect(
            error?.description
                == "read fan speeds: firmware rejected the request (SMC result 0x82)")
        #expect(await provider.requests.count == 2)
    }
}
