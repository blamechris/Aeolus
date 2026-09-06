import SMCCore
import Testing

@testable import AeolusUI

/// Covers what `SensorSelectionPreferencesView` extracts from its body — the pure
/// `selectionSummary(selectedKeys:sensors:)` and `rowModel(for:temperatureUnit:)`
/// functions, and the instance-level `rowModel(for:)` that actually wires the live
/// `preferencesController` into a row — so the Sensors tab's caption and rows are
/// checkable without rendering the view. `SensorSelectionPreferencesView` is a plain
/// `struct`, so it can be constructed directly here with no SwiftUI host.
@Suite("SensorSelectionPreferencesView — the caption and row respect what is actually shown")
@MainActor
struct SensorSelectionPreferencesViewTests {

    private func sensor(_ key: String) -> SensorPollingReading {
        SensorPollingReading(key: key, kind: .unknown, sample: .value(key: key, 1))
    }

    // MARK: - selectionSummary

    @Test("An empty selection reports every discovered sensor, not a stale zero")
    func emptySelectionSummary() {
        let sensors = [sensor("Tp09"), sensor("TC0P")]
        let summary = SensorSelectionPreferencesView.selectionSummary(
            selectedKeys: [], sensors: sensors)

        #expect(summary == "Showing every discovered sensor. Select any below to limit the list.")
    }

    @Test("A selection where every key still matches reports the matched count")
    func fullyMatchingSelectionSummary() {
        let sensors = [sensor("Tp09"), sensor("TC0P"), sensor("F0Ac")]
        let summary = SensorSelectionPreferencesView.selectionSummary(
            selectedKeys: ["Tp09", "TC0P"], sensors: sensors)

        #expect(summary == "Showing 2 of 3 sensors.")
    }

    @Test(
        """
        A selected key the machine no longer reports contributes nothing to the count — \
        the caption must agree with SensorSelectionFilter, never with selectedKeys.count \
        directly, or it overstates what the main window actually shows.
        """)
    func selectedKeyWithNoLiveMatchIsNotCounted() {
        let sensors = [sensor("Tp09")]
        // Five keys selected, only one of which still exists as a live sensor.
        let summary = SensorSelectionPreferencesView.selectionSummary(
            selectedKeys: ["Tp09", "TC0P", "F0Ac", "TG0P", "TH0P"], sensors: sensors)

        #expect(summary == "Showing 1 of 1 sensors.")
    }

    @Test("Every selected key gone still reports zero, never the stale selection size")
    func everySelectedKeyGoneReportsZero() {
        let sensors = [sensor("Tp09")]
        let summary = SensorSelectionPreferencesView.selectionSummary(
            selectedKeys: ["TC0P", "F0Ac"], sensors: sensors)

        #expect(summary == "Showing 0 of 1 sensors.")
    }

    // MARK: - rowModel

    @Test("A temperature row is built with the caller's unit, not SensorRowModel's own default")
    func rowModelUsesTheGivenTemperatureUnit() {
        let reading = SensorPollingReading(
            key: "Tp09", kind: .temperatureCelsius, sample: .value(key: "Tp09", 44.2))

        let fahrenheit = SensorSelectionPreferencesView.rowModel(
            for: reading, temperatureUnit: .fahrenheit)
        let celsius = SensorSelectionPreferencesView.rowModel(
            for: reading, temperatureUnit: .celsius)

        #expect(fahrenheit.value.text == "111.56 °F")
        #expect(celsius.value.text == "44.20 °C")
    }

    @Test("A non-temperature reading is unaffected by the unit")
    func rowModelPassesThroughNonTemperatureReadings() {
        let reading = SensorPollingReading(
            key: "F0Ac", kind: .rpm, sample: .value(key: "F0Ac", 1800))

        let row = SensorSelectionPreferencesView.rowModel(
            for: reading, temperatureUnit: .fahrenheit)

        #expect(row.value.text == "1800 RPM")
    }

    // MARK: - instance-level wiring

    @Test(
        """
        The view's own row(for:) — exercised here via the identical instance method it \
        calls — forwards preferencesController's *current* temperature unit, not \
        SensorRowModel's own .celsius default. This is the actual bug the adversarial \
        review found: SensorRowModel was constructed with no unit argument at all.
        """)
    func viewRowModelForwardsTheLivePreference() {
        let store = InMemoryPreferencesStore(stored: Preferences(temperatureUnit: .fahrenheit))
        let preferencesController = PreferencesController(store: store)
        let pollingViewModel = PollingViewModel(labelSource: NoSensorLabels())
        let view = SensorSelectionPreferencesView(
            preferencesController: preferencesController, pollingViewModel: pollingViewModel)
        let reading = SensorPollingReading(
            key: "Tp09", kind: .temperatureCelsius, sample: .value(key: "Tp09", 44.2))

        #expect(view.rowModel(for: reading).value.text == "111.56 °F")
    }
}
