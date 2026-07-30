import SMCCore
import Testing

@testable import AeolusUI

@Suite("KeyedReading — unavailable vs. zero, and non-finite guarding")
struct KeyedReadingTests {

    @Test("A successful, finite read decodes to .value, carrying the exact reading")
    func successfulFiniteReadDecodesToValue() {
        let reading = KeyedReading(
            key: "F0Ac", outcome: .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)))

        #expect(reading.value == 1712)
        #expect(reading.isAvailable)
        #expect(reading.availability == .value(1712))
    }

    @Test(
        "A reading below the declared firmware minimum is a legitimate value, not an error",
        // The exact figure this project measured on real hardware: F0Ac at 1343.07
        // against a declared F0Mn of 1350 — see docs/SMC-RESEARCH.md and this file's
        // sibling test in FanPollerTests.swift for the same fact at the fan-poll level.
        arguments: [1343.07]
    )
    func belowMinimumReadingIsLegitimate(_ value: Double) {
        let reading = KeyedReading(
            key: "F0Ac", outcome: .success(.fake(key: "F0Ac", value: value, kind: .rpm)))
        #expect(reading.value == value)
        #expect(reading.isAvailable)
    }

    @Test("A NaN successful read is unavailable, never a fabricated 0")
    func nanReadIsUnavailable() {
        let reading = KeyedReading(
            key: "Tp09", outcome: .success(.fake(key: "Tp09", value: .nan, kind: .unknown)))

        #expect(reading.value == nil)
        #expect(!reading.isAvailable)
        guard case .unavailable(let reason) = reading.availability else {
            Issue.record("expected .unavailable, got \(reading.availability)")
            return
        }
        #expect(reason.contains("NaN"))
        #expect(reason.contains("non-finite"))
    }

    @Test(
        "A non-finite successful read never decodes to 0 — the exact fabrication this type exists to prevent"
    )
    func nonFiniteNeverBecomesZero() {
        let reading = KeyedReading(
            key: "F0Ac", outcome: .success(.fake(key: "F0Ac", value: .infinity, kind: .rpm)))

        // The specific bug this guards: `Int(exactly:)`/naive rendering must never see 0
        // RPM for a fan that is actually reporting garbage, which a user would read as
        // "this fan stopped."
        #expect(reading.value != 0)
        #expect(reading.value == nil)
    }

    @Test(
        "Positive and negative infinity are distinguished in the unavailable reason",
        arguments: [(Double.infinity, "Infinity"), (-Double.infinity, "-Infinity")]
    )
    func infinitySignIsPreservedInReason(_ pair: (Double, String)) {
        let (value, expectedSubstring) = pair
        let reading = KeyedReading(
            key: "F0Ac", outcome: .success(.fake(key: "F0Ac", value: value, kind: .rpm)))
        guard case .unavailable(let reason) = reading.availability else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(reason.contains(expectedSubstring))
    }

    @Test("A failed read is unavailable with a readable, non-parsed reason, never .value(0)")
    func failedReadIsUnavailableNeverZero() {
        let reading = KeyedReading(
            key: "F9Ac", outcome: .failure(.unknownKey("F9Ac")))

        #expect(reading.value == nil)
        guard case .unavailable(let reason) = reading.availability else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(reason.contains("F9Ac"))
    }

    @Test("A read that decoded but isn't numeric is unavailable, not silently dropped")
    func notDecodableReadIsUnavailable() {
        let reading = KeyedReading(
            key: "#KEY", outcome: .failure(.notDecodable(reason: "ch8* is not numeric")))
        #expect(reading.value == nil)
        guard case .unavailable = reading.availability else {
            Issue.record("expected .unavailable")
            return
        }
    }

    @Test("The static .value/.unavailable factories round-trip through the same invariants")
    func staticFactoriesRoundTrip() {
        let value = KeyedReading.value(key: "F0Ac", 3200)
        let unavailable = KeyedReading.unavailable(key: "F0Mx", reason: "no outcome returned")

        #expect(value.key == "F0Ac")
        #expect(value.value == 3200)
        #expect(unavailable.key == "F0Mx")
        #expect(unavailable.value == nil)
    }
}
