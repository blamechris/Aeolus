import Testing

@testable import SMCCore
@testable import fanctl

/// The words `fanctl list` and `fanctl watch` print when enumeration fails outright. An
/// extension of the fetch suite, in its own file only to keep `ListCommandTests.swift` under
/// the 400-line limit.
extension ListCommandFetchTests {

    /// The reason comes from `SMCFanEnumeration`. Before #536 it was `String(describing:)` of
    /// the error, so this printed "Could not read FNum: connectionFailed(kernReturn: …)".
    @Test("An SMCError thrown by the FNum read is printed in words, not as its enum case")
    func fanCountThrowIsPrintedInWords() async {
        let provider = FakeSensorProvider(
            keysError: SMCError.connectionFailed(kernReturn: -536_870_212))

        let error = await #expect(throws: FanctlError.self) {
            try await ListCommand.fetch(provider: provider)
        }
        #expect(
            error?.errorDescription
                == "Could not read FNum: connection to AppleSMC failed (kernel result -536870212)")
    }
}
