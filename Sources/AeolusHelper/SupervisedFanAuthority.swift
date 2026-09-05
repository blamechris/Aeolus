import AeolusXPC
import FanKit
import Foundation

/// The helper's `FanAuthority`: the read path it already had, and the lease core behind it.
///
/// It replaces `ReadOnlyFanAuthority` at the composition root. Until #163 that type *was*
/// the helper's authority, and every control verb on it threw a hard-coded refusal —
/// truthfully, because no lease core was wired into the daemon at all. Every E5 mechanism
/// that had merged was therefore inert in production, which is the finding #103 was reopened
/// on.
///
/// ## What actually changed, which is less than it looks
///
/// On this machine, today, a client sees the same thing it saw before: the same fans, the
/// same sensors, `activeLease: nil`, and every fan
/// `manualControlAvailability: .unavailable(.writePathNotBuilt)`. `SMCFanControlPlane`
/// answers `FanWriteCapability.notBuilt`, so `LeaseAuthority.acquireLease` refuses before it
/// reaches anything else. What changed is **where the refusal comes from**: a literal in a
/// type that could not have done otherwise has become a gate reading the seam that would
/// have to perform the write. The mechanisms behind it — the lease table, both teardown
/// paths, § 3, § 5 — are now running rather than merely present.
///
/// ## It holds no plane, and cannot write
///
/// The one thing it needs of the firmware beyond the read path is *whether there is a write
/// path*, and it takes that as `FanWriteCapabilityReporting` rather than as a
/// `FanControlPlane`. Handing an authority a plane would put `commandTarget(_:)` one
/// `await` from a decoded client message, which is the shape E2 froze this seam to prevent —
/// see `FanControlPlane` and `FanStateSensing` for the same argument made twice already.
/// E3 adds the control loop; it does not add it here by accident first.
///
/// ## The composition, in one line each
///
/// - `snapshot` — the read path, plus the lease the lease core reports.
/// - `acquireLease` / `renewLease` / `releaseLease` / `connectionDidInvalidate` — the lease
///   core, verbatim. Every signature already matched, which is what `LeaseAuthority`'s own
///   documentation predicted: *"every method below carries a `FanAuthority` signature
///   verbatim, so the helper's control plane composes it with one-line forwards."*
/// - `apply` — authorises, then refuses. There is no control loop to apply anything with.
/// - `restoreAllToAutomatic` — § 7's panic verb, as much of it as this build can perform.
struct SupervisedFanAuthority: FanAuthority {

    /// The snapshot path, unchanged: `SMCFanEnumeration`, the discovered sensor set, and
    /// `F<n>Md` per fan, all through the scheduler's snapshot reader.
    ///
    /// Composed rather than absorbed. Its discovery cache, its once-per-process `readAll()`
    /// invariant and its per-fan unreadable-mode throttle are all state that belongs to
    /// reading the machine, and moving them here to save an indirection would put them in the
    /// same type as the privilege boundary's control verbs.
    private let reading: ReadOnlyFanAuthority

    private let leases: LeaseAuthority

    /// Why `apply` refuses, asked of the seam rather than assumed. See
    /// `FanWriteCapabilityReporting`.
    private let writeCapability: any FanWriteCapabilityReporting

    private let log: HelperLog

    init(
        reading: ReadOnlyFanAuthority,
        leases: LeaseAuthority,
        writeCapability: some FanWriteCapabilityReporting,
        log: HelperLog
    ) {
        self.reading = reading
        self.leases = leases
        self.writeCapability = writeCapability
        self.log = log
    }

    // MARK: - Reporting

    /// The machine, then the lease — in that order, deliberately.
    ///
    /// A snapshot's `capturedAt` comes from the read path and covers ~0.5 s of subset reads
    /// on this machine, so the lease is read at one end of that span whichever end is chosen.
    /// It is read at the **end** because `LeaseAuthority.activeLease()` sweeps anything
    /// lapsed first: taken before the reads, a lease that expired during them would be
    /// reported as live, and a client shown a lease that has already stopped holding the fans
    /// is `CLAUDE.md` rule 6 exactly. Taken after, the worst case is a lease granted during
    /// the reads appearing beside fan values from a moment before it existed — a fan reported
    /// automatic under a lease that has not yet commanded anything, which is a true statement
    /// about both.
    ///
    /// The other four fields are the read path's own and are passed through untouched: this
    /// re-assembles the value rather than producing a second opinion about any of them.
    func snapshot() async throws -> SystemSnapshot {
        let machine = try await reading.snapshot()
        return SystemSnapshot(
            fans: machine.fans,
            sensors: machine.sensors,
            activeLease: await leases.activeLease(),
            isThermalEmergencyActive: machine.isThermalEmergencyActive,
            capturedAt: machine.capturedAt
        )
    }

    // MARK: - Control

    func acquireLease(
        _ request: LeaseRequest,
        from connection: ConnectionID
    ) async throws -> Lease {
        try await leases.acquireLease(request, from: connection)
    }

    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease {
        try await leases.renewLease(id: id, from: connection)
    }

    func releaseLease(id: UUID, from connection: ConnectionID) async throws {
        try await leases.releaseLease(id: id, from: connection)
    }

    /// Authorises, and then refuses.
    ///
    /// The authorisation is not ceremony: `heldLease(id:from:)` distinguishes "no such
    /// lease", "not yours" and "expired", and a client debugging its own lease handling is
    /// entitled to those answers rather than to a blanket refusal that hides them. It is also
    /// what keeps this method honest the day the control loop lands — the check will already
    /// be here, in front of the write, rather than being added alongside it.
    ///
    /// The refusal is `.writePathNotBuilt` unconditionally, and that is **not** a literal
    /// standing in for `writeCapability`: there is no control loop in this type for a
    /// capable plane to reach. A `.built` seam behind a helper with nothing to apply is a
    /// state only a test can produce, and answering it any other way would claim a
    /// capability this file does not contain. E3 owns the body; #17 owns the curve behind it.
    func apply(
        _ settings: [FanSetting],
        leaseID: UUID,
        from connection: ConnectionID
    ) async throws {
        _ = try await leases.heldLease(id: leaseID, from: connection)
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    /// Drops every lease and restores the fans they covered.
    ///
    /// `docs/SAFETY.md` § 7's panic verb, as much of it as exists. `releaseEveryLease()` is
    /// the lease core's half and it is real work now: each dropped lease's fans go through
    /// `HelperFanRestorer`, so both safety registries are told and the firmware is asked.
    ///
    /// **It does not additionally call `restoreToAutomatic(.everyFan)` on the plane**, and
    /// that is a decision rather than an omission. That verb throws `.controlPathNotBuilt`
    /// unconditionally in this build, so calling it would convert a v1 message that succeeds
    /// into one that always fails, while leaving the machine in precisely the same state.
    /// The message's contract is frozen at v1 ([#159](https://github.com/blamechris/Aeolus/issues/159))
    /// and keeps the fewest preconditions it can have. A fan some *other* tool left in manual
    /// is not this verb's to clear either — startup reconciliation owns it
    /// ([#164](https://github.com/blamechris/Aeolus/issues/164)), and E5.4d wires the machine-wide
    /// restore to the signal handlers ([#166](https://github.com/blamechris/Aeolus/issues/166))
    /// once there is a write path for it to use.
    func restoreAllToAutomatic(from connection: ConnectionID) async throws {
        await leases.releaseEveryLease()
        log.restoredAllToAutomatic(connection: connection)
    }

    func connectionDidInvalidate(_ connection: ConnectionID) async {
        await leases.connectionDidInvalidate(connection)
    }
}
