import FanKit
import Testing

@testable import AeolusHelper

/// [ADR 0009](../../docs/ADR/0009-precedence-at-the-write.md) D2: the lease table is the
/// authority, and § 5's registry of held fans is a hint
/// ([#180](https://github.com/blamechris/Aeolus/issues/180)).
///
/// A fan in `held` with no live lease covering it is `ReclamationDivergence.leaseLapsed`,
/// decided in `examine(fanAt:)` after the control-state read and before either firmware
/// signal is computed from it, and its only action is restore-and-forget: no re-assert, no
/// ledger mark, no revocation. Every scenario here ends a lease **without telling § 5** —
/// `endLease()` drops the table entry and hands the fans to a `RecordingFanRestorer`, and
/// `lapseLease()` moves the lease core's clock past the deadline and sweeps nothing — because
/// that silence is what D2 exists to survive. The shipped `HelperFanRestorer` does tell § 5,
/// before every lease-core restore; D2's premise is that a registry kept by notification is
/// not the control, so these tests do not lean on it.
///
/// ## The order is the decision, so each half of it has a test that fails without it
///
/// - **Before the signals** — `aFanWhoseLeaseLapsedIsRestoredNotReasserted`: move the lease
///   check below `primaryDivergence(of:against:)` and `.modeReclaimed` re-engages the fan.
/// - **After the read** — `aLeaseEndingDuringTheReadIsCaughtByTheCheckAfterIt`: move it above
///   `readControlState(ofFan:)` and a teardown's restore landing inside the read is judged as
///   the system reclaiming the fan.
/// - **Before a failed read is counted** — `anUnreadableFanWithNoLeaseIsHandedBackAtOnce`:
///   check only a successful read and the fan sits out the blindness threshold instead.
@Suite("The reclamation watchdog's lease check (ADR 0009 D2)")
struct ReclamationLeaseLapseTests {

