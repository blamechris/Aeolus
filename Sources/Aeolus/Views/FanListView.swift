import SwiftUI

/// The left pane: the control for all fans, then live fan readings — current, minimum, and
/// maximum RPM per fan, and each fan's control state, rendered honestly (see `FanRowModel`),
/// under one line saying whose report that control state is (`ControlSourceDisplay`).
///
/// ## The control for all fans (#153's PR 6b), and each fan's own (#154, PR 8b)
///
/// Auto, 50 %, 75 % and 100 %, for every fan at once, and in each fan's row Auto or Custom with a
/// target speed (`FanRowView`), here in the main window and nowhere else: not in the menu bar
/// panel and not in Settings. That keeps `AppWindow.isControlWindow` and the window-close default
/// true as they stand: a lease taken here is released when the last main window closes, and no
/// window event could release one taken from the panel.
///
/// - **Computed in `body` only**, from **one** read of `viewModel` and the root's lease state:
///   `FanControlPresentation.onScreen(in:driver:)` once, and the control for all fans, the
///   monitoring-mode banner and every row drawn from what it returned, against the same snapshot
///   and report. Never from a sink on one of `viewModel`'s properties. `leaseState` is observed,
///   so a change of the driver's report with no new snapshot re-renders it.
/// - **What is drawn as selected is the presentations'**, never the last click.
/// - **A click calls `actions` or `rowActions`**, which read the screen again and ask the root.
///   Neither selects anything itself.
/// - **The per-fan control adds no reason of its own.** Why control is disabled is the control
///   for all fans' to say, attributed to the fans it is about. A row draws its control greyed
///   beside what it already showed: its own line for a helper refusal (`FanRowModel.refusal`).
/// - **The change-of-fan-set sentence** (`FanRowControlPresentation.changeOfFanSet`) is said once,
///   above the rows, whenever any row draws a control.
/// - **No row draws one while the helper grants only every-fan leases** (#670): a fan's own Custom
///   would be refused, and its own Auto would hand back every fan, so `drawsControl(_:)` answers
///   `false` for every row and the control for all fans is the window's only control.
///
/// ## The monitoring-mode line (#157)
///
/// Above the control, `MonitoringModeDisplay`'s banner when it has one: the user chose Auto, the
/// helper refuses manual control, the system reclaimed fans, or this build has no helper. Computed
/// in `body` from the same read of `viewModel` and `leaseState` as the control.
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
    /// The root's per-fan entry points, as each row calls them.
    private let rowActions: FanRowControlActions

    /// - Parameters:
    ///   - viewModel: The window's view model, which `MainView` starts and stops.
    ///   - composition: The app's one root: the control's lease state and its entry points are
    ///     both read from it here, so the view cannot be given one root's state and another's
    ///     actions.
    init(viewModel: PollingViewModel, composition: AppComposition) {
        self.viewModel = viewModel
        _leaseState = ObservedObject(wrappedValue: composition.leaseState)
        actions = AllFansControlActions(composition: composition)
        rowActions = FanRowControlActions(composition: composition)
    }

    /// One fan's row as drawn: its reading, and its per-fan control's inputs.
    private struct Row: Identifiable {
        let reading: FanPollingReading
        let control: FanRowControlPresentation.Inputs
        var id: Int { reading.index }
    }

    var body: some View {
        // One read of the window and the lease, for everything below.
        let report = leaseState.current
        let fans = FanControlPresentation.onScreen(in: viewModel, driver: report)
        let snapshot = viewModel.renderedSnapshot
        let rows = zip(
            fans,
            FanRowControlPresentation.Inputs.rows(fans, snapshot: snapshot, driver: report.state)
        )
        .map { Row(reading: $0.0.reading, control: $0.1) }
        let banner = MonitoringModeDisplay.banner(
            given: MonitoringModeDisplay.Inputs(
                controlSource: viewModel.controlSource,
                thermalEmergency: viewModel.thermalEmergency, fans: fans, driver: report.state,
                enteredAfterTheUsersAuto: leaseState.enteredAfterTheUsersAuto))
        VStack(alignment: .leading, spacing: 0) {
            Text("Fans")
                .font(.headline)
                .padding([.horizontal, .top])

            PollingStatusBanner(
                status: PollingStatusDisplay.text(
                    phase: viewModel.phase, lastUpdated: viewModel.lastUpdated))

            controlSourceLine(ControlSourceDisplay.text(for: viewModel.controlSource))

            if let banner {
                MonitoringModeBanner(banner: banner)
            }

            AllFansControlView(
                control: AllFansControlPresentation(fans: fans, snapshot: snapshot),
                choose: { percent in actions.choose(percent, on: viewModel) },
                chooseAutomatic: { actions.chooseAutomatic() })

            if rows.contains(where: { Self.drawsControl($0.control) }) {
                Text(FanRowControlPresentation.changeOfFanSet)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }

            if rows.isEmpty {
                emptyState
            } else {
                // Builds FanRowModel per row inside the closure, rather than mapping the whole
                // array on every render: that would allocate a fresh [FanRowModel] on every
                // refresh tick even for rows SwiftUI's own diffing would otherwise skip
                // re-evaluating.
                List(rows) { row in
                    let index = row.reading.index
                    FanRowView(
                        row: FanRowModel(reading: row.reading), control: row.control,
                        chooseAutomatic: { rowActions.chooseAutomatic(fan: index) },
                        chooseCustom: { rowActions.chooseCustom(fan: index, on: viewModel) },
                        submit: { text in rowActions.submit(text, fan: index, on: viewModel) },
                        step: { direction, field in
                            rowActions.step(direction, from: field, fan: index, on: viewModel)
                        })
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 320)
    }

    /// Whether a row with `control` draws any per-fan control, whatever the user is typing: never
    /// while the helper grants only every-fan leases (`FanRowControlPresentation.isOffered`,
    /// #670), so the change-of-fan-set sentence is not said either.
    static func drawsControl(_ control: FanRowControlPresentation.Inputs) -> Bool {
        FanRowControlPresentation.isOffered
            && FanRowControlPresentation(control, field: .init()).drawsControl
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
