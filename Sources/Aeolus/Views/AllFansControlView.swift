import SwiftUI

/// Draws an `AllFansControlPresentation`, and nothing else: Auto, 50 %, 75 % and 100 % for every
/// fan, with the reason it is disabled, the release offer, and the lines beneath it (#153's PR
/// 6b).
///
/// Separate buttons rather than a segmented `Picker`, because a picker cannot enable one segment
/// alone: Auto must stay enabled while the percentages are disabled whenever a release is offered.
///
/// It decides nothing. Which segment is selected, which is pending, what is enabled and what
/// each line says all come from the presentation, through `segments(for:)` and `labelMark(for:)`,
/// and a click only reaches `perform(_:)`, which calls `choose` or `chooseAutomatic`; the next
/// presentation says what came of it. What the suite cannot see is the one `Button` closure that
/// calls `perform(_:)`: that needs a hosted window.
struct AllFansControlView: View {
    let control: AllFansControlPresentation
    let choose: (FanSpeedPercent) -> Void
    let chooseAutomatic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            label
            let segments = Self.segments(for: control)
            if !segments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(segments) { segment in
                        button(segment)
                    }
                }
                .controlSize(.small)
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

    /// "All fans", with a spinner while a lease is held that nothing on screen confirms
    /// (`labelMark(for:)`).
    private var label: some View {
        HStack(spacing: 4) {
            Text("All fans")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if Self.labelMark(for: control.selection) == .pending {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Held, not confirmed")
            }
        }
    }

    /// How a segment, or the control's label, is drawn: as the selection, as asked for and not
    /// yet answered, or neither.
    enum Mark: Equatable {
        case selected, pending, plain
    }

    /// One segment as drawn: what a click on it does, how it is marked, and whether it may be
    /// clicked.
    struct Segment: Equatable, Identifiable {

        /// What a click asks for.
        enum Action: Hashable {
            case automatic
            case percent(FanSpeedPercent)
        }

        let action: Action
        let mark: Mark
        let isEnabled: Bool

        var id: Action { action }

        var title: String {
            switch action {
            case .automatic: return "Auto"
            case .percent(let percent): return percent.label
            }
        }

        var help: String {
            switch action {
            case .automatic:
                return "Releases the manual-control lease, if one is held. What the fans do next "
                    + "is the helper's snapshot to show."
            case .percent(let percent):
                return "Every fan at \(percent.label) of its commandable range, as the helper "
                    + "reports it. The helper clamps every speed again."
            }
        }
    }

    /// Every segment `control` draws, in order: none when it draws no control, otherwise Auto and
    /// then each percentage. Auto is enabled whenever a release is offered; the percentages only
    /// when the control is enabled.
    static func segments(for control: AllFansControlPresentation) -> [Segment] {
        guard control.drawsControl else { return [] }
        let automatic = Segment(
            action: .automatic, mark: control.selection == .automatic ? .selected : .plain,
            isEnabled: control.automaticIsEnabled)
        let percents = FanSpeedPercent.allCases.map { percent in
            Segment(
                action: .percent(percent), mark: mark(percent, in: control.selection),
                isEnabled: control.percentsAreEnabled)
        }
        return [automatic] + percents
    }

    /// The mark `selection` gives the segment for `percent`.
    static func mark(
        _ percent: FanSpeedPercent, in selection: AllFansControlPresentation.Selection
    ) -> Mark {
        switch selection {
        case .percent(let selected) where selected == percent: return .selected
        case .pending(let asked) where asked == percent: return .pending
        case .automatic, .percent, .pending, .checking, .none: return .plain
        }
    }

    /// The mark the control's label carries: pending while every fan is `.checking`, a lease held
    /// with no licensed snapshot on screen to name the percentage it holds, so no segment can be.
    static func labelMark(for selection: AllFansControlPresentation.Selection) -> Mark {
        switch selection {
        case .checking: return .pending
        case .automatic, .percent, .pending, .none: return .plain
        }
    }

    /// What a click on a segment does: the one place an action reaches `choose` or
    /// `chooseAutomatic`.
    func perform(_ action: Segment.Action) {
        switch action {
        case .automatic: chooseAutomatic()
        case .percent(let percent): choose(percent)
        }
    }

    /// One segment. Selected is drawn prominent; pending is drawn as asked for, with a spinner,
    /// never as achieved.
    @ViewBuilder
    private func button(_ segment: Segment) -> some View {
        let label = HStack(spacing: 4) {
            Text(segment.title)
            if segment.mark == .pending {
                ProgressView().controlSize(.mini)
            }
        }
        Group {
            if segment.mark == .selected {
                Button(action: { perform(segment.action) }) { label }
                    .buttonStyle(.borderedProminent)
                    .accessibilityAddTraits(.isSelected)
            } else {
                Button(action: { perform(segment.action) }) { label }
                    .buttonStyle(.bordered)
                    .accessibilityValue(segment.mark == .pending ? "Asked for, not confirmed" : "")
            }
        }
        .disabled(!segment.isEnabled)
        .help(segment.help)
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
