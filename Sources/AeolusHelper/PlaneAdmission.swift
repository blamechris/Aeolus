/// Which admission class a plane's turns take: § 3's lane, or `.supervisor` — the two the safety
/// path may use, and never the snapshot's.
///
/// ## A view of the one plane, not a second plane
///
/// [ADR 0012](../../docs/ADR/0012-a-round-trip-that-does-not-return-ends-the-helper.md)'s
/// 2026-10-18 amendment gives § 3's cycle its own admission. The way a mechanism reaches it is a
/// **view**: `FanControlPlane.admitted(at:)`, the same plane — the same scheduler, connection and,
/// on a plane that can write, the same channel and `PlaneWriteLedger` — whose every turn is
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
/// Only § 3 uses it, and it is reached by holding a view of it — never by a value a request
/// carries (ADR 0012's #440 amendment). The composition's § 3 wiring builds § 3's telemetry,
/// read-back reader and writer over `admitted(at: .thermalCycle)`, and `ThermalCycleHandback`
/// admits its writer there: the restorer § 3 holds, and lends to the lease core for its revocation
/// alone. Nothing else mints a view, and the lease core and the restorer name no admission at all
/// (`ThermalCycleHandbackTripwireTests`). `ThermalCycleLaneTripwireTests` counts the lane's word
/// file by file, `ThermalCycleLaneWriterTests` holds every stored plane's admission at rest and
/// after a firing, and `SMCReadScheduler` reports at run time a lane request that arrives while
/// another is outstanding.
///
/// **The two cases are pinned.** A third case mapped to the lane's priority would reach the lane
/// without naming it, from any file and at any call site, so `ThermalCycleLaneValueSetTests`
/// switches over this enum exhaustively, with no `default`: a new case does not compile until the
/// pin says where it maps, and the pin holds that only `.thermalCycle` maps to the lane.
/// `CaseIterable` is for that test; nothing in `Sources` enumerates the cases.
enum PlaneAdmission: Sendable, Hashable, CaseIterable {

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
