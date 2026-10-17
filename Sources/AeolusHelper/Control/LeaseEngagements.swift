import Foundation

/// Which fans level 6 holds under which lease, and on what account: the authority for "this lease
/// has engaged the fan", as a value (ADR 0014's A6 PR-2 and #410 refused-hand-back amendments).
///
/// Keyed by lease. A fan is `.engaged` when the driver's engagement returns under that lease, or a
/// kept fan is re-adopted. It is `.handBackRefused` when level 6's undo, or the driver's undo of an
/// engagement that issued a write, was refused, so it may still be off automatic control. It leaves
/// when level 6's hand-back returns, when § 5 answers its report `.notHeld`, and when `read` ends
/// it. Either account under a lease drops every other lease's fans: one live lease covers a fan at
/// a time, so a lease that engages or keeps has outlived every other. Dropped when `apply` is
/// authorised instead, a call whose lease ended between `heldLease` answering and its resumption
/// would erase the account of the lease granted since, whose next re-apply would then be refused
/// `.notAutomatic` about its own fans; a call under an ended lease cannot engage, because its
/// driver's entitlement refuses it. A fan a teardown, § 3 or § 5 handed back under a lease that is
/// still live stays here: #381's one-cycle residual.
///
/// **While its lease is live, every `.handBackRefused` fan is in § 3's registry.** Both routes that
/// open the account leave it registered, because the driver registers before any undo and a refused
/// restore tells § 3 nothing. Every route by which § 3 forgets a fan ends the account (a hand-back
/// of level 6's or the driver's that returns) or every lease (a lease teardown, § 3's own bridge,
/// § 4, § 6, § 7). A re-adoption registers the fan with § 3 again all the same, so the bridge does
/// not rest on this.
struct LeaseEngagements: Sendable {

    /// What level 6 holds of one fan under one lease.
    enum Account: Sendable, Hashable {
        /// The driver's engagement returned, or a kept fan was re-adopted. Its re-apply registers
        /// and commands it without the driver.
        case engaged
        /// Level 6's undo, or the driver's undo of an engagement that issued a write, was refused:
        /// the fan may still be off automatic control. Its re-apply runs the driver, whose first
        /// step reads where the fan is.
        case handBackRefused
    }

    private var fans: [UUID: [Int: Account]] = [:]

    /// `index`'s account under `lease`, or `nil` when it has none there.
    func account(of index: Int, under lease: UUID) -> Account? {
        fans[lease]?[index]
    }

    /// The leases with a fan on account, for tests.
    var leases: Set<UUID> { Set(fans.keys) }

    /// An engagement of `index` under `lease` returned, or a kept fan was re-adopted.
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

    /// `index` was handed back under `lease`, § 5 no longer holds it there, or `read` ended it.
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
    /// holds no `.engaged` account of (ADR 0014's #410 refused-hand-back amendment). Returns only
    /// for a re-adoption, after which the step registers the fan with § 3 and holds it as engaged;
    /// otherwise throws `refusal` as it came, and `LeaseApplier.refusal(for:)` answers it by its
    /// cause. Synchronous, so the account is read and changed in the step's own turn.
    ///
    /// - **A refused undo** (`EngagementUndoRefused`, #406): the engagement issued a write, so the
    ///   fan may still be off automatic control. It is kept, and named in `fans` for the refusal's
    ///   notice.
    /// - On a `.handBackRefused` account, and no other:
    ///   - **`.notAutomatic` with `EngagementRules.isEngagedMode`:** the fan reads the value an
    ///     engagement writes, and is re-adopted with nothing written. The value cannot say whose
    ///     write it was, so the notice says only what was read.
    ///   - **`.notAutomatic` with any other value:** someone else's fan. The account ends.
    ///   - **`.failedBeforeFirstWrite`:** nothing was written and nothing read. The account stands.
    ///   - **Anything else** ends the account: an undo that landed, the hand-back returning; a
    ///     lease that is ending, or § 3's latch; or `.superseded`, which also follows an undo that
    ///     landed.
    /// - With no account, every refusal is thrown as it is, and `.notAutomatic` is
    ///   `foreignManualControl`.
    ///
    /// Sound while `.notAutomatic` comes only from a first step, which holds while the examination
    /// gate admits one engagement of a fan (#389), and while only a first step throws
    /// `.failedBeforeFirstWrite`, which is the plane's contract.
    mutating func read(
        _ refusal: any Error, of index: Int, under lease: UUID, into fans: inout ApplyEngagements,
        log: SafetyLog
    ) throws {
        if refusal is EngagementUndoRefused {
            keep(index, under: lease)
            fans.keptByTheDriver.append(index)
            throw refusal
        }
        guard account(of: index, under: lease) == .handBackRefused else { throw refusal }
        switch refusal as? FanControlPlaneError {
        case .notAutomatic(_, let raw)? where EngagementRules.isEngagedMode(raw):
            log.controlLoopKeptFanReAdopted(fan: index, rawMode: raw)
        case .failedBeforeFirstWrite?:
            throw refusal
        default:
            remove(index, under: lease)
            throw refusal
        }
    }
}

/// One `apply`'s share of level 6's account: the fans it came to hold as engaged, by an engagement
/// that returned or a kept fan re-adopted, in the order it held them, which its undo hands back;
/// and the one the driver could not hand back itself (#406), which the refusal's notice names
/// beside the undo's own.
struct ApplyEngagements: Sendable {
    var engaged: [Int] = []
    var keptByTheDriver: [Int] = []

    /// The refused `apply`'s notice, once its undo has run: the fans it handed back, and the ones
    /// whose hand-back was refused, `kept` by the undo or by the driver itself. The detail is the
    /// refusal's cause, so a refused undo reads as the step's own refusal.
    func sayRefused(because error: any Error, keptByTheUndo kept: [Int], to log: SafetyLog) {
        log.controlLoopApplyRefused(
            handedBack: engaged.filter { !kept.contains($0) }, refused: kept + keptByTheDriver,
            detail: String(describing: EngagementUndoRefused.cause(of: error)))
    }
}
