import SwiftUI

/// One sensor's row in `SensorListView`'s table: raw key, catalog label (if any), a
/// visible confidence badge, and the current value.
struct SensorRowView: View {
    let row: SensorRowModel

    var body: some View {
        HStack(spacing: 12) {
            // The raw key is always shown, and never replaced by the label — see
            // `CLAUDE.md`: "a wrong label must never be able to quietly mislead someone
            // into driving a fan from the wrong sensor."
            Text(row.key)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 48, alignment: .leading)

            labelColumn
                .frame(minWidth: 120, alignment: .leading)

            Text(row.value.text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(row.value.isAvailable ? Color.primary : .secondary)
                .frame(minWidth: 90, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var labelColumn: some View {
        HStack(spacing: 6) {
            Text(row.label ?? "Unlabelled")
                .foregroundStyle(row.label == nil ? Color.secondary : .primary)
            if let confidence = row.confidence {
                ConfidenceBadge(confidence: confidence)
            }
        }
    }
}
