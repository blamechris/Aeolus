/// Which admission class a plane's turns take: § 3's lane, or `.supervisor` — the two the safety
/// path may use, and never the snapshot's.
///
/// ## A view of the one plane, not a second plane
///
/// [ADR 0012](../../docs/ADR/0012-a-round-trip-that-does-not-return-ends-the-helper.md)'s
/// 2026-10-18 amendment gives § 3's cycle its own admission. The way a mechanism reaches it is a
/// **view**: `FanControlPlane.admitted(at:)`, the same plane — the same scheduler, connection and,
/// once B1 builds the write path, the same channel and `PlaneWriteLedger` — whose every turn is
/// admitted at this class. There is one plane, and only what each turn waits for differs.
///
/// That matters because the ledger is what the in-turn properties are decided by: ADR 0014's
/// U15, D4's restore epoch, the exit's seal, #305's re-engagement check and D5's force-key gate
/// are each checked inside a turn, from the plane's own state. A view with state of its own would
/// be a second set of rules; a view that shares it changes nothing those properties see, and the
/// order the lane produces is one first-come first-served admission could have produced under a
/// different arrival timing. `PlaneViewTests` holds the sharing in both conformers.
///
/// ## Two cases, and no `.snapshot`
///
/// A plane is the safety path's seam. A snapshot read never goes through one — it goes through
/// `SMCReadScheduler.snapshotReader` — so a view at snapshot admission would be a safety write
/// waiting behind a client's refresh, and the type cannot say it.
///
/// ## Who names the lane
///
/// Only § 3 uses it: the composition's § 3 wiring builds § 3's telemetry, read-back reader and
/// writer over `admitted(at: .thermalCycle)`, and `HelperFanRestorer` routes the restores caused by
/// `FanRestoreCause.thermalEmergency` through its lane view. `ThermalCycleLaneTripwireTests` holds
/// both lists.
enum PlaneAdmission: Sendable, Hashable {

    /// § 3's own cycle (`SMCReadPriority.thermalCycle`).
    case thermalCycle

    /// Every other safety mechanism (`SMCReadPriority.supervisor`). A plane is built here.
    case supervisor

    /// The scheduler's priority for a turn taken at this admission.
    var priority: SMCReadPriority {
        switch self {
        case .thermalCycle: return .thermalCycle
        case .supervisor: return .supervisor
        }
    }
}
