import Testing

@testable import SMCCore

// swiftlint:disable force_unwrapping

/// `SMCSensorProvider.kind(for:)` is pure classification logic over a key's raw string
/// and needs no hardware — see the type's documentation for why it stays this narrow.
@Suite("SMC sensor provider, kind classification")
struct SMCSensorProviderKindTests {

    @Test("Fan actual/target/min/max keys classify as rpm")
    func fanKeysClassifyAsRPM() {
        for suffix in ["Ac", "Tg", "Mn", "Mx"] {
            let key = SMCKey("F0\(suffix)")!
            #expect(SMCSensorProvider.kind(for: key) == .rpm)
        }
    }

    @Test("A fan key for a different fan index still classifies as rpm")
    func otherFanIndexClassifiesAsRPM() {
        #expect(SMCSensorProvider.kind(for: SMCKey("F1Ac")!) == .rpm)
    }

    @Test("A fan-prefixed key with an unrecognised suffix is unknown, not guessed")
    func unrecognisedFanSuffixIsUnknown() {
        #expect(SMCSensorProvider.kind(for: SMCKey("F0Md")!) == .unknown)
    }

    @Test("Temperature-looking keys are unknown, not inferred from a bare prefix")
    func temperatureKeysAreNotGuessed() {
        // Kind classification beyond fan RPM is deliberately left to the catalog (E6),
        // which carries a confidence level and a citation. A bare 'T' prefix is not
        // enough on its own to claim Celsius.
        #expect(SMCSensorProvider.kind(for: SMCKey("TC0P")!) == .unknown)
    }

    @Test("A non-fan key is unknown")
    func nonFanKeyIsUnknown() {
        #expect(SMCSensorProvider.kind(for: SMCKey("#KEY")!) == .unknown)
    }
}

/// End-to-end behaviour requires the real SMC and is skipped, not failed, where it is
/// absent.
@Suite("SMC sensor provider, real hardware", .enabled(if: SMCConnection.isHardwareAvailable()))
struct SMCSensorProviderHardwareTests {

    @Test("isAvailable reflects that the SMC is present")
    func isAvailableIsTrue() async {
        let provider = SMCSensorProvider()
        #expect(await provider.isAvailable)
    }

    @Test("readAll enumerates readings, every one carrying its raw key")
    func readAllProducesReadings() async throws {
        let provider = SMCSensorProvider()
        let readings = try await provider.readAll()

        #expect(!readings.isEmpty)
        for reading in readings {
            #expect(reading.key.count == 4)
            #expect(reading.providerIdentifier == "smc")
        }
    }

    @Test("A fan actual RPM reading is present, classified as rpm, and never zero")
    func fanReadingIsPresentAndClassified() async throws {
        let provider = SMCSensorProvider()
        let readings = try await provider.readAll()

        let fanReading = readings.first { $0.key == "F0Ac" }
        guard let fanReading else {
            Issue.record("F0Ac was not present in the enumerated readings")
            return
        }
        #expect(fanReading.kind == .rpm)
        // Hard rule: never allow 0 RPM to be representable. This is an *observation*,
        // not a target, so it is not clamped — but a real fan spinning at all should
        // never report exactly zero.
        #expect(fanReading.value > 0)
    }
}

// swiftlint:enable force_unwrapping
