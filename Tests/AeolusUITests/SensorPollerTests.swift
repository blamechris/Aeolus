import FanKit
import Testing

@testable import AeolusUI

@Suite("SensorPoller — discovery via readAll() exactly once, refresh via read(keys:) only")
struct SensorPollerTests {

    @Test("discover() enumerates every key readAll() returns, deduplicated and sorted")
    func discoverEnumeratesEveryKey() async throws {
        let provider = FakeSensorProvider(
            allReadings: [
                .fake(key: "Tp09", value: 42, kind: .unknown),
                .fake(key: "F0Ac", value: 1712, kind: .rpm),
                // A duplicate key, as a defensive fixture: SensorProvider's own contract
                // does not promise uniqueness, so discover() must not double-count one.
                .fake(key: "Tp09", value: 42, kind: .unknown),
            ])

        let discovered = try await SensorPoller.discover(provider: provider)
        #expect(discovered.map(\.key) == ["F0Ac", "Tp09"])
        #expect(discovered.first { $0.key == "F0Ac" }?.kind == .rpm)
    }

    @Test("refresh() never calls readAll() — only discover() does")
    func refreshNeverCallsReadAll() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42, kind: .unknown)],
            keyedResults: ["Tp09": .success(.fake(key: "Tp09", value: 43, kind: .unknown))])

        let discovered = try await SensorPoller.discover(provider: provider)
        _ = try await SensorPoller.refresh(
            discovered: discovered, provider: provider, labelSource: NoSensorLabels())
        _ = try await SensorPoller.refresh(
            discovered: discovered, provider: provider, labelSource: NoSensorLabels())

        let readAllCalls = await provider.readAllCallCount
        #expect(readAllCalls == 1)
    }

    @Test("A key present at discovery but failing on refresh reports unavailable, never dropped")
    func discoveredKeyFailingOnRefreshStaysInTheList() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42, kind: .unknown)],
            // Tp09 deliberately unstubbed in keyedResults: the subsequent subset read
            // reports .unknownKey for it, simulating a sensor that vanished between
            // discovery and this tick.
            keyedResults: [:])

        let discovered = try await SensorPoller.discover(provider: provider)
        let refreshed = try await SensorPoller.refresh(
            discovered: discovered, provider: provider, labelSource: NoSensorLabels())

        #expect(refreshed.count == 1)
        let sensor = try #require(refreshed.first)
        #expect(sensor.key == "Tp09")
        #expect(sensor.sample.value == nil)
        #expect(sensor.kind == .unknown)  // still known, from discovery, despite the failure
    }

    @Test("kind is fixed at discovery and does not depend on a successful refresh")
    func kindPersistsAcrossFailedRefresh() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "F0Ac", value: 1712, kind: .rpm)],
            keyedResults: [:])

        let discovered = try await SensorPoller.discover(provider: provider)
        let refreshed = try await SensorPoller.refresh(
            discovered: discovered, provider: provider, labelSource: NoSensorLabels())

        #expect(refreshed.first?.kind == .rpm)
        #expect(refreshed.first?.sample.value == nil)
    }

    @Test("An empty discovered list refreshes to an empty list without issuing any read")
    func emptyDiscoveryRefreshesToEmptyWithNoRead() async throws {
        let provider = FakeSensorProvider()
        let refreshed = try await SensorPoller.refresh(
            discovered: [], provider: provider, labelSource: NoSensorLabels())
        #expect(refreshed.isEmpty)
        let calls = await provider.readKeysCalls
        #expect(calls.isEmpty)
    }

    @Test("A non-finite reading refreshes to unavailable, never a fabricated value")
    func nonFiniteRefreshIsUnavailable() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42, kind: .unknown)],
            keyedResults: ["Tp09": .success(.fake(key: "Tp09", value: .nan, kind: .unknown))])

        let discovered = try await SensorPoller.discover(provider: provider)
        let refreshed = try await SensorPoller.refresh(
            discovered: discovered, provider: provider, labelSource: NoSensorLabels())

        #expect(refreshed.first?.sample.value == nil)
    }

    @Test(
        "The catalog label source's decoration is threaded through per key, without hiding the raw key"
    )
    func decorationIsThreadedThroughAlongsideRawKey() async throws {
        let decoration = CatalogDecoration(
            key: "Tp09", label: "CPU Core 1", category: .cpu, confidence: .verified)
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42, kind: .unknown)],
            keyedResults: ["Tp09": .success(.fake(key: "Tp09", value: 44.2, kind: .unknown))])
        let labelSource = FakeSensorLabelSource(decorationsByKey: ["Tp09": decoration])

        let discovered = try await SensorPoller.discover(provider: provider)
        let refreshed = try await SensorPoller.refresh(
            discovered: discovered, provider: provider, labelSource: labelSource)

        let sensor = try #require(refreshed.first)
        #expect(sensor.key == "Tp09")
        #expect(sensor.decoration?.label == "CPU Core 1")
        #expect(sensor.decoration?.key == "Tp09")
    }

    @Test("With no catalog wired in, every sensor is unlabelled but fully present — not degraded")
    func noSensorLabelsLeavesEverythingUnlabelledButPresent() async throws {
        let provider = FakeSensorProvider(
            allReadings: [
                .fake(key: "Tp09", value: 42, kind: .unknown),
                .fake(key: "F0Ac", value: 1712, kind: .rpm),
            ],
            keyedResults: [
                "Tp09": .success(.fake(key: "Tp09", value: 44, kind: .unknown)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
            ])

        let discovered = try await SensorPoller.discover(provider: provider)
        let refreshed = try await SensorPoller.refresh(
            discovered: discovered, provider: provider, labelSource: NoSensorLabels())

        #expect(refreshed.count == 2)
        for sensor in refreshed {
            #expect(sensor.decoration == nil)
            #expect(!sensor.key.isEmpty)
        }
    }
}
