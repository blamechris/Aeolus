import Foundation

/// Which fans level 6 holds under which lease, and on what account: the authority for "this lease
/// has engaged the fan", as a value (ADR 0014's A6 PR-2 and #410 refused-hand-back amendments).
///
/// Keyed by lease. A fan is `.engaged` when the driver's engagement returns under that lease, or a
/// kept fan is read as still the lease's; it is `.handBackRefused` when level 6's undo or the
/// driver's own was refused, so it may still be off automatic control. It leaves when a hand-back
/// returns or § 5 answers its report `.notHeld`. Either account under a lease drops every other
/// lease's fans: one live lease covers a fan at a time, so a lease that engages or keeps has
/// outlived every other. Dropped when `apply` is authorised instead, a call whose lease ended
/// between `heldLease` answering and its resumption would erase the account of the lease granted
/// since, whose next re-apply would then be refused `.notAutomatic` about its own fans; a call
/// under an ended lease cannot engage, because its driver's entitlement refuses it. A fan a
/// teardown, § 3 or § 5 handed back under a lease that is still live stays here: #381's one-cycle
/// residual.
struct LeaseEngagements: Sendable {

    /// What level 6 holds of one fan under one lease.
    enum Account: Sendable, Hashable {
        /// The driver's engagement returned, or a kept fan was read as still this lease's. Its
        /// re-apply registers and commands it without the driver.
        case engaged
        /// Level 6's undo, or the driver's own, was refused: the fan may still be off automatic
        /// control. Its re-apply runs the driver, whose first step reads where the fan is.
        case handBackRefused
    }

    private var fans: [UUID: [Int: Account]] = [:]

    /// `index`'s account under `lease`, or `nil` when it has none there.
    func account(of index: Int, under lease: UUID) -> Account? {
        fans[lease]?[index]
    }

    /// The leases with a fan on account, for tests.
    var leases: Set<UUID> { Set(fans.keys) }

    /// An engagement of `index` under `lease` returned, or a kept fan was read as still its own.
    mutating func insert(_ index: Int, under lease: UUID) {
        open(.engaged, for: index, under: lease)
    }

    /// `insert(_:under:)`, by one `apply`, which `index` joins as a fan its undo hands back.
    mutating func insert(_ index: Int, under lease: UUID, into fans: inout ApplyEngagements) {
        insert(index, under: lease)
        fans.engaged.append(index)
    }

    /// A hand-back of `index` under `lease` was refused: level 6's undo, or the driver's.
    mutating func keep(_ index: Int, under lease: UUID) {
        open(.handBackRefused, for: index, under: lease)
    }

    /// `index` was handed back under `lease`, or § 5 no longer holds it there.
    mutating func remove(_ index: Int, under lease: UUID) {
        fans[lease]?[index] = nil
        if fans[lease]?.isEmpty == true { fans[lease] = nil }
    }

    private mutating func open(_ account: Account, for index: Int, under lease: UUID) {
        fans = fans.filter { $0.key == lease }
        fans[lease, default: [:]][index] = account
    }
}

// MARK: - A refusal of the driver's, read by the account

extension LeaseEngagements {

    /// What level 6's step makes of its driver's refusal to engage `index` under `lease`, a fan it
    /// holds no `.engaged` account of (ADR 0014's #410 refused-hand-back amendment). Returns when
    /// the refusal is the engagement returning, so the step holds the fan as engaged; otherwise
    /// throws what the step is answered by. Synchronous, so the account is read and changed in the
    /// step's own turn.
    ///
    /// - **A refused undo** (`EngagementUndoRefused`, #406): the fan may still be off automatic
    ///   control. It is kept, named in `fans` for the refusal's notice, and the cause is thrown.
    /// - **A kept fan still holding the value the engagement wrote:** `.notAutomatic` with
    ///   `EngagementRules.isEngagedMode`, on a `.handBackRefused` account. Its restore never
    ///   landed, so it is still this lease's, and nothing was written. Said at `.notice`.
    /// - **Anything else** is thrown as it is. A `.notAutomatic` with any other value, or on a fan
    ///   with no account, is someone else's fan: `foreignManualControl`.
    mutating func read(
        _ refusal: any Error, of index: Int, under lease: UUID, into fans: inout ApplyEngagements,
        log: SafetyLog
    ) throws {
        if let undo = refusal as? EngagementUndoRefused {
            keep(index, under: lease)
            fans.keptByTheDriver.append(index)
            throw undo.cause
        }
        guard account(of: index, under: lease) == .handBackRefused,
            case .notAutomatic(_, let raw)? = refusal as? FanControlPlaneError,
            EngagementRules.isEngagedMode(raw)
        else { throw refusal }
        log.controlLoopKeptFanReAdopted(fan: index, rawMode: raw)
    }
}

/// One `apply`'s share of level 6's account: the fans whose engagement returned in it, in the
/// order it engaged them, which its undo hands back; and the one the driver could not hand back
/// itself (#406), which the refusal's notice names beside the undo's own.
struct ApplyEngagements: Sendable {
    var engaged: [Int] = []
    var keptByTheDriver: [Int] = []
}