    /// **The named test for the liveness guard, and the defect #180 opened with.** A lease
    /// lapses with nobody told; the fan reads automatic — the lease core's restore landed —
    /// and with a commanded target on record that is `.modeReclaimed`, the strongest primary
    /// signal there is. Without D2 that re-engaged `F<n>Md` and re-commanded the old speed:
    /// manual control with no lease counting a TTL, `CLAUDE.md` rule 2 inverted by the
    /// mechanism written to uphold it.
    ///
    /// The lease is **lapsed, not removed**: `lapseLease()` leaves the entry in the table, so
    /// this also fails against a query that judges presence instead of the deadline.
    ///
    /// The ledger is read **at the restore write** as well as afterwards, through the
    /// `.restoreWrite` moment. `restoreAndForget(fanAt:)` ends by clearing the ledger, so a
    /// `markReclaimed` issued before it would leave the end state clean and is visible only
    /// in between — the same masking `itNeverReassertsWhileTheThermalLatchHolds` records for
    /// § 3's branch, closed here by looking at the instant rather than at a log line.
    ///
    /// **Mutation:** delete the `guard await leases.hasLiveLease(coveringFan:)` block from
    /// `examine(fanAt:)`. Run: red on the engage assertion — the write the guard refuses —
    /// and on every assertion after it except `restorer.causes`.
    /// **Mutation:** move that block below the primary-signal `if` in `examine(fanAt:)`. Run:
    /// red on the same assertions.
    /// **Mutation:** add `await ledger.markReclaimed(fanAt: index)` to the guard's `else`,
    /// before `restoreAndForget`. Run: red on `sightings` — and with it after
    /// `restoreAndForget`, red on the final ledger assertion.
    /// **Mutation:** make `LeaseTable.covers(_:liveAt:)` ignore the deadline. Run: red here.
    @Test("A fan whose lease lapsed is handed back and forgotten, never re-asserted")
    func aFanWhoseLeaseLapsedIsRestoredNotReasserted() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 2_400)])
        let sensing = InterferingFanStateSensing(plane, during: .restoreWrite)
        let machine = ReclamationMachine(plane: plane, interfering: sensing)
        let sightings = LedgerSightings()
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [ledger = machine.ledger] in
            await sightings.record(await ledger.causes)
        }

        machine.lapseLease()
        await plane.setMode(.automatic, ofFan: 0)
        #expect(await machine.leases.leaseCount == 1, "the lapsed lease was swept: not D2's case")

        await machine.watchdog.cycle()

        #expect(
            await machine.attempts.contains(.engageManualControl(fan: 0)) == false,
            "§ 5 took a fan off automatic control under a lease that had lapsed")
        #expect(await machine.commandedRPMs.isEmpty, "§ 5 re-commanded a fan nobody holds")
        #expect(await machine.didRestore(fan: 0), "a fan with no live lease was not handed back")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await sensing.didFire, "the restore never reached the write seam")
        #expect(
            await sightings.seen == [[:]],
            "the ledger claimed a reclamation while the fan was being handed back")
        #expect(
            await machine.ledger.causes.isEmpty,
            "a lease lapsing was reported as the system reclaiming the fan")
        // No revocation on § 5's behalf: `finaliseRelease` would have swept the lapsed entry
        // through the lease core's restorer under `.systemReclaimed`.
        #expect(await machine.restorer.causes.isEmpty)
        #expect(machine.safetyLog.lines(containing: "no live lease covers it").count == 1)
        #expect(machine.safetyLog.levels(containing: "no live lease covers it") == [.notice])
        #expect(machine.safetyLog.lines(containing: "Reclamation detected").isEmpty)
    }

    /// **After the read, never before it.** The lease ends *inside* the control-state read,
    /// and its restore lands before the read samples the fan — so the read sees automatic.
    /// Every teardown removes the table entry before it restores, so the query after the read
    /// sees the lease gone; a query taken before the read saw it live, and the reading then
    /// looked exactly like the system taking the fan.
    ///
    /// **Mutation:** move the lease-check block above the `readControlState(ofFan:)` call in
    /// `examine(fanAt:)`. Run: red on every assertion after `didFire`, and on no other test.
    @Test("A lease ending during the read is caught by the check after it")
    func aLeaseEndingDuringTheReadIsCaughtByTheCheckAfterIt() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 2_400)])
        let sensing = InterferingFanStateSensing(plane, during: .controlStateRead)
        let machine = ReclamationMachine(plane: plane, sensing: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [machine] in
            await machine.endLease()
            await machine.plane.setMode(.automatic, ofFan: 0)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            await machine.attempts.contains(.engageManualControl(fan: 0)) == false,
            "a teardown's restore landing mid-read was re-asserted as a reclamation")
        #expect(await machine.commandedRPMs.isEmpty)
        #expect(await machine.didRestore(fan: 0))
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.ledger.causes.isEmpty)
        #expect(machine.safetyLog.lines(containing: "no live lease covers it").count == 1)
    }

    /// **Before a failed read is counted.** The SMC answers nothing and the lease has ended:
    /// the blindness threshold is a tolerance for a fan Aeolus holds, and this one is not
    /// held, so it is handed back on the first cycle — with no reconnect, no blindness count
    /// and nothing in the ledger, where the blind path would have marked it
    /// `.supervisorBlind` three cycles later and revoked every lease on the machine.
    ///
    /// **Mutation:** move the lease-check block below the `switch reading` in
    /// `examine(fanAt:)`, where only a successful read reaches it. Run: red on the restore,
    /// the registry and both log assertions, and on no other test.
    @Test("An unreadable fan with no live lease is handed back at once")
    func anUnreadableFanWithNoLeaseIsHandedBackAtOnce() async throws {
        let machine = ReclamationMachine(stages: [.blind()], fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        await machine.endLease()

        await machine.watchdog.cycle()

        #expect(await machine.didRestore(fan: 0), "a fan nobody holds sat out a blind cycle")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.attempts.contains(.reconnect) == false)
        #expect(await machine.ledger.causes.isEmpty)
        #expect(machine.safetyLog.lines(containing: "no live lease covers it").count == 1)
        #expect(machine.safetyLog.lines(containing: "could not read fan 0").isEmpty)
    }

    /// **Not conditional on divergence.** A fan reading exactly as Aeolus left it — manual,
    /// on the commanded target — is converged on both signals, and nothing in § 5 used to
    /// revisit such a fan once its lease was gone.
    ///
    /// In the shipped composition `HelperFanRestorer` deregisters § 5 before every
    /// lease-core restore, so this is a registration that outlived its lease by some other
    /// route — a restorer that does not deregister, or a fan registered after its lease ended,
    /// which is what a level-6 write racing a release will produce. It is the converged half
    /// of the guard's mutation, which the divergent scenario above cannot see.
    ///
    /// **Mutation:** delete the lease-check block. Run: red on the restore and registry
    /// assertions.
    @Test("A converged fan whose lease ended is handed back")
    func aConvergedFanWhoseLeaseEndedIsHandedBack() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        await machine.endLease()

        await machine.watchdog.cycle()

        #expect(await machine.didRestore(fan: 0), "an unleased fan was left pinned at 2,400 RPM")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.commandedRPMs.isEmpty)
        #expect(await machine.ledger.causes.isEmpty)
    }

    /// **Per fan.** A live lease over fan 1 does not entitle § 5 to fan 0, and the answer for
    /// fan 0 does not touch fan 1 or the lease.
    ///
    /// **Mutation:** make `LeaseTable.covers(_:liveAt:)` ignore `fan` — any live entry
    /// answers. Run: red on fan 0's restore, the registry and the log assertion.
    @Test("A live lease over another fan does not entitle this one")
    func aLeaseOverAnotherFanDoesNotEntitleThisOne() async throws {
        let fans: [Int: ScriptedControlPlane.FanCondition] = [
            0: .held(at: 2_400), 1: .held(at: 2_400),
        ]
        let machine = ReclamationMachine(fans: fans)
        let lease = try await machine.lease(fans: [1])
        try await machine.hold(fan: 0, commanding: 2_400)
        try await machine.hold(fan: 1, commanding: 2_400)

        await machine.watchdog.cycle()

        #expect(await machine.didRestore(fan: 0), "fan 0 was kept on fan 1's lease")
        #expect(await machine.didRestore(fan: 1) == false)
        #expect(await machine.watchdog.fansUnderManualControl == [1])
        #expect(await machine.leases.activeLease()?.id == lease.id)
        #expect(machine.safetyLog.lines(containing: "no live lease covers it").count == 1)
    }

    /// The lease core's half: one fan, one instant, judged against the deadline.
    ///
    /// **Mutation:** make `LeaseTable.covers(_:liveAt:)` ignore the deadline. Run: red on the
    /// lapsed assertion. Ignoring `fan` instead: red on fan 1.
    @Test("The lease core answers per fan, against the deadline, without sweeping")
    func theLeaseCoreAnswersPerFanAgainstTheDeadline() async throws {
        let clock = TestClock()
        let leases = LeaseFixture.authority(clock: clock)
        #expect(await leases.hasLiveLease(coveringFan: 0) == false)

        let connection = ConnectionID()
        _ = try await leases.acquireLease(LeaseFixture.request(fans: [0]), from: connection)
        #expect(await leases.hasLiveLease(coveringFan: 0))
        #expect(await leases.hasLiveLease(coveringFan: 1) == false)

        clock.advance(by: .seconds(Lease.defaultTimeToLive))
        #expect(
            await leases.hasLiveLease(coveringFan: 0) == false,
            "a lease whose deadline is exactly now has had its full TTL")
        #expect(await leases.leaseCount == 1, "the question swept the table it was asked about")

        await leases.expireLapsedLeases()
        #expect(await leases.hasLiveLease(coveringFan: 0) == false)
    }
}

/// What § 5's ledger said at each instant a scenario looked.
actor LedgerSightings {
    private(set) var seen: [[Int: ReclamationLedger.Cause]] = []

    func record(_ causes: [Int: ReclamationLedger.Cause]) {
        seen.append(causes)
    }
}
