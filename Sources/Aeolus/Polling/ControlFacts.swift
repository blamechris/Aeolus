import AeolusXPCClient
import FanKit

// Where the app's control facts come from, and what it says when there are none.
//
// ADR 0006's invariant is the whole of this file: a **control claim** — mode, target, lease,
// reclamation, availability, thermal emergency — may be rendered only from a helper snapshot
// within its staleness bound, and every other source renders the claim as **unknown**, "never
// as last-known helper state, and never as a synthesised safe value". Before #156 the app
// pinned every fan's mode to `.automatic` and the emergency flag to `false` on its direct-read
// path, which is the synthesised safe value the ADR forbids, recorded as a latent defect in its
// own text. These types replace those literals with the two answers that are true: the
// helper's report, or "not tracked" and why.

/// The control facts about one fan: the helper's report of it, or the reason there is none.
///
/// There is deliberately no third case and no default. A fan read directly from the SMC by
/// this unprivileged app carries `.notTracked`, because nothing the app reads itself says who
/// is driving the fan: `F<n>Md` is unread here, and even read it would not say whether a lease,
/// another program or the firmware put the fan there.
public enum FanControlSource: Sendable, Hashable {
    /// No current helper snapshot speaks for this fan. Every control claim is unknown.
    case notTracked(ControlNotTracked)
    /// The helper's own report, from a snapshot within its freshness bound
    /// (`HelperSnapshotSource`). Carried whole, so a renderer judges it with FanKit's shared
    /// predicates (`FanState.isClearedToAutomatic`) rather than a second reading of `mode`.
    ///
    /// `thermalEmergency` is the same snapshot's `isThermalEmergencyActive`, carried beside
    /// each fan so a row can say what is true of it: the flag is set and the fan reads manual.
    /// It says nothing about who is driving the fan. `docs/SAFETY.md` § 3 acts only on fans
    /// Aeolus itself took off automatic control, never on one another program holds, and on a
    /// helper that cannot write it has taken none.
    case reported(FanState, thermalEmergency: Bool)

    /// Whether the helper reports this fan reclaimed by the system.
    ///
    /// `false` for `.notTracked` means **nothing reports it**, not that it is known not to
    /// have happened — which is why this is named for the report rather than for the fan. It
    /// exists for the two places that raise a warning when a reclamation is reported, and must
    /// not be read as "this fan is under control".
    public var reportsReclamation: Bool {
        guard case .reported(let state, _) = self else { return false }
        return state.isReclaimedBySystem
    }
}

/// Where the app's control facts come from right now, for the whole machine.
///
/// The per-fan `FanControlSource` says the same thing fan by fan. This one also carries what
/// only the machine has: the lease the snapshot lists.
public enum ControlSource: Sendable, Hashable {
    /// A helper snapshot within its freshness bound. `activeLease` is the snapshot's own, and
    /// its `holderDescription` is **another client's free text**: render it only through
    /// `HelperAuthoredText.sanitised(_:)`.
    case helperSnapshot(activeLease: Lease?)
    /// Direct SMC reads, or nothing yet. Every control claim is unknown.
    case notTracked(ControlNotTracked)
}

/// Why the app cannot say anything about control right now.
///
/// Every case is a statement about the app's view of the helper, never about the fans. None of
/// them is "the fans are automatic", and none may be rendered as though it were.
public enum ControlNotTracked: Sendable, Hashable {
    /// Nothing has been read yet. The value a view model starts with, before its first tick.
    case nothingReadYet
    /// This build ships no helper: the `Monitor` configuration (`HelperEmbedding.absent`).
    /// No helper client exists in this process at all.
    case noHelperInThisBuild
    /// The bundle has one half of a helper and not the other (`HelperEmbedding.incomplete`).
    /// No helper client is built for a damaged bundle either.
    case helperInstallIncomplete
    /// A helper client exists and its connection is not `.handshaken`: ADR 0006's switch.
    /// Never carries `.handshaken`; `HelperSnapshotSource` only produces it for the others.
    case helperConnection(HelperConnectionHealth)
    /// Handshaken, and nothing has answered yet in this handshaken episode. A snapshot from an
    /// earlier episode — before the helper process was replaced, or the connection dropped —
    /// does not count.
    case awaitingSnapshot
    /// The most recent snapshot request failed. `detail` has already been through
    /// `HelperAuthoredText.sanitised(_:)`, because an `AeolusXPCFault` can carry the helper's
    /// words.
    case snapshotRequestFailed(detail: String)
    /// The most recent snapshot arrived and contradicted itself — it names one fan, or one
    /// sensor key, twice — so the app refused it. Not a failed request: the helper answered.
    /// `detail` says what was named twice, with any helper text in it already cleaned.
    case snapshotContradicted(detail: String)
    /// Handshaken, and the snapshot this episode has is older than its freshness bound allows
    /// (`HelperSnapshotSource.freshnessBound`): the next answer is due.
    case snapshotStale
}

/// Whether the helper reports a thermal emergency: on, off, or unknown.
///
/// Three cases because there are three answers, and the third is the one the app gave wrongly
/// before #156 — `false`, hardcoded, on a path that had asked nobody. `.unknown` is what every
/// source but a fresh snapshot produces.
///
/// **Read from `SystemSnapshot.isThermalEmergencyActive` alone**, never inferred from a lease
/// being listed or from `controlLoss`: `docs/SAFETY.md` § 3 revokes every lease when it fires,
/// so a snapshot taken during an emergency usually lists no lease at all. And the flag clears
/// once § 3's latch releases (#476 NB3), so `.inactive` says only that this snapshot reports no
/// emergency now — never why a lease that has gone ended.
public enum ThermalEmergencyState: Sendable, Hashable {
    /// The snapshot reports `isThermalEmergencyActive`.
    case active
    /// The snapshot reports no thermal emergency.
    case inactive
    /// No current helper snapshot says either way.
    case unknown
}
