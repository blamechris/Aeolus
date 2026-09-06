import AppKit
import SwiftUI

/// The menu bar item's dropdown: every selected readout in full, plus honest status text
/// and a way to quit.
///
/// No control affordance anywhere — like `#62`'s main window, this epic is read-only
/// monitoring. Adding a slider or a "set speed" action here would cross into E8a/E10b's
/// scope, not merely arrive early.
struct MenuBarContentView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    /// `Preferences.temperatureUnit`. Defaults to `.celsius`, preserving this view's
    /// existing rendering for every call site that does not pass one explicitly.
    var temperatureUnit: TemperatureUnit = .celsius

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isThermalEmergencyActive {
                Label("Thermal emergency active", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            if viewModel.readouts.isEmpty {
                emptyReadoutsView
            } else {
                ForEach(viewModel.readouts) { readout in
                    MenuBarReadoutRow(readout: readout, temperatureUnit: temperatureUnit)
                }
            }

            Divider()

            statusText
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit Aeolus") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(minWidth: 240)
    }

    /// Shown when nothing is currently selected — either no fan/sensor has been chosen
    /// yet, or (once `#64` lands a real picker) a user deliberately picked nothing.
    ///
    /// This is this file's deliberate `@available` gate: `ContentUnavailableView` is
    /// macOS 14+ (`SwiftUI`'s own richer replacement for a bare "nothing here" `Text`),
    /// used only where it is actually available — the macOS 13 branch renders the same
    /// message as a plain, styled `Text` instead. Per `CLAUDE.md`, this deployment
    /// floor stays 13; a newer API is opted into per-view, not by raising it. Unlike
    /// `MenuBarExtra(isInserted:content:label:)` (see `AeolusApp`'s documentation for why
    /// that one was avoided entirely), this gate sits in a plain `View`, where
    /// `ViewBuilder`'s `if`/`else` — unlike `SceneBuilder`'s — fully supports branching
    /// on `#available`.
    @ViewBuilder
    private var emptyReadoutsView: some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView(
                "No Readouts Selected", systemImage: "gauge.with.dots.needle.33percent",
                description: Text("Choose what to show here from Preferences."))
        } else {
            Text("No readouts selected")
                .foregroundStyle(.secondary)
        }
    }

    /// Status text driven entirely by `viewModel.phase`/`.lastUpdated` — never inferred
    /// from whether `readouts` happens to be non-empty, which would conflate "no
    /// readouts selected" with "the last poll failed." See `PollingPhase`'s own
    /// documentation for why that distinction is load-bearing.
    @ViewBuilder
    private var statusText: some View {
        switch viewModel.phase {
        case .notStarted:
            Text("Waiting for first reading\u{2026}")
        case .polling:
            Text("Refreshing\u{2026}")
        case .ready:
            if let lastUpdated = viewModel.lastUpdated {
                Text("Updated \(Self.timeFormatter.string(from: lastUpdated))")
            } else {
                Text("Updated")
            }
        case .failed(let error):
            Text("Last refresh failed: \(error.description)")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// One resolved readout: raw key always visible alongside any label, per `CLAUDE.md`'s
/// rule that a friendly label never stands in for the key it came from.
private struct MenuBarReadoutRow: View {
    let readout: ResolvedMenuBarReadout
    var temperatureUnit: TemperatureUnit = .celsius

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(readout.label ?? readout.key)
                    .font(.body)
                if readout.label != nil {
                    Text(readout.key)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fontDesign(.monospaced)
                }
            }

            Spacer()

            if let state = readout.fanControlState, state.isReclaimedBySystem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("System reclaimed control of this fan")
            }

            Text(displayText)
                .fontDesign(.monospaced)
        }
    }

    /// Converts `readout.reading` for `temperatureUnit` before formatting — the same
    /// `TemperatureDisplay` seam `SensorRowModel` uses for the main window, so a
    /// temperature reading never shows two different converted values depending on which
    /// view rendered it.
    private var displayText: String {
        let displayReading = TemperatureDisplay.convert(
            readout.reading, kind: readout.kind, to: temperatureUnit)
        let unit =
            TemperatureDisplay.unit(for: readout.kind, temperatureUnit: temperatureUnit)
            ?? readout.unit
        return ReadingFormatting.text(for: displayReading, unit: unit)
    }
}
