import SwiftUI

/// Rendered only when `PollingViewModel.isThermalEmergencyActive` reports `true`.
///
/// That flag is hardcoded `false` under `Monitor` today — see its documentation on
/// `PollingViewModel` for why — but the rendering path exists now regardless, so a real
/// helper-reported emergency does not require the first-ever UI change to surface it
/// honestly. Never gated behind a setting: `CLAUDE.md` requires this state, when
/// reported, always render.
struct ThermalEmergencyBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Thermal emergency — the system has taken control of every fan.")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(8)
        .background(Color.red.opacity(0.85))
        .foregroundStyle(.white)
    }
}
