import FanKit
import Foundation

/// A pure, testable projection of `FanPollingReading` into what a fan row shows.
///
/// Extracted from the view layer for the same reason as `KeyedValueDisplay`: the
/// decision of how a fan's control state renders — in particular, how reclamation and
/// refusal render — is exactly the kind of logic `CLAUDE.md` rule 6 exists to protect, and it
/// needs to be checkable by a unit test rather than only by eyeballing a running window.
struct FanRowModel: Equatable, Identifiable {
    let id: Int
    let displayName: String
    let actual: KeyedValueDisplay
    let minimum: KeyedValueDisplay
    let maximum: KeyedValueDisplay
    /// Whether the helper reports this fan reclaimed by the system. Drawn as a warning.
    let isReclaimedBySystem: Bool
    /// What a view should say is driving this fan right now — see
    /// `controlStateLabel(for:)`.
    let controlStateLabel: String
    /// Why the helper refuses manual control of this fan, in the reason's own words, or `nil`
    /// when it does not refuse or nothing reports either way.
    let refusal: Refusal?

    /// A refusal, in the words `ManualControlAvailability.Reason` already carries: its
    /// `userFacingSummary` and `recoveryAdvice`, unchanged. Not new copy, so the app and
    /// `fanctl status` cannot describe one reason two ways.
    struct Refusal: Equatable {
        let summary: String
        let advice: String
        /// The reason's wire value, shown beside the prose the way a raw key is shown beside a
        /// label — it is what `docs/RECOVERY.md` is indexed by. Cleaned, because an `unknown`
        /// reason's wire value is the helper's free text.
        let wireValue: String
    }

    init(reading: FanPollingReading) {
        id = reading.index
        displayName = reading.displayName
        actual = KeyedValueDisplay(reading: reading.actual, unit: "RPM")
        minimum = KeyedValueDisplay(reading: reading.minimum, unit: "RPM")
        maximum = KeyedValueDisplay(reading: reading.maximum, unit: "RPM")
        isReclaimedBySystem = reading.control.reportsReclamation
        controlStateLabel = Self.controlStateLabel(for: reading.control)
        refusal = Self.refusal(for: reading.control)
    }

    /// The label for a fan's control state.
    ///
    /// - **Not tracked:** "Mode not tracked". A direct read says nothing about who drives the
    ///   fan, and the old path's hardcoded "Automatic" is the claim ADR 0006 records as a
    ///   defect.
    /// - **Reclaimed:** "Reclaimed by system", whatever the mode reads. The system has taken the
    ///   fan back; nothing Aeolus asked for is in effect.
    /// - **"Automatic" only when `FanState.isClearedToAutomatic` holds.** The helper reports an
    ///   unreadable `F<n>Md` as `automatic` (#178), so `mode == .automatic` beside a pending or
    ///   durable availability — a restore not yet confirmed, a blind supervisor, a fan another
    ///   program holds — is not a fan cleared to automatic, and it says "Not confirmed as
    ///   automatic" instead. On a helper that cannot write, an unread mode arrives beside
    ///   `writePathNotBuilt`, which is silent, so it still reads "Automatic" — #178's gap; this
    ///   row cannot close it until the wire can say a mode is unknown.
    /// - **A fan that reads manual while the emergency flag is set** says exactly that — "Manual
    ///   during a thermal emergency" — rather than "Manual — fixed speed", which is the label a
    ///   user's own setting gets and would read as their choice. It claims nothing about who is
    ///   driving the fan: `docs/SAFETY.md` § 3 acts only on fans in its own registers, which are
    ///   fans Aeolus took off automatic control. It is never told about a fan the grant path
    ///   reports `.foreignManualControl`, and on a helper that cannot write, it has registered
    ///   none.
    /// - Otherwise the mode the helper reports.
    ///
    /// Everything but the first is the helper's report, and the fan pane says so once, above
    /// the rows (`ControlSourceDisplay`).
    static func controlStateLabel(for control: FanControlSource) -> String {
        guard case .reported(let state, let thermalEmergency) = control else {
            return "Mode not tracked"
        }
        if state.isReclaimedBySystem { return "Reclaimed by system" }
        if state.isClearedToAutomatic { return "Automatic" }
        if thermalEmergency, state.mode != .automatic { return "Manual during a thermal emergency" }
        switch state.mode {
        case .automatic: return "Not confirmed as automatic"
        case .manualFixed: return "Manual — fixed speed"
        case .manualCurve: return "Manual — curve"
        }
    }

    private static func refusal(for control: FanControlSource) -> Refusal? {
        guard case .reported(let state, _) = control,
            case .unavailable(let reason) = state.manualControlAvailability
        else { return nil }
        return Refusal(
            summary: reason.userFacingSummary,
            advice: reason.recoveryAdvice,
            wireValue: HelperAuthoredText.sanitised(reason.wireValue))
    }
}
