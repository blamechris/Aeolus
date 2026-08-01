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
    @StateObject private var menuBarViewModel = MenuBarViewModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainView()
        }

        // `MenuBarExtra` with multiple simultaneous readouts (`MenuBarLabelView`) and a
        // detail dropdown (`MenuBarContentView`) — see `MenuBar/` for the readout model
        // and view model.
        //
        // - Note: `MenuBarExtra` itself, `.menuBarExtraStyle(.window)`, and the
        //   `content:label:` initializer used here are all macOS 13+, matching this
        //   project's deployment floor — nothing in this Scene needed raising it.
        //   `MenuBarExtra(isInserted:content:label:)` was deliberately *not* used,
        //   despite existing since macOS 13.0 in the installed SDK (contrary to this
        //   project's working assumption that it needed a macOS 14 gate — see this PR's
        //   description for the SDK evidence): it is a documented source of real bugs on
        //   Ventura (`isInserted` bindings driven by `@AppStorage`/`@Published`
        //   triggering "Publishing changes from within view updates" loops, fixed only in
        //   Sonoma), and `SceneBuilder` — unlike `ViewBuilder` — has no `buildEither`, so
        //   there is no way to branch between the `isInserted:` and plain initializers
        //   for two different OS versions in one `Scene` body regardless. The
        //   macOS-14-only refinement this epic's acceptance criteria ask to be gated
        //   lives instead in `MenuBarContentView`, in the view layer, where `#available`
        //   branching is fully supported.
        MenuBarExtra {
            MenuBarContentView(viewModel: menuBarViewModel)
        } label: {
            MenuBarLabelView(viewModel: menuBarViewModel)
        }
        .menuBarExtraStyle(.window)
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
///
/// The footer states where the privileged helper stands. It is rendered in every build,
/// including `Monitor`, where the honest answer is that this build ships no helper at all
/// — see `HelperStatusDisplay`. A window that said nothing at all about the helper would
/// leave "can this app change my fans?" to be inferred, and inference is what `CLAUDE.md`
/// rule 6 exists to prevent.
struct MainView: View {
    @StateObject private var viewModel = PollingViewModel(
        labelSource: CatalogSensorLabelSource.loadDefault())
    @StateObject private var helperController = HelperLifecycleController()

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
            Divider()
            HelperStatusView(controller: helperController)
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}
