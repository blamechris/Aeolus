import Testing

@testable import AeolusUI

@Suite("FanPoller — no {fds, targeted subset reads only")
struct FanPollerTests {

    @Test("FNum absent entirely (a fanless Mac) reports zero fans, not an error")
    func fanNumAbsentReportsZeroFans() async throws {
        // FNum deliberately unstubbed: the fake reports .unknownKey for it, exactly what
        // a genuinely fanless machine's firmware would answer — see docs/SMC-RESEARCH.md.
        let provider = FakeSensorProvider(keyedResults: [:])
        let fans = try await FanPoller.poll(provider: provider)
        #expect(fans.isEmpty)
    }

    @Test("A fan whose maximum-RPM key fails to read still reports its other two values")
    func oneFailingKeyDoesNotBlockSiblingReadings() async throws {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                // F0Mx deliberately unstubbed — the fake reports .unknownKey for it.
            ])

        let fans = try await FanPoller.poll(provider: provider)
        let fan = try #require(fans.first)

        #expect(fan.actual.value == 1712)
        #expect(fan.minimum.value == 1200)
        #expect(fan.maximum.value == nil)
        guard case .unavailable = fan.maximum.availability else {
            Issue.record("expected F0Mx to be unavailable, got \(fan.maximum.availability)")
            return
        }
    }

    @Test("A NaN actual-RPM reading is unavailable, never a fabricated value")
    func nanActualReadingIsUnavailable() async throws {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: .nan, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
            ])

        let fans = try await FanPoller.poll(provider: provider)
        let fan = try #require(fans.first)
        #expect(fan.actual.value == nil)
        #expect(!fan.actual.isAvailable)
    }

    @Test(
        "A reading below the declared firmware minimum is legitimate and is never clamped up"
    )
    func belowMinimumReadingIsNeverClamped() async throws {
        // The exact figure measured on this project's development hardware: F0Ac at
        // 1343.07 against a declared F0Mn of 1350.
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1343.07, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1350, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
            ])

        let fans = try await FanPoller.poll(provider: provider)
        let fan = try #require(fans.first)
        #expect(fan.actual.value == 1343.07)
    }

    @Test("An implausible FNum throws rather than allocating an unbounded fan list")
    func implausibleFanCountThrows() async throws {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 999_999))
            ])

        await #expect(throws: PollingError.self) {
            _ = try await FanPoller.poll(provider: provider)
        }
    }

    @Test("A non-finite FNum throws instead of trapping on Int(exactly:)")
    func nonFiniteFanCountThrows() async throws {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: .infinity))
            ])

        await #expect(throws: PollingError.self) {
            _ = try await FanPoller.poll(provider: provider)
        }
    }

    // MARK: - Classified-error surfacing (proving the shared enumeration's error is not
    // flattened or re-derived on its way through FanPoller)

    @Test("No SMC on this machine surfaces as PollingError.noSMC specifically")
    func unavailableProviderThrowsClassifiedNoSMC() async {
        let provider = FakeSensorProvider(isAvailable: false)

        let error = await #expect(throws: PollingError.self) {
            _ = try await FanPoller.poll(provider: provider)
        }
        #expect(error == .noSMC)
    }

    @Test("An implausible FNum surfaces as PollingError.implausibleFanCount specifically")
    func implausibleFanCountThrowsClassifiedCase() async {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 999_999))
            ])

        let error = await #expect(throws: PollingError.self) {
            _ = try await FanPoller.poll(provider: provider)
        }
        guard case .implausibleFanCount(let declared) = error else {
            Issue.record("expected .implausibleFanCount, got \(String(describing: error))")
            return
        }
        #expect(declared == 999_999)
    }

    @Test("An FNum read failure that is not absence surfaces as PollingError.readFailed")
    func fnumReadFailureThrowsClassifiedReadFailed() async {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .failure(.readFailed(reason: "firmware rejected the read"))
            ])

        let error = await #expect(throws: PollingError.self) {
            _ = try await FanPoller.poll(provider: provider)
        }
        guard case .readFailed(_, let reason) = error else {
            Issue.record("expected .readFailed, got \(String(describing: error))")
            return
        }
        #expect(reason == "firmware rejected the read")
    }

    @Test("Every fan carries the hardcoded-safe honesty flags: automatic, never reclaimed")
    func honestyFlagsAreHardcodedSafe() async throws {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 2)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
                "F1Ac": .success(.fake(key: "F1Ac", value: 1800, kind: .rpm)),
                "F1Mn": .success(.fake(key: "F1Mn", value: 1200, kind: .rpm)),
                "F1Mx": .success(.fake(key: "F1Mx", value: 5312, kind: .rpm)),
            ])

        let fans = try await FanPoller.poll(provider: provider)
        #expect(fans.count == 2)
        for fan in fans {
            #expect(fan.mode == .automatic)
            #expect(fan.isReclaimedBySystem == false)
        }
    }

    @Test("The raw key is always carried, in both table and displayName synthesis")
    func rawKeyIsAlwaysPresent() async throws {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
            ])

        let fans = try await FanPoller.poll(provider: provider)
        let fan = try #require(fans.first)
        #expect(fan.displayName == "Fan 0")
        #expect(fan.actual.key == "F0Ac")
        #expect(fan.minimum.key == "F0Mn")
        #expect(fan.maximum.key == "F0Mx")
    }

    @Test("A value differs across two independent polls, proving nothing is memoized")
    func pollDoesNotMemoizeAcrossCalls() async throws {
        let firstTick = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1200, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1000, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5000, kind: .rpm)),
            ])
        let secondTick = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 3400, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1000, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5000, kind: .rpm)),
            ])

        let first = try await FanPoller.poll(provider: firstTick)
        let second = try await FanPoller.poll(provider: secondTick)

        #expect(first.first?.actual.value == 1200)
        #expect(second.first?.actual.value == 3400)
    }
}
