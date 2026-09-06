import SwiftUI

/// The "Sensors" tab: which sensors, by raw key, show in the main window — the same
/// key/label/confidence presentation `SensorRowView` already uses, so a sensor looks the
/// same whether it is being picked here or read there.
struct SensorSelectionPreferencesView: View {
    @ObservedObject var preferencesController: PreferencesController
    @ObservedObject var pollingViewModel: PollingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selectionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top])

            if pollingViewModel.sensors.isEmpty {
                Spacer()
                Text("No sensors discovered yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(pollingViewModel.sensors) { sensor in
                    row(for: sensor)
                }
                .listStyle(.inset)
            }
        }
        .padding(.bottom)
    }

    private var selectedKeys: Set<String> { preferencesController.preferences.selectedSensorKeys }

    private var selectionSummary: String {
        Self.selectionSummary(selectedKeys: selectedKeys, sensors: pollingViewModel.sensors)
    }

    /// The "Showing N of M sensors" caption's text, as a pure function of the same two
    /// inputs the view already holds — extracted so the count agrees with
    /// `SensorSelectionFilter`, the same filter the main window applies, rather than with
    /// `selectedKeys.count` directly: a persisted key with no live match (a sensor the
    /// machine has stopped reporting) contributes nothing to what `SensorSelectionFilter`
    /// actually shows, and the caption must not claim otherwise. `internal`, not
    /// `private`, so this agreement is checkable by a unit test rather than only by
    /// reading a `View` body — see
    /// `Tests/AeolusUITests/SensorSelectionPreferencesViewTests.swift`.
    static func selectionSummary(
        selectedKeys: Set<String>, sensors: [SensorPollingReading]
    ) -> String {
        guard !selectedKeys.isEmpty else {
            return "Showing every discovered sensor. Select any below to limit the list."
        }
        let shown = SensorSelectionFilter.apply(selectedKeys, to: sensors).count
        return "Showing \(shown) of \(sensors.count) sensors."
    }

    private func row(for sensor: SensorPollingReading) -> some View {
        Toggle(
            isOn: Binding(
                get: { selectedKeys.contains(sensor.key) },
                set: { isOn in
                    var keys = selectedKeys
                    if isOn {
                        keys.insert(sensor.key)
                    } else {
                        keys.remove(sensor.key)
                    }
                    preferencesController.setSelectedSensorKeys(keys)
                })
        ) {
            SensorRowView(row: rowModel(for: sensor))
        }
    }

    /// This row's `SensorRowModel`, sourced from `preferencesController`'s *current*
    /// temperature unit — `internal`, not `private`, so the wiring itself (not only the
    /// pure conversion below) is checkable by a unit test:
    /// `Tests/AeolusUITests/SensorSelectionPreferencesViewTests.swift` constructs this view
    /// directly (a plain `struct`, no rendering required) and calls this method, so a
    /// regression that stops forwarding the preference — the exact bug this method
    /// replaces — fails that test rather than only showing up on screen.
    func rowModel(for sensor: SensorPollingReading) -> SensorRowModel {
        Self.rowModel(
            for: sensor, temperatureUnit: preferencesController.preferences.temperatureUnit)
    }

    /// This row's `SensorRowModel`, built with the user's configured display unit —
    /// extracted for the same reason `selectionSummary(selectedKeys:sensors:)` is above.
    /// See `TemperatureDisplay`'s own documentation for why every view that shows a
    /// temperature key must agree on which unit it is shown in; before this, this tab
    /// alone used `SensorRowModel.init`'s `.celsius` default regardless of the preference.
    static func rowModel(
        for sensor: SensorPollingReading, temperatureUnit: TemperatureUnit
    ) -> SensorRowModel {
        SensorRowModel(reading: sensor, temperatureUnit: temperatureUnit)
    }
}
