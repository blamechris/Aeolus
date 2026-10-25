import SwiftUI

/// The left pane: the control for all fans, then live fan readings — current, minimum, and
/// maximum RPM per fan, and each fan's control state, rendered honestly (see `FanRowModel`),
/// under one line saying whose report that control state is (`ControlSourceDisplay`).
///
/// ## The control for all fans (#153's PR 6b)
///
/// Auto, 50 %, 75 % and 100 %, for every fan at once, here in the main window and nowhere else:
/// not in the menu bar panel and not in Settings. That keeps `AppWindow.isControlWindow` and the
/// window-close default true as they stand: a lease taken here is released when the last main
/// window closes, and no window event could release one taken from the panel. Per-fan control is
/// PR 8.
///
/// - **Computed in `body` only**, from one read of `viewModel` and the root's lease state
///   (`AllFansControlPresentation(polling:driver:)`), and never from a sink on one of
///   `viewModel`'s properties. `leaseState` is observed, so a change of the driver's report with
///   no new snapshot re-renders it.
/// - **What is drawn as selected is the presentation's**, never the last click.
/// - **A click calls `actions`**, which reads the screen again and asks the root. It selects
///   nothing itself.
///
/// This view starts and stops nothing itself — `MainView` owns the view model's lifecycle, so
/// the fan and sensor panes always observe the same refresh loop, and the control reads a view
/// model `MainView` started.
struct FanListView: View {
    @ObservedObject var viewModel: PollingViewModel
    /// The root's, never one of the view's own (`AppComposition.leaseState`).
    @ObservedObject private var leaseState: LeaseStateModel
    /// The root's entry points, as the control calls them.
    private let actions: AllFansControlActions

    /// - Parameters:
    ///   - viewModel: The window's view model, which `MainView` starts and stops.
    ///   - composition: The app's one root: the control's lease state and its entry points are
    ///     both read from it here, so the view cannot be given one root's state and another's
    ///     actions.
    init(viewModel: PollingViewModel, composition: AppComposition) {
        self.viewModel = viewModel
        _leaseState = ObservedObject(wrappedValue: composition.leaseState)
        actions = AllFansControlActions(composition: composition)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Fans")
                .font(.headline)
                .padding([.horizontal, .top])

            PollingStatusBanner(
                status: PollingStatusDisplay.text(
                    phase: viewModel.phase, lastUpdated: viewModel.lastUpdated))

            controlSourceLine(ControlSourceDisplay.text(for: viewModel.controlSource))

            AllFansControlView(
                control: AllFansControlPresentation(
                    polling: viewModel, driver: leaseState.current),
                choose: { percent in actions.choose(percent, on: viewModel) },
                chooseAutomatic: { actions.chooseAutomatic() })

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
