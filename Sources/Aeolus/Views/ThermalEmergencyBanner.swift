import SwiftUI

/// The window's thermal emergency line: `ThermalEmergencyDisplay`'s banner, drawn.
///
/// An emergency is the red bar, rendered whenever the helper's snapshot sets
/// `isThermalEmergencyActive` and never gated behind a setting. *Unknown* is a quiet line of
/// its own, so it can never be mistaken for either "no emergency" or an emergency. No
/// emergency draws nothing — the caller passes no banner.
struct ThermalEmergencyBanner: View {
    let banner: ThermalEmergencyDisplay.Banner

    var body: some View {
        switch banner.severity {
        case .emergency:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(banner.text)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(8)
            .background(Color.red.opacity(0.85))
            .foregroundStyle(.white)
        case .unknown:
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                Text(banner.text)
                    .font(.caption)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }
}
