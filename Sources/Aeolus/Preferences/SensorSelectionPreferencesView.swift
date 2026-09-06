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
        guard !selectedKeys.isEmpty else {
            return "Showing every discovered sensor. Select any below to limit the list."
        }
        return "Showing \(selectedKeys.count) of \(pollingViewModel.sensors.count) sensors."
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
            SensorRowView(row: SensorRowModel(reading: sensor))
        }
    }
}
