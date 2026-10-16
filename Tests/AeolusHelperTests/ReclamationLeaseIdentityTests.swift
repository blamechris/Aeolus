import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5 acts for the lease a fan was registered under, and for no other
/// ([#357](https://github.com/blamechris/Aeolus/issues/357),
/// [#353](https://github.com/blamechris/Aeolus/issues/353); ADR 0009's 2026-10-15 amendment).
///
/// Every scenario here ends a lease and grants another over the **same fan** before § 5 looks
/// again — the re-grant `acquireLease` allows as soon as the first lease's restore returns.
/// Asked "does some live lease cover this fan?", the newer lease answered for the older lease's
/// record: § 5 re-asserted a target for a holder that never applied, spent its budget, gave the
/// fan up and revoked the newer lease blaming the system. Asked about the record's own lease,
/// each of those is a hand-back of the stale record, or nothing at all.
///
/// `endLease()` ends the fixture's lease the way a client dying does and tells § 5 nothing —
/// `RecordingFanRestorer` calls nobody back — so the stale record #357 describes is left in
/// place. The newer lease comes from a new `ConnectionID`, because `endLease()` tombstones the
/// fixture's own.
@Suite("The reclamation watchdog acts for the fan's own lease", .timeLimit(.minutes(1)))
struct ReclamationLeaseIdentityTests {

    /// A lease over fan 0 from a connection the fixture never used.
    static func regrant<Writes>(
        _ machine: ReclamationMachine<Writes>
    ) async throws -> Lease {
        try await machine.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
    }

