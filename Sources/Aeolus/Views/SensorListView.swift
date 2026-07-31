import SwiftUI

/// The right pane: every sensor this machine currently exposes, decorated with a catalog
/// label where one is known — never in place of the raw key, always alongside it.
///
/// Read-only, same as `FanListView`; binds to the same `PollingViewModel` instance so
/// both panes share one refresh loop rather than polling independently.
struct SensorListView: View {
    @ObservedObject var viewModel: PollingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sensors")
                .font(.headline)
                .padding([.horizontal, .top])

            PollingStatusBanner(
                status: PollingStatusDisplay.text(
                    phase: viewModel.phase, lastUpdated: viewModel.lastUpdated))

            if viewModel.sensors.isEmpty {
                emptyState
            } else {
                columnHeader
                // Lists SensorPollingReading directly — it is already Identifiable on
                // its stable key — and builds SensorRowModel per row inside the
                // closure, rather than mapping the whole array on every render: see
                // FanListView's identical note.
                List(viewModel.sensors) { reading in
                    SensorRowView(row: SensorRowModel(reading: reading))
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

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No sensors discovered yet.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
