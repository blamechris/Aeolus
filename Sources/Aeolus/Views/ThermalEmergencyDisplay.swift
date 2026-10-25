import Foundation

/// What the app says about a thermal emergency, for each of the three answers it can have.
///
/// Pure, so the rule that the three render **distinctly** is a unit test rather than a look at
/// a window: an emergency is a red banner; no emergency is no banner; and *unknown* is its own
/// quiet line, never folded into either. Folding unknown into "no banner" is how a process
/// that had asked nobody used to tell the user there was no emergency.
///
/// **Unknown says why**, from the same reason the fan pane gives (`ControlSourceDisplay`): a
/// `Monitor` build cannot see an emergency at all, which is a different thing to know from a
/// helper that has stopped answering.
///
/// **The copy names the emergency only while the flag is set**, says only what the helper does
/// while it is — grant no new manual-control lease — and infers nothing from a lease and says
/// nothing about protecting any particular fan. `docs/SAFETY.md` § 3 acts only on fans in its own
/// registers, which are fans Aeolus took off automatic control. It is never told about a fan the
/// grant path reports `.foreignManualControl`, and on a helper that cannot write, it has
/// registered none. § 3 revokes every lease when it fires, and its flag clears once the latch
/// releases (#476 NB3), so a banner that inferred a cause from a lease that had gone would be
/// guessing.
///
/// **"No new lease", not "no manual control" (#485 S3).** `ThermalEmergency.fire()` engages the
/// latch first, then bridges the fans in its registers to maximum and back, and revokes every
/// live lease last; § 3's opening in `docs/SAFETY.md` gives the same order for the last three.
/// `LeaseAuthority.acquireLease` refuses while the latch holds, and `renewLease` does not consult
/// it. So a snapshot can carry the flag beside a lease it still lists — the window
/// `SystemSnapshot.controlLoss(leaseID:covering:)` names — and "grants no manual control" would
/// sit beside "Manual-control lease held by …". On a helper that cannot write, that window holds
/// no lease, because none is granted; the sentence is for the helper that can.
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
            "Thermal emergency reported by the helper — it grants no new manual-control lease "
            + "while this lasts.",
        compactText: "Thermal emergency active")

    /// The unknown line, with the reason nothing is tracked.
    static func unknown(because why: ControlNotTracked?) -> Banner {
        let text: String
        switch why {
        case .noHelperInThisBuild:
            text =
                "Thermal emergency: unknown — this build ships no privileged helper, so it cannot "
                + "see one."
        case .some(let why):
            text = "Thermal emergency: unknown. " + ControlSourceDisplay.explanation(why)
        case nil:
            text = "Thermal emergency: unknown — no current helper snapshot reports either way."
        }
        return Banner(severity: .unknown, text: text, compactText: "Thermal emergency: unknown")
    }

    /// The banner for `state`, or `nil` when the helper reports no emergency. `source` is where
    /// the control facts came from; when they are not tracked, its reason is the unknown line's.
    static func banner(for state: ThermalEmergencyState, source: ControlSource) -> Banner? {
        switch state {
        case .active:
            return emergency
        case .inactive:
            return nil
        case .unknown:
            guard case .notTracked(let why) = source else { return unknown(because: nil) }
            return unknown(because: why)
        }
    }
}
