import SwiftUI

/// The left pane: live fan readings — current, minimum, and maximum RPM per fan, and
/// each fan's control state, rendered honestly (see `FanRowModel`).
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

            if viewModel.fans.isEmpty {
                emptyState
            } else {
                List(viewModel.fans.map(FanRowModel.init)) { row in
                    FanRowView(row: row)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 320)
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
