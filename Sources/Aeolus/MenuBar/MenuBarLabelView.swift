import SwiftUI

/// What actually appears in the menu bar itself: an icon plus every currently-selected
/// readout's compact text, side by side — the "multiple simultaneous readouts" this epic
/// asks for, always visible without opening the dropdown.
///
/// Owns `viewModel`'s start/stop lifecycle: this view mounts once, for as long as the
/// menu bar item exists (unlike `MenuBarContentView`, which under `.window` style only
/// exists while the dropdown is actually open), so it — not the content view — is the
/// right place to start the poll loop per `PollingViewModel.start()`'s documented
/// contract ("the owning view is responsible for calling `stop()`").
struct MenuBarLabelView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        Label(labelText, systemImage: iconName)
            .labelStyle(.titleAndIcon)
            .onAppear { viewModel.start() }
            .onDisappear { viewModel.stop() }
    }

    /// Every currently-selected readout's formatted value, in selection order, separated
    /// by two spaces — through the same `Views/ReadingFormatting.text(for:unit:)` `#62`'s
    /// main window renders every fan/sensor row with, so the same key never shows two
    /// different values at the same moment. An unavailable reading renders as
    /// `"unavailable (<reason>)"`, never as `0` or a blank space that could be mistaken
    /// for one — see `ReadingFormatting.text(for:unit:)`'s own documentation.
    private var labelText: String {
        guard !viewModel.readouts.isEmpty else {
            switch viewModel.phase {
            case .notStarted, .polling:
                return "\u{2026}"  // ellipsis: still waiting on the first reading.
            case .ready:
                return "no readouts"
            case .failed:
                return "offline"
            }
        }
        return
            viewModel.readouts
            .map { ReadingFormatting.text(for: $0.reading, unit: $0.unit) }
            .joined(separator: "  ")
    }

    /// Honest about reclamation and thermal state rather than a fixed icon — see
    /// `CLAUDE.md` rule 6: this must never look identical to the normal state while the
    /// system has actually taken a fan back or declared an emergency. Both conditions are
    /// hardcoded false/absent under `Monitor` today (see `PollingViewModel`'s
    /// documentation), so this always resolves to `"fan"` in this build; the branches
    /// exist so nothing has to change here once a real answer is possible.
    private var iconName: String {
        if viewModel.isThermalEmergencyActive {
            return "exclamationmark.triangle.fill"
        }
        if viewModel.readouts.contains(where: { $0.fanControlState?.isReclaimedBySystem == true }) {
            return "exclamationmark.triangle"
        }
        return "fan"
    }
}
