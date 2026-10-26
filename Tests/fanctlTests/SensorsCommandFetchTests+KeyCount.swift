import FanKit
import Testing

@testable import SMCCore
@testable import fanctl

/// `fanctl sensors` and `#KEY`: how a refused `#KEY` reaches the user, and what the
/// `keysDeclared` diagnostic does with a fractional one. An extension of the fetch suite,
/// in its own file only because `SensorsCommandTests.swift` sits at the 400-line limit.
extension SensorsCommandFetchTests {

    /// `readAll()` throws `SMCError` when `#KEY` is refused, and `fetch` wraps it in
    /// `FanctlError.connectionFailed`. Before #531 the wrapped reason was
    /// `String(describing:)`, so the user read the enum case:
    /// `unrepresentableKeyCount(type: SMCCore.SMCKeyType.flt, bytes: [127, 192, 0, 0])`.
    /// The reason is now the shared describer's sentence, which is what `dump` prints for the
    /// same failure.
    @Test(
        "A refused #KEY is described in words, never printed as an SMCError case",
        arguments: [
            SMCError.unrepresentableKeyCount(type: .flt, bytes: [0x7F, 0xC0, 0x00, 0x00]),
            .implausibleKeyCount(declared: 957_153_280),
            .nonNumericKeyCount(type: .hex, bytes: [0x00, 0x00, 0x0D, 0x39]),
        ])
    func refusedKeyCountIsDescribed(_ refusal: SMCError) async {
        let provider = FakeSensorProvider(allError: refusal)

        let expected = FanctlError.connectionFailed(
            context: "enumerate sensors", reason: describeSMCError(refusal))
        await #expect(throws: expected) {
            try await SensorsCommand.fetch(
                provider: provider, catalog: NoSensorCatalog(), rawKeys: false)
        }
        #expect(describeSMCError(refusal) != String(describing: refusal))
    }

    /// `keysDeclared` is diagnostic context only, but it is still a count, and it follows the
    /// one rule SMCCore applies to `#KEY` and `FNum`: a fraction is not made into a count.
    /// Before #531 3385.5 was rounded to 3386, a number the firmware never declared.
    @Test("A fractional #KEY reading leaves keysDeclared nil instead of rounding it")
    func fractionalKeyCountIsNotRounded() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 1)],
            keyedResults: ["#KEY": .success(.fake(key: "#KEY", value: 3385.5))])

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: NoSensorCatalog(), rawKeys: false)

        #expect(result.keysDeclared == nil)
        #expect(result.entries.map(\.key) == ["Tp09"])
    }
}
