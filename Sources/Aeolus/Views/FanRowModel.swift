import FanKit
import Foundation

/// A pure, testable projection of `FanPollingReading` into what a fan row shows.
///
/// Extracted from the view layer for the same reason as `KeyedValueDisplay`: the
/// decision of how a fan's control state renders — in particular, how reclamation
/// renders — is exactly the kind of logic `CLAUDE.md` rule 6 exists to protect, and it
/// needs to be checkable by a unit test rather than only by eyeballing a running window.
struct FanRowModel: Equatable, Identifiable {
    let id: Int
    let displayName: String
    let actual: KeyedValueDisplay
    let minimum: KeyedValueDisplay
    let maximum: KeyedValueDisplay
    let isReclaimedBySystem: Bool
    /// What a view should say is driving this fan right now.
    ///
    /// Never simply `mode`'s own label: when `isReclaimedBySystem` is `true`, the mode
    /// this reading carries is what was *requested*, not what is currently in effect —
    /// the system has taken the fan back. Presenting that requested mode on its own
    /// would be exactly the failure `CLAUDE.md` rule 6 calls out: "a UI reporting a
    /// target nothing is honouring is worse than one reporting an error." So a reclaimed
    /// fan is always labelled by what is actually true now, with the reclaimed mode
    /// named only for context.
    let controlStateLabel: String

    init(reading: FanPollingReading) {
        id = reading.index
        displayName = reading.displayName
        actual = KeyedValueDisplay(reading: reading.actual, unit: "RPM")
        minimum = KeyedValueDisplay(reading: reading.minimum, unit: "RPM")
        maximum = KeyedValueDisplay(reading: reading.maximum, unit: "RPM")
        isReclaimedBySystem = reading.isReclaimedBySystem
        controlStateLabel = Self.controlStateLabel(
            mode: reading.mode, isReclaimedBySystem: reading.isReclaimedBySystem)
    }

    static func controlStateLabel(mode: FanControlMode, isReclaimedBySystem: Bool) -> String {
        guard isReclaimedBySystem else {
            return modeLabel(for: mode)
        }
        return "Reclaimed by system (was \(modeLabel(for: mode)))"
    }

    private static func modeLabel(for mode: FanControlMode) -> String {
        switch mode {
        case .automatic: return "Automatic"
        case .manualFixed: return "Manual — fixed speed"
        case .manualCurve: return "Manual — curve"
        }
    }
}
