import AeolusXPCClient
import Foundation

/// What the fan pane says, once and above its rows, about where its control facts come from.
///
/// The rows say "Automatic" or "Mode not tracked"; this line says whose word that is. A helper
/// snapshot's facts are **the helper's report**, never a statement that the fan is so — FanKit's
/// `isClearedToAutomatic` is explicit that a client renders "the helper reports". A direct read's
/// line says why nothing is tracked.
///
/// It never says the machine is in its safe state. "Every fan on automatic" needs every fan
/// cleared **and** no lease listed, as `fanctl`'s `SafeState.verdict` checks, and that banner
/// is #157's (`MonitoringModeDisplay`), not this.
enum ControlSourceDisplay {

    struct Text: Equatable {
        let headline: String
        let detail: String?
    }

    static func text(for source: ControlSource) -> Text {
        switch source {
        case .helperSnapshot(let lease):
            guard let lease else {
                return Text(headline: "Fan control state as the helper reports it.", detail: nil)
            }
            return Text(
                headline: "Fan control state as the helper reports it.",
                detail:
                    "Manual-control lease held by “"
                    + HelperAuthoredText.sanitised(lease.holderDescription) + "”.")
        case .notTracked(let why):
            return Text(headline: "Mode not tracked.", detail: explanation(why))
        }
    }

    /// Why nothing is tracked, in one sentence.
    ///
    /// The two cases with no helper client reuse `HelperStatusDisplay`'s titles, so the pane and
    /// the footer name the same condition the same way; the footer carries the full account.
    /// Both broken-install defects share one title there, "This copy of Aeolus is damaged", and
    /// `ControlSourceDisplayTests` holds that they still do.
    static func explanation(_ why: ControlNotTracked) -> String {
        switch why {
        case .nothingReadYet:
            return "Nothing has been read yet."
        case .noHelperInThisBuild:
            return HelperStatusDisplay.text(for: .unavailableInThisBuild).title + "."
        case .helperInstallIncomplete:
            return HelperStatusDisplay.text(for: .brokenInstall(.helperExecutableMissing)).title
                + ", so it does not talk to its helper."
        case .helperConnection(let health):
            return explanation(health)
        case .awaitingSnapshot:
            return "Waiting for the helper's first snapshot."
        case .snapshotRequestFailed(let detail):
            return "The last snapshot request failed: \(detail)"
        case .snapshotContradicted(let detail):
            return "The helper's last snapshot contradicted itself (\(detail)), so it is not shown."
        case .snapshotStale:
            return "The helper's last snapshot is too old to show as current."
        }
    }

    /// One sentence per connection state, after `HelperConnectionHealth`'s own account of
    /// each. `.invalidated` names no single cause, because ADR 0005 measured that an absent
    /// helper, an unapproved one and a silent signature refusal look the same from here.
    private static func explanation(_ health: HelperConnectionHealth) -> String {
        switch health {
        case .idle:
            return "Aeolus has not connected to its helper yet."
        case .handshaken:
            // Never produced with this value: `HelperSnapshotSource` reports the connection
            // only when it is not handshaken. Written out anyway, truthfully.
            return "Aeolus is connected to its helper and has no current snapshot from it."
        case .unresponsive:
            return "The helper stopped answering."
        case .interrupted:
            return "The helper process went away."
        case .invalidated:
            return "Aeolus cannot reach its helper: it may not be installed or approved yet, "
                + "or it refused this copy of Aeolus."
        case .refused:
            return "Aeolus and its helper would not agree to talk."
        case .versionMismatched:
            return "This copy of Aeolus and its helper speak different protocol versions."
        }
    }
}
