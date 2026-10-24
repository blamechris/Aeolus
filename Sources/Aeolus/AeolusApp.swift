import AeolusXPC
import AppKit
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

    /// The app's one reader of helper snapshots, shared by every `PollingViewModel` — the
    /// window's, the menu bar's and the Settings window's. A plain constant rather than a
    /// `StateObject`: nothing renders the source itself, and `init()` runs once per process.
    /// In a build with no helper it holds no client at all (`HelperSnapshotSource.forBundle`).
    /// It reads the refresh interval preference live, so its cadence and freshness bound
    /// follow a change at once.
    private let snapshots: HelperSnapshotSource

    public init() {
        // `preferencesController` must exist before the other two `StateObject`s: both
        // read its already-loaded `Preferences` value once, at construction, to seed the
        // refresh interval and menu bar selection this build starts with (the snapshot
        // source alone reads the interval live, through the closure below) — see
        // `PreferencesRefreshInterval`'s and `Preferences.menuBarReadouts`'s own
        // documentation for why those are read here rather than left at
        // `PollingViewModel`'s and `MenuBarViewModel`'s own hardcoded defaults.
        let preferencesController = PreferencesController()
        _preferencesController = StateObject(wrappedValue: preferencesController)
        let snapshots = HelperSnapshotSource.forRunningApp(
            refreshInterval: { preferencesController.preferences.refreshInterval })
        self.snapshots = snapshots
        _launchAtLoginController = StateObject(
            wrappedValue: LaunchAtLoginController(preferences: preferencesController))
        _menuBarViewModel = StateObject(
            wrappedValue: MenuBarViewModel(
                polling: PollingViewModel(
                    labelSource: CatalogSensorLabelSource.loadDefault(),
                    refreshInterval: preferencesController.preferences.refreshInterval,
                    snapshots: snapshots),
                selection: preferencesController.preferences.menuBarReadouts))
    }

    public var body: some Scene {
        WindowGroup {
            MainView(preferencesController: preferencesController, snapshots: snapshots)
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
                temperatureUnit: preferencesController.preferences.temperatureUnit
            )
            // Here rather than in the window, because the menu bar item is always mounted:
            // coming back to the app is when an approval made in System Settings may have
            // taken effect, so a backoff from the helper's earlier absence ends now. Only a
            // pause is cut short; no request is cancelled or doubled (`retrySoon()`).
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)
            ) { _ in
                snapshots.retrySoon()
            }
        }
        .menuBarExtraStyle(.window)

        // The Settings scene (`#64`): sensor selection, units, refresh interval, menu bar
        // contents, and launch at login. macOS surfaces this as "Aeolus › Settings…" (or
        // "Preferences…" pre-Ventura) automatically — no menu item is defined for it here.
        Settings {
            PreferencesView(
                preferencesController: preferencesController,
                launchAtLoginController: launchAtLoginController,
                menuBarViewModel: menuBarViewModel,
                snapshots: snapshots)
        }
    }
}

/// The two-pane main window: fans on the left, sensors on the right — both bound to the
/// same `PollingViewModel`, so they always reflect the same refresh tick, and that view
/// model reads the app's one `HelperSnapshotSource`.
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
    private let snapshots: HelperSnapshotSource

    /// Reads `preferencesController.preferences.refreshInterval` once, at construction,
    /// to seed this window's own `PollingViewModel`: how often this window redraws, and how
    /// often it reads the SMC itself on the direct-read path, change when the window is
    /// reopened. The helper's snapshots follow a change at once, because the shared source
    /// reads the preference live. (`selectedSensorKeys`/`temperatureUnit` are read fresh on
    /// every `body` evaluation below and apply immediately.)
    init(preferencesController: PreferencesController, snapshots: HelperSnapshotSource) {
        self.preferencesController = preferencesController
        self.snapshots = snapshots
        _viewModel = StateObject(
            wrappedValue: PollingViewModel(
                labelSource: CatalogSensorLabelSource.loadDefault(),
                refreshInterval: preferencesController.preferences.refreshInterval,
                snapshots: snapshots))
    }

    private var thermalEmergencyBanner: ThermalEmergencyDisplay.Banner? {
        ThermalEmergencyDisplay.banner(
            for: viewModel.thermalEmergency, source: viewModel.controlSource)
    }

    var body: some View {
        VStack(spacing: 0) {
            // On, off or unknown — the last whenever no fresh helper snapshot speaks, which is
            // always under Monitor. See `ThermalEmergencyDisplay` for why unknown is a line of
            // its own rather than no banner.
            if let banner = thermalEmergencyBanner {
                ThermalEmergencyBanner(banner: banner)
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
        // macOS just reported the helper enabled — typically the approval the footer asked
        // for — so a backoff from its earlier absence ends now, rather than leaving this pane
        // saying "cannot reach its helper" beside a footer saying "installed and enabled".
        .onReceive(helperController.$state) { state in
            if state == .enabled { snapshots.retrySoon() }
        }
    }
}