    /// Fan 0's permit, minted from its declared condition as the fixture mints one.
    static func permit<Writes>(
        _ machine: ReclamationMachine<Writes>
    ) throws -> CommandableFan {
        try commandableFan(0, declaring: try #require(machine.fanConditions[0]))
    }

    /// The lease the fixture's `hold` registered under.
    static func activeLease<Writes>(
        _ machine: ReclamationMachine<Writes>
    ) async throws -> UUID {
        try #require(await machine.leases.activeLease()).id
    }

    // MARK: - #357: a stale record judged under the next lease

    /// **#357's first harm.** L1 holds fan 0 at 2,400 RPM and ends with § 5 never told. L2 is
    /// granted over fan 0, and the fan reads automatic — L1's restore landed. With a commanded
    /// target on record that is `.modeReclaimed`, and a coverage question answered by L2 let § 5
    /// re-engage the fan and re-command L1's target for a holder that never applied.
    ///
    /// **Mutation:** make `LeaseTable.covers(_:under:liveAt:)` ignore `id` — any live entry
    /// covering the fan answers. Run: red on the engage, command and restorer assertions.
    @Test("A stale record is handed back, not re-asserted under the next lease")
    func aStaleRecordIsNotReassertedUnderTheNextLease() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        await machine.endLease()
        let next = try await Self.regrant(machine)
        await machine.plane.setMode(.automatic, ofFan: 0)

        await machine.watchdog.cycle()

        #expect(
            await machine.attempts.contains(.engageManualControl(fan: 0)) == false,
            "§ 5 took fan 0 off automatic control for a lease that had ended")
        #expect(await machine.commandedRPMs.isEmpty, "§ 5 re-commanded the old lease's target")
        #expect(await machine.didRestore(fan: 0), "the stale record's fan was not handed back")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.leases.activeLease()?.id == next.id, "the new lease did not survive")
        #expect(
            await machine.restorer.causes.contains(.systemReclaimed) == false,
            "a lease was revoked blaming the system for a lease ending")
        #expect(await machine.ledger.causes.isEmpty)
        #expect(machine.safetyLog.lines(containing: leaseLapsedNotice).count == 1)
    }

    /// **#357's second harm.** The firmware discards every write, so L1's re-asserts spend the
    /// whole budget. L1 then ends, L2 is granted, and the next cycle would have been the budget's
    /// terminal action — judged under L2, it gave the fan up as reclaimed by the system.
    ///
    /// **Mutation:** as above. Run: red on the budget fault and the "already ended" notice —
    /// the terminal action now revokes only L1, which is gone, so L2 survives either way, and
    /// what discriminates is that the stale record reached the terminal action at all.
    @Test("A stale record does not spend the next lease's fan")
    func aStaleRecordDoesNotSpendTheNextLease() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(writes: .reverted)], fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        for _ in 0..<ReclamationLimits.reassertAttemptBudget {
            await machine.watchdog.cycle()
        }
        #expect(
            machine.safetyLog.lines(containing: "re-asserted 2400 RPM").count
                == ReclamationLimits.reassertAttemptBudget,
            "the setup did not spend L1's budget")
        await machine.endLease()
        let next = try await Self.regrant(machine)

        await machine.watchdog.cycle()

        #expect(await machine.leases.activeLease()?.id == next.id)
        #expect(await machine.restorer.causes.contains(.systemReclaimed) == false)
        #expect(
            machine.safetyLog.faults.contains { $0.contains("budget") } == false,
            "the old lease's spent budget gave the new lease's fan up")
        #expect(machine.safetyLog.lines(containing: "had already ended").isEmpty)
        #expect(await machine.didRestore(fan: 0))
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    // MARK: - Registration

    /// A registration under a new lease replaces an ended lease's record with a fresh one: the
    /// old lease's end restored the fan, so its target and its spent counters are not the new
    /// lease's (#180's anti-rearm rule is per lease, and this is not a rearm).
    ///
    /// **Mutation:** make `HeldFan.registering(_:over:)` keep any existing record —
    /// `if let existing { return existing }`. Run: red on `lastCommanded` and the notice.
    @Test("A registration under a new lease starts a fresh record")
    func aRegistrationUnderANewLeaseStartsAFreshRecord() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        await machine.endLease()
        let next = try await Self.regrant(machine)

        try await machine.watchdog.manualControlEngaged(try Self.permit(machine), under: next.id)

        #expect(
            await machine.watchdog.lastCommanded(ofFan: 0) == nil,
            "the new lease inherited the ended lease's target")
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        #expect(
            machine.safetyLog.lines(containing: "replacing the record an ended lease left").count
                == 1)
    }

    /// A registration that arrives late, under a lease that has already ended, is refused and
    /// touches nothing: the live lease's record keeps its target, and nothing is handed back.
    /// At most one live lease covers a fan, so the lease core is the only arbiter between the
    /// two.
    ///
    /// **Mutation:** in `ReclamationWatchdog.Registry.register(_:fanAt:live:since:)`, drop `live`
    /// from the refusal — `guard registrations[index, default: 0] == generation, finalising[index]
    /// != lease` — so a lease that is not live records. Run: red on the refusal, `lastCommanded`
    /// and the cycle's restore.
    @Test("A late registration under an ended lease is refused and evicts nothing")
    func aLateRegistrationUnderAnEndedLeaseIsRefusedAndEvictsNothing() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_000)])
        let ended = try await machine.lease()
        await machine.endLease()
        let next = try await Self.regrant(machine)
        let permit = try Self.permit(machine)
        try await machine.watchdog.manualControlEngaged(permit, under: next.id)
        await machine.watchdog.commandedTarget(
            CommandedTarget(fanIndex: 0, rpm: 2_000), under: next.id)

        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await machine.watchdog.manualControlEngaged(permit, under: ended.id)
        }
        await machine.watchdog.cycle()

        #expect(
            await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000,
            "a registration under an ended lease evicted the live lease's record")
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        #expect(machine.safetyLog.lines(containing: "refused to register fan 0").count == 1)
    }

    /// A target reported under an ended lease does not reach the live lease's record.
    ///
    /// **Mutation:** in `ReclamationWatchdog.commandedTarget(_:under:)`, guard on presence —
    /// `guard registry.record(ofFan: commanded.fanIndex) != nil`. Run: red.
    @Test("A stale target does not reach the new lease's record")
    func aStaleTargetDoesNotReachTheNewRecord() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_000)])
        let ended = try await machine.lease()
        await machine.endLease()
        let next = try await Self.regrant(machine)
        try await machine.watchdog.manualControlEngaged(try Self.permit(machine), under: next.id)
        await machine.watchdog.commandedTarget(
            CommandedTarget(fanIndex: 0, rpm: 2_000), under: next.id)

        await machine.watchdog.commandedTarget(
            CommandedTarget(fanIndex: 0, rpm: 2_400), under: ended.id)

        #expect(
            await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000,
            "an ended lease's target was written into the new lease's record")
    }

    // MARK: - Re-fetches after an await ask about identity
    //
    // All but two are held here or in `ReclamationRefetchIdentityTests.swift`, whose header lists
    // each re-fetch against its test. The precedence check and the ledger hop in `diverged` are
    // not: they sit on concrete actors with nothing to park an answer in (#365).

    /// The re-fetch after the control-state read asks about the record's lease, not its
    /// presence. A newer lease registers fan 0 inside the read; § 5 stops there, and leaves the
    /// newer record and the fan alone.
    ///
    /// Behaviourally a presence check here is caught one hop later, by the re-fetch after the
    /// lease check — so the **log line** is what discriminates the two, as
    /// `aFanReleasedDuringTheControlStateReadIsAbandoned` records for the presence half.
    ///
    /// **Mutation:** make the re-fetch after `readControlState(ofFan:)` in `examine(fanAt:)`
    /// check presence only — `guard registry.record(ofFan: index) != nil`. Run: red on the log
    /// assertion.
    @Test("A record registered under a new lease during the read stops the examination there")
    func aRecordRegisteredUnderANewLeaseDuringTheReadStopsTheExamination() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .controlStateRead)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 1_800)], sensing: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await machine.endLease()
            await machine.watchdog.manualControlReleased(fanAt: 0)
            do {
                let next = try await Self.regrant(machine)
                try await machine.watchdog.manualControlEngaged(permit, under: next.id)
            } catch {
                Issue.record("the re-grant inside the read failed: \(error)")
            }
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            machine.safetyLog.lines(containing: "during its control-state read").count == 1,
            "the examination of the old lease's record went past the read")
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.ledger.causes.isEmpty)
    }

    /// A newer lease registers fan 0 while § 5's re-assert command write is in flight. The
    /// command landed, so the fan is off automatic control — under the newer lease's engagement,
    /// whose own record now watches it. § 5 neither writes its old target into that record nor
    /// forgets it nor hands the fan back.
    ///
    /// **Mutation (a):** make the re-fetch after the command write check presence only —
    /// `guard registry.record(ofFan: index) != nil`. Run: red on `lastCommanded` and the
    /// "re-asserted" line.
    /// **Mutation (b):** drop the other-lease check in `ReclamationWatchdog.Registry.forget(fanAt:
    /// ifUnder:)`, which `restoreAndForget(fanAt:heldUnder:)` guards on. Run: red on the registry
    /// and the restore.
    @Test("A record registered under a new lease during the command write is left to it")
    func aRecordRegisteredUnderANewLeaseDuringTheCommandWriteIsLeftToIt() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .commandWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await machine.endLease()
            await machine.watchdog.manualControlReleased(fanAt: 0)
            do {
                let next = try await Self.regrant(machine)
                try await machine.watchdog.manualControlEngaged(permit, under: next.id)
                await machine.watchdog.commandedTarget(
                    CommandedTarget(fanIndex: 0, rpm: 2_000), under: next.id)
            } catch {
                Issue.record("the re-grant inside the command write failed: \(error)")
            }
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.commandedRPMs == [2_400], "the re-assert's command never landed")
        #expect(
            await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000,
            "§ 5 wrote the old lease's target into the new lease's record")
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        #expect(await machine.didRestore(fan: 0) == false, "§ 5 handed back the new lease's fan")
        #expect(machine.safetyLog.lines(containing: "re-asserted").isEmpty)
        #expect(machine.safetyLog.lines(containing: "left fan 0 alone").count == 1)
    }

    // MARK: - The terminal action

    /// The terminal action is for the lease it was holding the fan for. An uncommanded fan
    /// reading automatic is graced and then given up; inside its hand-back, L1 ends and L2 is
    /// granted and registers fan 0. The hand-back still lands — L1's episode may have written
    /// after its own release's restore — and then L2's record is kept and L2 is not revoked.
    ///
    /// **Mutation (a):** make `ReclamationWatchdog.Registry.dropLease(_:sparing:)`, which
    /// `finaliseRelease(fanAt:heldUnder:because:)` calls after the hand-back, also drop `index`
    /// whatever lease holds it — `held[index] = nil`. Run: red on the registry.
    /// **Mutation (b):** replace the `revokeLease(id:forFan:because:)` guard with
    /// `await leases.revokeEveryLease(because: cause)`. Run: red on L2 and the restorer.
    @Test("A terminal action leaves a newer lease's record and lease alone")
    func aTerminalActionLeavesANewerLeasesRecordAlone() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 2_400)])
        let sensing = InterferingFanStateSensing(plane, during: .restoreWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 2_400)], interfering: sensing)
        try await machine.holdWithoutCommanding(fan: 0)
        let permit = try Self.permit(machine)
        let granted = GrantedLeases()
        await sensing.interfere { [machine] in
            await machine.endLease()
            do {
                let next = try await Self.regrant(machine)
                await granted.record(next.id)
                await machine.plane.setMode(.manual, ofFan: 0)
                try await machine.watchdog.manualControlEngaged(permit, under: next.id)
            } catch {
                Issue.record("the re-grant inside the hand-back failed: \(error)")
            }
        }

        try await cycledToTheTerminalAction(machine.watchdog)

        #expect(await sensing.didFire, "the terminal action's hand-back never reached the seam")
        #expect(machine.safetyLog.lines(containing: "no speed to re-assert").count == 1)
        let next = try #require(await granted.ids.first)
        #expect(
            await machine.watchdog.fansUnderManualControl == [0],
            "the terminal action dropped the new lease's record")
        #expect(await machine.leases.activeLease()?.id == next, "the new lease was revoked")
        #expect(
            await machine.restorer.causes.contains(.systemReclaimed) == false,
            "a lease was revoked blaming the system for the old lease's episode")
        #expect(machine.safetyLog.lines(containing: "had already ended").count == 1)
    }
}

/// The leases a scenario granted inside an interference effect, in order.
actor GrantedLeases {
    private(set) var ids: [UUID] = []

    func record(_ id: UUID) { ids.append(id) }
}
