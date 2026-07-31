import AeolusXPC
import FanKit
import SwiftUI

/// The SwiftUI application.
///
/// This target is a *view* of helper state, not an owner of it. It edits configuration
/// and renders snapshots; it never writes to the SMC and never holds authoritative fan
/// state. Closing the window or quitting the app is always safe.
///
/// Built two ways:
///   * `Monitor` — read-only, no helper, no entitlements. Ad-hoc signable, so anyone can
///     build and run it. All of the UI work happens here.
///   * `Full` — embeds and registers the privileged helper. Needs a Developer ID.
///
/// - Note: `@main` is applied by the Xcode app target generated from `project.yml`. This
///   type is compiled as a plain library under `swift build` so CI type-checks the views
///   without needing an app bundle.
public struct AeolusApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainView()
        }

        // TODO(E7): MenuBarExtra with multiple simultaneous readouts and sparklines.
    }
}

/// The two-pane main window: fans on the left, sensors on the right — both bound to the
/// same `PollingViewModel`, so they always reflect the same refresh tick.
///
/// This view owns the view model's lifecycle: `start()` on appear, `stop()` on disappear
/// per that method's own documentation, so no SMC traffic continues once the window is
/// gone. The label source is the real catalog (`CatalogSensorLabelSource.loadDefault()`)
/// rather than `PollingViewModel`'s own `NoSensorLabels()` default — E6's catalog is
/// seeded for this project's development hardware, and a window that never showed a
/// label would not demonstrate what #62 is actually for. A machine with no matching
/// catalog entries still works fully unlabelled either way — see `SensorLabelSource`.
struct MainView: View {
    @StateObject private var viewModel = PollingViewModel(
        labelSource: CatalogSensorLabelSource.loadDefault())

    var body: some View {
        VStack(spacing: 0) {
            // Hardcoded false under Monitor today — see
            // `PollingViewModel.isThermalEmergencyActive`'s documentation — but the
            // rendering path exists unconditionally so a real emergency never needs a
            // first-ever UI change to be shown honestly.
            if viewModel.isThermalEmergencyActive {
                ThermalEmergencyBanner()
            }
            HSplitView {
                FanListView(viewModel: viewModel)
                SensorListView(viewModel: viewModel)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}
