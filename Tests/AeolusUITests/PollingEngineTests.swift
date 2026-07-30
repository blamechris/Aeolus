import Foundation
import Testing

@testable import AeolusUI

@Suite("PollingEngine — one fan-plus-sensor tick")
struct PollingEngineTests {

    private static func provider() -> FakeSensorProvider {
        FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42, kind: .unknown)],
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
                "Tp09": .success(.fake(key: "Tp09", value: 44.2, kind: .unknown)),
            ])
    }

    @Test("No SMC on this machine fails the whole tick before any read is attempted")
    func unavailableProviderThrowsBeforeAnyRead() async throws {
        let provider = FakeSensorProvider(isAvailable: false)
        await #expect(throws: PollingError.self) {
            _ = try await PollingEngine.poll(
                provider: provider, labelSource: NoSensorLabels(), discovery: [])
        }
        let readAllCalls = await provider.readAllCallCount
        let readKeysCalls = await provider.readKeysCalls
        #expect(readAllCalls == 0)
        #expect(readKeysCalls.isEmpty)
    }

    @Test("An empty discovery argument triggers exactly one readAll(), never on later ticks")
    func discoveryHappensOnceWhenFedBackToTheNextCall() async throws {
        let provider = Self.provider()

        let first = try await PollingEngine.poll(
            provider: provider, labelSource: NoSensorLabels(), discovery: [])
        #expect(!first.discovery.isEmpty)

        _ = try await PollingEngine.poll(
            provider: provider, labelSource: NoSensorLabels(), discovery: first.discovery)
        _ = try await PollingEngine.poll(
            provider: provider, labelSource: NoSensorLabels(), discovery: first.discovery)

        let readAllCalls = await provider.readAllCallCount
        #expect(readAllCalls == 1)
    }

    @Test("A snapshot carries both fans and sensors from the same tick")
    func snapshotCarriesFansAndSensors() async throws {
        let provider = Self.provider()
        let snapshot = try await PollingEngine.poll(
            provider: provider, labelSource: NoSensorLabels(), discovery: [])

        #expect(snapshot.fans.count == 1)
        #expect(snapshot.fans.first?.actual.value == 1712)
        #expect(snapshot.sensors.count == 1)
        #expect(snapshot.sensors.first?.key == "Tp09")
    }

    @Test("capturedAt reflects the injected clock, not the wall clock")
    func capturedAtUsesInjectedNow() async throws {
        let provider = Self.provider()
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try await PollingEngine.poll(
            provider: provider, labelSource: NoSensorLabels(), discovery: [], now: fixedDate)
        #expect(snapshot.capturedAt == fixedDate)
    }

    @Test("A fan value that changes between two ticks is reflected, not held stale from the first")
    func fanValueReflectsTheLatestTickNotAMemoizedOne() async throws {
        let firstProvider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42, kind: .unknown)],
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1200, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1000, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5000, kind: .rpm)),
                "Tp09": .success(.fake(key: "Tp09", value: 30, kind: .unknown)),
            ])
        let secondProvider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42, kind: .unknown)],
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 3400, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1000, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5000, kind: .rpm)),
                "Tp09": .success(.fake(key: "Tp09", value: 61.5, kind: .unknown)),
            ])

        let first = try await PollingEngine.poll(
            provider: firstProvider, labelSource: NoSensorLabels(), discovery: [])
        // The second tick's provider is different, but the discovered key set (which
        // only names *which* keys exist, not their values) from the first tick is reused
        // exactly as a real refresh loop would reuse it — see PollingViewModel.tick().
        let second = try await PollingEngine.poll(
            provider: secondProvider, labelSource: NoSensorLabels(), discovery: first.discovery)

        #expect(first.fans.first?.actual.value == 1200)
        #expect(second.fans.first?.actual.value == 3400)
        #expect(first.sensors.first?.sample.value == 30)
        #expect(second.sensors.first?.sample.value == 61.5)
    }

    @Test("A sensor-discovery failure fails the whole tick rather than returning a partial result")
    func discoveryFailurePropagates() async throws {
        let provider = FakeSensorProvider(
            allError: FakeProviderError(description: "simulated readAll failure"),
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
            ])

        await #expect(throws: PollingError.self) {
            _ = try await PollingEngine.poll(
                provider: provider, labelSource: NoSensorLabels(), discovery: [])
        }
    }
}
