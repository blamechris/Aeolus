import SwiftUI

/// The right pane: every sensor this machine currently exposes, decorated with a catalog
/// label where one is known — never in place of the raw key, always alongside it.
///
/// Read-only, same as `FanListView`; binds to the same `PollingViewModel` instance so
/// both panes share one refresh loop rather than polling independently.
struct SensorListView: View {
    @ObservedObject var viewModel: PollingViewModel

    /// `Preferences.selectedSensorKeys`. Defaults to empty — "no filter, show
    /// everything" — so every existing call site is unaffected by this parameter's
    /// addition. See `SensorSelectionFilter`'s documentation.
    var selectedKeys: Set<String> = []

    /// `Preferences.temperatureUnit`. Defaults to `.celsius`, preserving this view's
    /// existing rendering for every call site that does not pass one explicitly.
    var temperatureUnit: TemperatureUnit = .celsius

    private var filteredSensors: [SensorPollingReading] {
        SensorSelectionFilter.apply(selectedKeys, to: viewModel.sensors)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sensors")
                .font(.headline)
                .padding([.horizontal, .top])

            PollingStatusBanner(
                status: PollingStatusDisplay.text(
                    phase: viewModel.phase, lastUpdated: viewModel.lastUpdated))

            if filteredSensors.isEmpty {
                emptyState
            } else {
                columnHeader
                // Lists SensorPollingReading directly — it is already Identifiable on
                // its stable key — and builds SensorRowModel per row inside the
                // closure, rather than mapping the whole array on every render: see
                // FanListView's identical note.
                List(filteredSensors) { reading in
                    SensorRowView(
                        row: SensorRowModel(reading: reading, temperatureUnit: temperatureUnit))
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 320)
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("KEY").frame(width: 48, alignment: .leading)
            Text("LABEL").frame(minWidth: 120, alignment: .leading)
            Text("VALUE").frame(minWidth: 90, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.bottom, 2)
    }

    /// Distinguishes "nothing has been discovered yet" from "a Preferences selection
    /// filtered everything out" — conflating the two would tell a user who chose a
    /// filter that their machine has no sensors at all, which is false.
    private var emptyState: some View {
        VStack {
            Spacer()
            Text(
                viewModel.sensors.isEmpty
                    ? "No sensors discovered yet."
                    : "No sensors match your current selection in Preferences."
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
