import SwiftUI

/// One fan's row in `FanListView`: name, control state, the helper's refusal if it
/// refuses, and the actual/minimum/maximum RPM readings — each with its raw SMC key shown
/// alongside it, per `CLAUDE.md`.
///
/// ## Per-fan control (#154, #153's PR 8b)
///
/// Beneath the name, an Auto/Custom segment, and while the fan is in Custom, a target RPM field
/// with a stepper. It draws a `FanRowControlPresentation` and nothing else: what is selected, what
/// is enabled, what the field shows and the courtesy line all come from it, and a click only
/// reaches `perform(_:)`, which calls one of the closures `FanListView` hands it. Those read the
/// screen again and ask the root (`FanRowControlActions`). The `Monitor` build draws none of it,
/// and the control adds no reason of its own to the row's refusal line or to the control for all
/// fans.
///
/// The field is labelled as a target, never beside the actual reading as if it were one, and
/// shows the driver's target, never the snapshot's (`CLAUDE.md` rule 6).
///
/// **The view's own state is the edit alone:** the draft while the field has focus, and the last
/// Return's courtesy line. It changes that state only through `FieldState`'s pure functions and
/// `submit`: focus gained starts the draft from what the field shows, focus lost drops it so the
/// field reverts to what the driver asks for, and a stepper click resets it. The view only calls
/// them, from `onChange(of:)`, the binding and `stepped(_:)`.
///
/// **What the suite cannot see is this view's own `body`**, as for `AllFansControlView`: the
/// buttons, the field's `onSubmit` and focus handling, and the stepper's closures. The suite holds
/// what each of them reads: `segments(for:)`, `perform(_:)` and the presentation.
struct FanRowView: View {
    let row: FanRowModel
    /// This fan's per-fan control inputs, read with the rest of the window in `FanListView.body`.
    let control: FanRowControlPresentation.Inputs
    let chooseAutomatic: () -> Void
    let chooseCustom: () -> Void
    /// Return in the field, with what was typed: what the field holds afterwards.
    let submit: (String) -> FanRowControlPresentation.FieldState
    let step:
        (FanRowControlPresentation.StepDirection, FanRowControlPresentation.FieldState) -> Void

    @State private var field = FanRowControlPresentation.FieldState()
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        let presentation = FanRowControlPresentation(control, field: field)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                controlStateLabel
            }
            if let refusal = row.refusal {
                refusalLine(refusal)
            }
            if presentation.drawsControl {
                controlRow(presentation)
            }
            keyedValueRow(label: "Actual", display: row.actual)
            HStack(spacing: 16) {
                keyedValueRow(label: "Min", display: row.minimum)
                keyedValueRow(label: "Max", display: row.maximum)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Per-fan control

    /// What a click on a segment asks for.
    enum SegmentAction: Hashable {
        case automatic, custom
    }

    /// One segment as drawn.
    struct Segment: Equatable, Identifiable {
        let action: SegmentAction
        let mark: FanRowControlPresentation.Mark
        let isEnabled: Bool

        var id: SegmentAction { action }

        /// The segment's label: the maintainer's to settle at the live look (#154's ruling).
        var title: String {
            switch action {
            case .automatic: return "Auto"
            case .custom: return "Custom"
            }
        }

        var help: String {
            switch action {
            case .automatic:
                return "Gives this fan back to automatic control. What it does next is the "
                    + "helper's snapshot to show."
            case .custom:
                return "Holds this fan at a speed you choose, starting from its actual speed. The "
                    + "helper clamps every speed again."
            }
        }
    }

    /// The segments `presentation` draws, in order, Auto then Custom: none when it draws no
    /// control.
    static func segments(for presentation: FanRowControlPresentation) -> [Segment] {
        guard presentation.drawsControl else { return [] }
        return [
            Segment(
                action: .automatic, mark: presentation.automatic.mark,
                isEnabled: presentation.automatic.isEnabled),
            Segment(
                action: .custom, mark: presentation.custom.mark,
                isEnabled: presentation.custom.isEnabled),
        ]
    }

    /// What a click on a segment does: the one place a segment reaches a closure.
    func perform(_ action: SegmentAction) {
        switch action {
        case .automatic: chooseAutomatic()
        case .custom: chooseCustom()
        }
    }

    private func controlRow(_ presentation: FanRowControlPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ForEach(Self.segments(for: presentation)) { segment in
                    button(segment)
                }
                if let shown = presentation.field {
                    targetField(shown)
                }
            }
            .controlSize(.small)
            if let courtesy = presentation.courtesy {
                Text(courtesy)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Selected is drawn prominent; pending is drawn as asked for, with a spinner, never as
    /// achieved.
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
                Button {
                    perform(segment.action)
                } label: {
                    label
                }
                .buttonStyle(.borderedProminent)
                .accessibilityAddTraits(.isSelected)
            } else {
                Button {
                    perform(segment.action)
                } label: {
                    label
                }
                .buttonStyle(.bordered)
                .accessibilityValue(segment.mark == .pending ? "Asked for, not confirmed" : "")
            }
        }
        .disabled(!segment.isEnabled)
        .help(segment.help)
    }

    /// "Target", the field, "RPM", the stepper, and a spinner while the driver's target is
    /// unanswered.
    private func targetField(_ shown: FanRowControlPresentation.Field) -> some View {
        HStack(spacing: 4) {
            Text("Target")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(
                "RPM",
                text: Binding(
                    get: { shown.text },
                    set: { field = field.typed($0) })
            )
            .focused($fieldIsFocused)
            .onSubmit {
                field = submit(shown.text)
                fieldIsFocused = false
            }
            .onChange(of: fieldIsFocused) { focused in
                field = field.focus(focused, showing: shown.text)
            }
            .frame(width: 64)
            .font(.caption.monospacedDigit())
            .accessibilityLabel("Target speed, RPM")
            Text("RPM")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(
                "Target speed",
                onIncrement: shown.canStepUp ? { stepped(.up) } : nil,
                onDecrement: shown.canStepDown ? { stepped(.down) } : nil
            )
            .labelsHidden()
            if shown.isPending {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Asked for, not confirmed")
            }
        }
        .disabled(!shown.isEnabled)
    }

    /// A stepper click commits and ends the edit, so the field shows what the driver asks for.
    private func stepped(_ direction: FanRowControlPresentation.StepDirection) {
        step(direction, field)
        field = .afterStep
        fieldIsFocused = false
    }

    // MARK: - Readings

    /// Reclamation always renders as a visible warning, never folded quietly into the
    /// same styling as a normal automatic/manual state — see `FanRowModel
    /// .controlStateLabel(for:)`'s documentation for why "Reclaimed by system" outranks
    /// whatever the mode reads.
    private var controlStateLabel: some View {
        Group {
            if row.isReclaimedBySystem {
                Label(row.controlStateLabel, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text(row.controlStateLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The reason's own summary, its wire value beside it the way a raw key sits beside a
    /// label, and its recovery advice on hover.
    private func refusalLine(_ refusal: FanRowModel.Refusal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(refusal.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("(\(refusal.wireValue))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .help(refusal.advice)
    }

    private func keyedValueRow(label: String, display: KeyedValueDisplay) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(display.text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(display.isAvailable ? Color.primary : .secondary)
            Text("(\(display.key))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}
