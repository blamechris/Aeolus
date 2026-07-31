import SwiftUI

/// A thin, per-pane freshness line: renders `PollingStatusDisplay.Text` — see that type
/// for how the message itself is chosen.
struct PollingStatusBanner: View {
    let status: PollingStatusDisplay.Text

    var body: some View {
        HStack(spacing: 6) {
            if status.severity == .warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(status.message)
                .font(.caption)
                .foregroundStyle(status.severity == .warning ? Color.orange : .secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}
