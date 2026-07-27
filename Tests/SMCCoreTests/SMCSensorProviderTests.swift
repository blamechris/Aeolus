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

/// End-to-end behaviour that holds for any machine exposing the real SMC, and is skipped,
/// not failed, where it is absent. Nothing here assumes a fan exists — see
/// `SMCSensorProviderMac165Tests` below for the one assertion that does, and why it is
/// gated more tightly than "the SMC is present."
///
/// Not additionally gated on the SMC interface generation being resolvable: `readAll()`
/// enumerates via `SMCConnection.keyCount()`, whose `#KEY` fallback means enumeration
/// completes either way — an undetectable generation only degrades the individual
/// display-grade plain-integer readings among the results (each decodes to `nil` and is
/// skipped), never the enumeration itself. `!readings.isEmpty` below holds regardless.
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
}

/// A fact specific to this project's sole verified machine, `Mac16,5`: that fan 0 exists
/// at all. `SMCConnection.isHardwareAvailable()` alone is true of every Mac, including
/// fanless MacBook Airs that expose no `F0Ac` — so this gates additionally on
/// `isDevelopmentMachine()`, the same split applied in `SMCConnectionTests.swift`.
@Suite(
    "SMC sensor provider, Mac16,5-specific facts",
    .enabled(if: SMCConnection.isHardwareAvailable() && isDevelopmentMachine())
)
struct SMCSensorProviderMac165Tests {

    @Test("A fan actual RPM reading is present and classified as rpm")
    func fanReadingIsPresentAndClassified() async throws {
        let provider = SMCSensorProvider()
        let readings = try await provider.readAll()

        let fanReading = readings.first { $0.key == "F0Ac" }
        guard let fanReading else {
            Issue.record("F0Ac was not present in the enumerated readings")
            return
        }
        #expect(fanReading.kind == .rpm)
        // docs/RECOVERY.md: 0 RPM is normal on many Macs when cool or idle, and F0Ac has
        // been observed reading *below* the declared F0Mn floor on Mac16,5 (see
        // SMCConnectionTests.swift). Clamping governs targets, never observations, so the
        // only thing worth asserting about an observed reading is that it is a
        // non-negative, finite RPM — never that it sits above some floor.
        #expect(fanReading.value >= 0)
        #expect(fanReading.value.isFinite)
    }
}

// swiftlint:enable force_unwrapping
