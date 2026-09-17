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

    /// `Preferences.temperatureUnit`. Defaults to `.celsius`, preserving this view's
    /// existing rendering for every call site that does not pass one explicitly.
    var temperatureUnit: TemperatureUnit = .celsius

    var body: some View {
        Label(labelText, systemImage: iconName)
            .labelStyle(.titleAndIcon)
            .onAppear { viewModel.start() }
            .onDisappear { viewModel.stop() }
    }

    /// Every currently-selected readout, in selection order, through
    /// `MenuBarReadoutFormatting.stripText(for:temperatureUnit:)` — the same formatter
    /// `MenuBarContentView`'s dropdown rows use, so a readout is never described one way
    /// in the strip and another in the dropdown. An unavailable reading renders as
    /// `"unavailable (<reason>)"`, never as `0` or a blank space that could be mistaken
    /// for one — see `ReadingFormatting.text(for:unit:)`'s own documentation. Per `#249`,
    /// every entry also always carries its label or raw key, so a value's meaning is
    /// never left to the reader to infer from where it sits in the list — see
    /// `MenuBarReadoutFormatting`'s own documentation.
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
        return MenuBarReadoutFormatting.stripText(
            for: viewModel.readouts, temperatureUnit: temperatureUnit)
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
