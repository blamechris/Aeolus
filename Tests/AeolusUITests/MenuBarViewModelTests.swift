import SMCCore
import Testing

@testable import AeolusUI

@Suite("MenuBarViewModel — default selection, resolution, and phase mirroring", .serialized)
@MainActor
struct MenuBarViewModelTests {

    private static func provider() -> FakeSensorProvider {
        FakeSensorProvider(
            allReadings: [
                .fake(key: "F0Ac", value: 1712, kind: .rpm),
                .fake(key: "Tp09", value: 44.2, kind: .unknown),
            ],
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
                "Tp09": .success(.fake(key: "Tp09", value: 44.2, kind: .unknown)),
            ])
    }

    @Test("Before any tick, the view model publishes no readouts and claims no data")
    func initialStateIsHonestlyEmpty() {
        let polling = PollingViewModel(provider: Self.provider(), clock: FakePollingClock())
        let viewModel = MenuBarViewModel(polling: polling)

        #expect(viewModel.readouts.isEmpty)
        #expect(viewModel.phase == .notStarted)
        #expect(viewModel.lastUpdated == nil)
        #expect(viewModel.currentSelection.isEmpty)
    }

    @Test("A successful tick with no prior selection computes and resolves a default")
    func successfulTickComputesDefaultSelection() async {
        let polling = PollingViewModel(provider: Self.provider(), clock: FakePollingClock())
        let viewModel = MenuBarViewModel(polling: polling)

        await polling.tick()

        #expect(viewModel.phase == .ready)
        #expect(!viewModel.currentSelection.isEmpty)
        #expect(viewModel.readouts.map(\.key).contains("F0Ac"))
        #expect(viewModel.readouts.allSatisfy { $0.reading.value != nil })
    }

    @Test("An explicit selection at init is never overwritten by the computed default")
    func explicitSelectionAtInitIsPreserved() async {
        let polling = PollingViewModel(provider: Self.provider(), clock: FakePollingClock())
        let explicit = [MenuBarReadout(key: "Tp09", source: .sensor)]
        let viewModel = MenuBarViewModel(polling: polling, selection: explicit)

        await polling.tick()

        #expect(viewModel.currentSelection == explicit)
        #expect(viewModel.readouts.map(\.key) == ["Tp09"])
    }

    @Test("setSelection(_:) replaces the selection and recomputes readouts immediately")
    func setSelectionReplacesAndRecomputesImmediately() async {
        let polling = PollingViewModel(provider: Self.provider(), clock: FakePollingClock())
        let viewModel = MenuBarViewModel(polling: polling)
        await polling.tick()

        viewModel.setSelection([MenuBarReadout(key: "Tp09", source: .sensor)])

        #expect(viewModel.currentSelection == [MenuBarReadout(key: "Tp09", source: .sensor)])
        #expect(viewModel.readouts.map(\.key) == ["Tp09"])
        #expect(viewModel.readouts.first?.reading.value == 44.2)
    }

    @Test("An explicitly empty selection ([]) is never replaced by a computed default")
    func explicitlyEmptySelectionStaysEmpty() async {
        let polling = PollingViewModel(provider: Self.provider(), clock: FakePollingClock())
        let viewModel = MenuBarViewModel(polling: polling, selection: [])

        await polling.tick()
        await polling.tick()

        #expect(viewModel.currentSelection.isEmpty)
        #expect(viewModel.readouts.isEmpty)
    }

    @Test("phase, lastUpdated, and isThermalEmergencyActive mirror the underlying PollingViewModel")
    func mirrorsUnderlyingPollingState() async {
        let polling = PollingViewModel(provider: Self.provider(), clock: FakePollingClock())
        let viewModel = MenuBarViewModel(polling: polling)

        await polling.tick()

        #expect(viewModel.phase == polling.phase)
        #expect(viewModel.lastUpdated == polling.lastUpdated)
        #expect(viewModel.isThermalEmergencyActive == polling.isThermalEmergencyActive)
    }

    @Test("A readout naming a key this poll never reported resolves unavailable, not omitted")
    func unresolvedReadoutStaysVisibleAsUnavailable() async {
        let polling = PollingViewModel(provider: Self.provider(), clock: FakePollingClock())
        let viewModel = MenuBarViewModel(
            polling: polling, selection: [MenuBarReadout(key: "F9Ac", source: .fan)])

        await polling.tick()

        #expect(viewModel.readouts.count == 1)
        #expect(viewModel.readouts.first?.key == "F9Ac")
        #expect(viewModel.readouts.first?.reading.value == nil)
    }

    @Test("The full-stack default selection never surfaces #KEY/AC-B-shaped meta keys")
    func defaultSelectionNeverSurfacesMetaKeysEndToEnd() async {
        // Reproduces, through the whole PollingViewModel -> MenuBarViewModel pipeline,
        // exactly what was observed on real hardware: with no catalog matches, #KEY and
        // AC-B are the first two non-fan keys discovery order would otherwise offer, and
        // neither is a measurement — see MenuBarReadoutSelection's documentation.
        let provider = FakeSensorProvider(
            allReadings: [
                .fake(key: "F0Ac", value: 1712, kind: .rpm),
                .fake(key: "#KEY", value: 3385, kind: .unknown),
                .fake(key: "AC-B", value: -1, kind: .unknown),
            ],
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
                "#KEY": .success(.fake(key: "#KEY", value: 3385, kind: .unknown)),
                "AC-B": .success(.fake(key: "AC-B", value: -1, kind: .unknown)),
            ])
        let polling = PollingViewModel(provider: provider, clock: FakePollingClock())
        let viewModel = MenuBarViewModel(polling: polling)

        await polling.tick()

        let keys = viewModel.readouts.map(\.key)
        #expect(keys.contains("F0Ac"))
        #expect(!keys.contains("#KEY"))
        #expect(!keys.contains("AC-B"))
    }

    @Test("start()/stop() forward to the underlying PollingViewModel's own loop")
    func startAndStopForwardToPolling() async {
        let clock = FakePollingClock(cancelAfterSleeps: 2)
        let polling = PollingViewModel(provider: Self.provider(), clock: clock)
        let viewModel = MenuBarViewModel(polling: polling)

        viewModel.start()
        await polling.waitUntilLoopFinishes()

        #expect(viewModel.phase == .ready)
        #expect(!viewModel.readouts.isEmpty)

        viewModel.stop()
    }
}
