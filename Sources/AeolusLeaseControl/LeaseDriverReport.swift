import Foundation

/// The driver's state, and which snapshots may show a fan automatic beside it: one value, published
/// whole by `LeaseDriver.reportUpdates()` (ADR 0015 D2).
///
/// ## Why the evidence travels with the state
///
/// Automatic's evidence is an absence: no lease listed, the fan cleared. That looks the same in a
/// snapshot read before a grant and in one read after a release, so only the read's timing tells
/// them apart. The driver mints that timing, and a state published apart from it could be paired
/// with an older one: `released` beside the floor of an earlier release, which a snapshot read
/// before this release passes. So both are one stream element, and a renderer that has the state
/// has the evidence the driver published with it.
///
/// ## What it does not say
///
/// It says which reads may be evidence, never what the fans are doing. A read it admits is still
/// judged on what it shows: that it lists no lease and reports the fan cleared
/// (`SystemSnapshot.showsAutomatic(_:)`), and the renderer still requires the driver to be holding
/// nothing and not acquiring or releasing (ADR 0015 D1's condition 1).
///
/// Only the driver makes a report with a minted floor: the synthesized initializer is `internal`,
/// and a `SnapshotTicket` can only be minted in `LeaseDriver.swift`.
public struct LeaseDriverReport: Sendable, Hashable {

    /// Where the lease stands.
    public let state: LeaseDriverState

    /// Which reads' snapshots may show a fan automatic.
    public let automaticEvidence: AutomaticEvidence

    /// What a driver that has done nothing reports: `idle`, and any read. The memberwise
    /// initializer is `internal`, so outside this module this is the only report not the driver's.
    public static let idle = LeaseDriverReport(state: .idle, automaticEvidence: .anyRead)

    /// Which reads may be evidence that a fan is automatic.
    ///
    /// Set only when the driver enters `released`, `lost` or `refused`, the states in which it has
    /// stopped acting, and kept through every other state, where the renderer claims no Automatic
    /// whatever this says. So it is "since the driver last stopped acting", ADR 0015 D1's
    /// condition 2.
    public enum AutomaticEvidence: Sendable, Hashable {

        /// The driver has never acted (`idle`): any licensed snapshot may be evidence. D1's "idle
        /// sets no floor". A new process starts here, whatever an earlier one held.
        case anyRead

        /// Only a snapshot whose read was ticketed with this ticket or a later one: read after the
        /// driver last stopped acting with no `apply` unanswered.
        case readFrom(LeaseDriver.SnapshotTicket)

        /// No snapshot yet: the driver stopped acting while an `apply` it sent was still
        /// unanswered, and no read is evidence until that `apply` has answered, when this becomes
        /// `readFrom` a ticket minted then (#498's S2). Such an `apply` can still land a target
        /// write after the release's restore, on a fan already automatic. ADR 0014 calls that
        /// reported harmless on Apple Silicon and untested on Intel: a hardware claim nobody has
        /// observed, so a read the helper may have served before that write is not evidence.
        case noRead

        /// Whether a snapshot whose read was ticketed `ticket` may be evidence. `nil` is a read the
        /// driver gave no ticket to, which only `anyRead` admits.
        public func admits(_ ticket: LeaseDriver.SnapshotTicket?) -> Bool {
            switch self {
            case .anyRead:
                return true
            case .readFrom(let floor):
                guard let ticket else { return false }
                return ticket >= floor
            case .noRead:
                return false
            }
        }
    }
}
