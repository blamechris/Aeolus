import Foundation

/// What the app says about a thermal emergency, for each of the three answers it can have.
///
/// Pure, so the rule that the three render **distinctly** is a unit test rather than a look at
/// a window: an emergency is a red banner; no emergency is no banner; and *unknown* is its own
/// quiet line, never folded into either. Folding unknown into "no banner" is how a process
/// that had asked nobody used to tell the user there was no emergency.
///
/// **The copy names the emergency only while the flag is set**, and says nothing about leases.
/// § 3 revokes every lease when it fires, and its flag clears once the latch releases (#476
/// NB3), so a banner that inferred a cause from a lease that had gone would be guessing.
enum ThermalEmergencyDisplay {

    enum Severity: Equatable {
        /// The helper reports an emergency. Never gated behind a setting.
        case emergency
        /// Nothing current says either way.
        case unknown
    }

    struct Banner: Equatable {
        let severity: Severity
        /// For the main window.
        let text: String
        /// For the menu bar dropdown, which has the width for a few words.
        let compactText: String
    }

    static let emergency = Banner(
        severity: .emergency,
        text:
            "Thermal emergency reported by the helper — its thermal protection outranks manual "
            + "control of every fan.",
        compactText: "Thermal emergency active")

    static let unknown = Banner(
        severity: .unknown,
        text: "Thermal emergency: unknown — no current helper snapshot reports either way.",
        compactText: "Thermal emergency: unknown")

    /// The banner for `state`, or `nil` when the helper reports no emergency.
    static func banner(for state: ThermalEmergencyState) -> Banner? {
        switch state {
        case .active: return emergency
        case .inactive: return nil
        case .unknown: return unknown
        }
    }
}
