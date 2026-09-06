import SwiftUI

/// The Settings scene (`#64`): sensor selection, units, refresh interval, menu bar
/// contents, and launch at login, all wired to `PreferencesController`.
///
/// Owns one dedicated `PollingViewModel`, independent of `MainView`'s and
/// `MenuBarViewModel`'s own — the same "independent consumers of the same data layer"
/// design `MenuBarViewModel`'s documentation already argues for: this window needs live
/// fan/sensor data to populate the sensor-selection and menu-bar-contents lists, and
/// coupling it to either of those other two instances would tie three independently
/// developed view trees together for a cost (one more 1 Hz poll while this window is
/// open) that is small and already paid twice over elsewhere in this app.
struct PreferencesView: View {
    @ObservedObject var preferencesController: PreferencesController
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    /// The live menu bar's own view model — passed in (not constructed here) so toggling
    /// a menu-bar-contents checkbox can update what is *currently showing* immediately,
    /// via `MenuBarViewModel.setSelection(_:)`, rather than only taking effect after a
    /// relaunch.
    @ObservedObject var menuBarViewModel: MenuBarViewModel

    @StateObject private var pollingViewModel = PollingViewModel(
        labelSource: CatalogSensorLabelSource.loadDefault())

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            SensorSelectionPreferencesView(
                preferencesController: preferencesController, pollingViewModel: pollingViewModel
            )
            .tabItem { Label("Sensors", systemImage: "thermometer") }
            MenuBarContentsPreferencesView(
                preferencesController: preferencesController, pollingViewModel: pollingViewModel,
                menuBarViewModel: menuBarViewModel
            )
            .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
        }
        .frame(width: 460, height: 360)
        .onAppear { pollingViewModel.start() }
        .onDisappear { pollingViewModel.stop() }
    }

    private var generalTab: some View {
        Form {
            Section("Units") {
                Picker(
                    "Temperature",
                    selection: Binding(
                        get: { preferencesController.preferences.temperatureUnit },
                        set: { preferencesController.setTemperatureUnit($0) })
                ) {
                    ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                        Text(unit == .celsius ? "Celsius (°C)" : "Fahrenheit (°F)").tag(unit)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Refresh Interval") {
                refreshIntervalControl
            }

            Section("Startup") {
                Toggle(
                    "Launch Aeolus at login",
                    isOn: Binding(
                        get: { launchAtLoginController.isEnabled },
                        set: { launchAtLoginController.setEnabled($0) })
                )
                Text(LoginItemStatusDisplay.text(for: launchAtLoginController.registrationStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var refreshIntervalControl: some View {
        VStack(alignment: .leading) {
            Slider(
                value: Binding(
                    get: { preferencesController.preferences.refreshInterval },
                    set: { preferencesController.setRefreshInterval($0) }),
                in: PreferencesRefreshInterval.minimum...PreferencesRefreshInterval.maximum
            ) {
                Text("Refresh Interval")
            }
            Text(
                String(
                    format: "Every %.1fs (%.1fs–%.0fs)",
                    preferencesController.preferences.refreshInterval,
                    PreferencesRefreshInterval.minimum, PreferencesRefreshInterval.maximum)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Takes effect the next time this window's data or the menu bar restarts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
