import FanKit
import SwiftUI

/// Renders a catalog confidence level so a `guess` looks like a guess — never rendered
/// with the same visual weight as a `verified` label. `label(for:)`/`tint(for:)` are
/// plain static functions, not view internals, so the mapping from `CatalogConfidence`
/// to what a user sees is unit-testable without instantiating a `View`.
struct ConfidenceBadge: View {
    let confidence: CatalogConfidence

    var body: some View {
        Text(Self.label(for: confidence))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Self.tint(for: confidence).opacity(0.18), in: Capsule())
            .foregroundStyle(Self.tint(for: confidence))
    }

    static func label(for confidence: CatalogConfidence) -> String {
        switch confidence {
        case .verified: return "Verified"
        case .community: return "Community"
        case .guess: return "Guess"
        case .unknown(let raw): return "Unknown (\(raw))"
        }
    }

    static func tint(for confidence: CatalogConfidence) -> Color {
        switch confidence {
        case .verified: return .green
        case .community: return .blue
        case .guess: return .orange
        case .unknown: return .gray
        }
    }
}
