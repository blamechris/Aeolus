import SwiftUI

/// The main window's monitoring-mode line, beside the control for all fans:
/// `MonitoringModeDisplay`'s banner, drawn, and nothing else (#157).
///
/// It decides nothing. Every string it draws is a field of the banner, so what it says is the
/// formatter's, which the suite pins state by state; `FanListView`'s body is walked to show it
/// draws the formatter's answer for what is on screen. No banner draws nothing: the caller passes
/// none.
///
/// **Main window only, not the menu bar panel.** The panel has no control (`FanListView`'s
/// documentation: the control is the main window's alone), so "as you chose" would refer to a
/// choice made somewhere else, and the panel already raises a reclamation in its icon and against
/// the fan it names.
struct MonitoringModeBanner: View {
    let banner: MonitoringModeDisplay.Banner

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch banner.severity {
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
            case .normal:
                Image(systemName: "eye")
                    .foregroundStyle(Color.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.headline)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = banner.detail {
                    Text(detail)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(banner.reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(reason.text)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("(\(reason.wireValue))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }
}
