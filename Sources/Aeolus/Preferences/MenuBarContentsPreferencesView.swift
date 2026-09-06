import SwiftUI

/// The "Menu Bar" tab: which fan and sensor readouts show in the menu bar — every fan and
/// sensor `pollingViewModel` currently sees is a toggleable candidate, per
/// `MenuBarContentsSelection.candidates(fans:sensors:)`.
///
/// Toggling here does two things, not one: it persists the choice via
/// `preferencesController.setMenuBarReadouts(_:)`, and it calls
/// `menuBarViewModel.setSelection(_:)` so the menu bar item itself updates immediately —
/// without that second call, a change here would only be visible after Aeolus restarts,
/// which is a worse experience than the cost (one extra method call) of keeping both in
/// sync.
struct MenuBarContentsPreferencesView: View {
    @ObservedObject var preferencesController: PreferencesController
    @ObservedObject var pollingViewModel: PollingViewModel
    @ObservedObject var menuBarViewModel: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose what appears in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top])

            if candidates.isEmpty {
                Spacer()
                Text("No fans or sensors discovered yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(candidates) { readout in
                    row(for: readout)
                }
                .listStyle(.inset)
            }
        }
        .padding(.bottom)
    }

    private var candidates: [MenuBarReadout] {
        MenuBarContentsSelection.candidates(
            fans: pollingViewModel.fans, sensors: pollingViewModel.sensors)
    }

    private var defaultSelection: [MenuBarReadout] {
        MenuBarReadoutSelection.defaultSelection(
            fans: pollingViewModel.fans, sensors: pollingViewModel.sensors)
    }

    private func row(for readout: MenuBarReadout) -> some View {
        let resolved = readout.resolve(
            fans: pollingViewModel.fans, sensors: pollingViewModel.sensors)
        return Toggle(
            isOn: Binding(
                get: {
                    MenuBarContentsSelection.isIncluded(
                        readout, in: preferencesController.preferences.menuBarReadouts,
                        defaultSelection: defaultSelection)
                },
                set: { _ in
                    let updated = MenuBarContentsSelection.toggling(
                        readout, in: preferencesController.preferences.menuBarReadouts,
                        defaultSelection: defaultSelection)
                    preferencesController.setMenuBarReadouts(updated)
                    menuBarViewModel.setSelection(updated)
                })
        ) {
            HStack {
                Text(resolved.label ?? readout.key)
                Text(readout.key)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
            }
        }
    }
}
