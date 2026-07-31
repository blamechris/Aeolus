import SwiftUI

/// One fan's row in `FanListView`: name, control state, and the actual/minimum/maximum
/// RPM readings — each with its raw SMC key shown alongside it, per `CLAUDE.md`.
///
/// Read-only. No slider, no target-speed field, no curve control — see issue #62's
/// "no control affordance" constraint.
struct FanRowView: View {
    let row: FanRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                controlStateLabel
            }
            keyedValueRow(label: "Actual", display: row.actual)
            HStack(spacing: 16) {
                keyedValueRow(label: "Min", display: row.minimum)
                keyedValueRow(label: "Max", display: row.maximum)
            }
        }
        .padding(.vertical, 4)
    }

    /// Reclamation always renders as a visible warning, never folded quietly into the
    /// same styling as a normal automatic/manual state — see `FanRowModel
    /// .controlStateLabel`'s documentation for why the label text itself already says
    /// what was reclaimed.
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
