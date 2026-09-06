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
    @StateObject private var preferencesController: PreferencesController
    @StateObject private var launchAtLoginController: LaunchAtLoginController
    @StateObject private var menuBarViewModel: MenuBarViewModel

    public init() {
        // `preferencesController` must exist before the other two `StateObject`s: both
        // read its already-loaded `Preferences` value once, at construction, to seed the
        // refresh interval and menu bar selection this build starts with — see
        // `PreferencesRefreshInterval`'s and `Preferences.menuBarReadouts`'s own
        // documentation for why those are read here rather than left at
        // `PollingViewModel`'s and `MenuBarViewModel`'s own hardcoded defaults.
        let preferencesController = PreferencesController()
        _preferencesController = StateObject(wrappedValue: preferencesController)
        _launchAtLoginController = StateObject(
            wrappedValue: LaunchAtLoginController(preferences: preferencesController))
        _menuBarViewModel = StateObject(
            wrappedValue: MenuBarViewModel(
                polling: PollingViewModel(
                    labelSource: CatalogSensorLabelSource.loadDefault(),
                    refreshInterval: preferencesController.preferences.refreshInterval),
                selection: preferencesController.preferences.menuBarReadouts))
    }

    public var body: some Scene {
        WindowGroup {
            MainView(preferencesController: preferencesController)
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
            MenuBarContentView(
                viewModel: menuBarViewModel,
                temperatureUnit: preferencesController.preferences.temperatureUnit)
        } label: {
            MenuBarLabelView(
                viewModel: menuBarViewModel,
                temperatureUnit: preferencesController.preferences.temperatureUnit)
        }
        .menuBarExtraStyle(.window)

        // The Settings scene (`#64`): sensor selection, units, refresh interval, menu bar
        // contents, and launch at login. macOS surfaces this as "Aeolus › Settings…" (or
        // "Preferences…" pre-Ventura) automatically — no menu item is defined for it here.
        Settings {
            PreferencesView(
                preferencesController: preferencesController,
                launchAtLoginController: launchAtLoginController,
                menuBarViewModel: menuBarViewModel)
        }
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
    @ObservedObject var preferencesController: PreferencesController
    @StateObject private var viewModel: PollingViewModel
    @StateObject private var helperController = HelperLifecycleController()

    /// Reads `preferencesController.preferences.refreshInterval` once, at construction,
    /// to seed this window's own `PollingViewModel` — see `AeolusApp.init()`'s identical
    /// note on why a preference changed later needs this window reopened to take effect
    /// on the refresh cadence specifically (`selectedSensorKeys`/`temperatureUnit`, by
    /// contrast, are read fresh on every `body` evaluation below and apply immediately).
    init(preferencesController: PreferencesController) {
        self.preferencesController = preferencesController
        _viewModel = StateObject(
            wrappedValue: PollingViewModel(
                labelSource: CatalogSensorLabelSource.loadDefault(),
                refreshInterval: preferencesController.preferences.refreshInterval))
    }

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
                SensorListView(
                    viewModel: viewModel,
                    selectedKeys: preferencesController.preferences.selectedSensorKeys,
                    temperatureUnit: preferencesController.preferences.temperatureUnit)
            }
            Divider()
            HelperStatusView(controller: helperController)
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}
