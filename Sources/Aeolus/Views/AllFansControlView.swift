import SwiftUI

/// Draws an `AllFansControlPresentation`, and nothing else: Auto, 50 %, 75 % and 100 % for every
/// fan, with the reason it is disabled, the release offer, and the lines beneath it (#153's PR
/// 6b).
///
/// Separate buttons rather than a segmented `Picker`, because a picker cannot enable one segment
/// alone: Auto must stay enabled while the percentages are disabled whenever a release is offered.
///
/// It decides nothing. Which segment is selected, which is pending, what is enabled and what
/// each line says all come from the presentation, and a click only calls `choose` or
/// `chooseAutomatic`; the next presentation says what came of it.
struct AllFansControlView: View {
    let control: AllFansControlPresentation
    let choose: (FanSpeedPercent) -> Void
    let chooseAutomatic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("All fans")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if control.drawsControl {
                buttons
            }
            switch control.affordance {
            case .hidden(let reason):
                reasonView(.init(fans: nil, value: reason))
            case .disabled(let reasons):
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    reasonView(reason)
                }
            case .enabled:
                EmptyView()
            }
            ForEach(Array(control.statusLines.enumerated()), id: \.offset) { _, line in
                statusView(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            segment(
                "Auto", isSelected: control.selection == .automatic, isPending: false,
                isEnabled: control.automaticIsEnabled,
                help:
                    "Releases the manual-control lease, if one is held. What the fans do next is "
                    + "the helper's snapshot to show.",
                action: chooseAutomatic)
            ForEach(FanSpeedPercent.allCases, id: \.self) { percent in
                segment(
                    percent.label, isSelected: control.selection == .percent(percent),
                    isPending: control.selection == .pending(percent),
                    isEnabled: control.percentsAreEnabled,
                    help:
                        "Every fan at \(percent.label) of its commandable range, as the helper "
                        + "reports it. The helper clamps every speed again.",
                    action: { choose(percent) })
            }
        }
        .controlSize(.small)
    }

    /// One segment. Selected is drawn prominent; pending is drawn as asked for, with a spinner,
    /// never as achieved.
    @ViewBuilder
    private func segment(
        _ title: String, isSelected: Bool, isPending: Bool, isEnabled: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        let label = HStack(spacing: 4) {
            Text(title)
            if isPending {
                ProgressView().controlSize(.mini)
            }
        }
        Group {
            if isSelected {
                Button(action: action) { label }
                    .buttonStyle(.borderedProminent)
                    .accessibilityAddTraits(.isSelected)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.bordered)
                    .accessibilityValue(isPending ? "Asked for, not confirmed" : "")
            }
        }
        .disabled(!isEnabled)
        .help(help)
    }

    /// A refusal: whose it is when not every fan's, the reason's own summary, its wire value
    /// beside it as a raw key sits beside a label, and its advice.
    private func reasonView(
        _ reason: AllFansControlPresentation.Attributed<FanControlPresentation.Reason>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Self.prefixed(reason.value.summary, by: reason.fans))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let wireValue = reason.value.wireValue {
                    Text("(\(wireValue))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            if let advice = reason.value.advice {
                Text(advice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func statusView(
        _ line: AllFansControlPresentation.Attributed<FanControlPresentation.StatusLine>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.prefixed(line.value.text, by: line.fans))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = line.value.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `text`, after the fans it is about when it is not about every fan.
    static func prefixed(_ text: String, by fans: [String]?) -> String {
        guard let fans, !fans.isEmpty else { return text }
        return fans.joined(separator: ", ") + ": " + text
    }
}
