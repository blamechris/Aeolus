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

/// `read(keys:)` splitting malformed key strings out before ever touching a connection
/// (see the type's documentation for why) needs no hardware: a request made entirely of
/// malformed strings never opens one, so this holds identically on CI's SMC-less runners
/// and on real hardware.
@Suite("SMC sensor provider, malformed key strings")
struct SMCSensorProviderMalformedKeyTests {

    @Test("A key string that is not four ASCII characters reports unknownKey, not a throw")
    func malformedKeyReportsUnknownKey() async throws {
        let provider = SMCSensorProvider()
        let outcomes = try await provider.read(keys: ["ABC", "TOOLONG"])

        #expect(outcomes.count == 2)
        for outcome in outcomes {
            guard case .failure(.unknownKey(let reported)) = outcome.result else {
                Issue.record("expected .unknownKey for \(outcome.key)")
                continue
            }
            #expect(reported == outcome.key)
        }
    }

    @Test("An empty request returns an empty result without opening a connection")
    func emptyRequestReturnsEmpty() async throws {
        let provider = SMCSensorProvider()
        let outcomes = try await provider.read(keys: [])
        #expect(outcomes.isEmpty)
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

    @Test("read(keys:) works standalone, with no prior readAll(), and matches readAll()'s value")
    func readKeysWorksWithoutPriorReadAll() async throws {
        // A fresh provider/connection: this is the acceptance criterion that a subset
        // read must not require a prior full enumeration to function at all.
        let subsetProvider = SMCSensorProvider()
        let outcomes = try await subsetProvider.read(keys: ["#KEY"])

        guard let outcome = outcomes.first, case .success(let reading) = outcome.result else {
            Issue.record("expected #KEY to read successfully with no prior readAll()")
            return
        }
        #expect(reading.key == "#KEY")
        #expect(reading.value > 0)
    }

    @Test("read(keys:) reports unknownKey for a key this machine does not expose")
    func readKeysReportsUnknownKeyForAbsentKey() async throws {
        let provider = SMCSensorProvider()
        // Establish discovery first so the machine's key set is actually known, rather
        // than this being indistinguishable from "never attempted."
        _ = try await provider.readAll()

        let outcomes = try await provider.read(keys: ["ZZZZ"])
        guard let outcome = outcomes.first else {
            Issue.record("expected exactly one outcome")
            return
        }
        #expect(outcome.result == .failure(.unknownKey("ZZZZ")))
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

    /// Issue #32's own performance claim, verified live rather than only measured once
    /// by hand: a second `readAll()`, run against a connection whose cache is already
    /// warm from the first, is materially faster. The exact multiple is a machine-and-
    /// moment fact (see the PR body for what was actually measured on `Mac16,5`), so
    /// this asserts a conservative fraction — "at least twice as fast" — rather than
    /// pinning the precise ratio observed once.
    @Test("A second readAll() is materially faster than the first, once the cache is warm")
    func secondReadAllIsMaterallyFaster() async throws {
        let provider = SMCSensorProvider()

        let firstStart = ContinuousClock.now
        _ = try await provider.readAll()
        let firstDuration = ContinuousClock.now - firstStart

        let secondStart = ContinuousClock.now
        _ = try await provider.readAll()
        let secondDuration = ContinuousClock.now - secondStart

        #expect(secondDuration < firstDuration / 2)
    }

    /// The other half of #32's claim: once the cache is warm, a small subset read is
    /// fast enough for a ~1 Hz monitoring UI. The issue's own target is "under 50 ms";
    /// this asserts a looser 100 ms bound to absorb ordinary scheduling jitter between
    /// runs rather than pin a number close enough to the target to occasionally flake —
    /// the PR body carries the actual measured figure from a real run.
    @Test("A ~40-key subset read on a warm cache is fast enough for 1 Hz monitoring")
    func warmSubsetReadIsFast() async throws {
        let provider = SMCSensorProvider()
        let allReadings = try await provider.readAll()  // warms the cache
        let sample = Array(allReadings.prefix(40)).map(\.key)
        guard sample.count >= 10 else {
            Issue.record("expected at least 10 readings to sample from")
            return
        }

        let start = ContinuousClock.now
        let outcomes = try await provider.read(keys: sample)
        let duration = ContinuousClock.now - start

        #expect(outcomes.count == sample.count)
        #expect(duration < .milliseconds(100))
    }
}

// swiftlint:enable force_unwrapping
