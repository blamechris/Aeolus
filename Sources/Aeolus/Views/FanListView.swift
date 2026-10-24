import SwiftUI

/// The left pane: live fan readings — current, minimum, and maximum RPM per fan, and
/// each fan's control state, rendered honestly (see `FanRowModel`), under one line saying
/// whose report that control state is (`ControlSourceDisplay`).
///
/// Read-only. Binds to `PollingViewModel`'s already-published `fans`; this view starts
/// and stops nothing itself — `MainView` owns the view model's lifecycle so the fan and
/// sensor panes always observe the same refresh loop.
struct FanListView: View {
    @ObservedObject var viewModel: PollingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Fans")
                .font(.headline)
                .padding([.horizontal, .top])

            PollingStatusBanner(
                status: PollingStatusDisplay.text(
                    phase: viewModel.phase, lastUpdated: viewModel.lastUpdated))

            controlSourceLine(ControlSourceDisplay.text(for: viewModel.controlSource))

            if viewModel.fans.isEmpty {
                emptyState
            } else {
                // Lists FanPollingReading directly — it is already Identifiable on the
                // fan index — and builds FanRowModel per row inside the closure, rather
                // than mapping the whole array on every render: that would allocate a
                // fresh [FanRowModel] on every refresh tick even for rows SwiftUI's own
                // diffing would otherwise skip re-evaluating.
                List(viewModel.fans) { reading in
                    FanRowView(row: FanRowModel(reading: reading))
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 320)
    }

    private func controlSourceLine(_ text: ControlSourceDisplay.Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text.headline)
                .font(.caption.weight(.semibold))
            if let detail = text.detail {
                Text(detail)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No fans reported by this machine yet.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
