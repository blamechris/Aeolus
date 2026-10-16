import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The identity half of § 5's re-fetches after an `await`
/// ([#365](https://github.com/blamechris/Aeolus/issues/365), from the panel on #361; #344 for the
/// lease hop).
///
/// `docs/SAFETY.md` § 5: after every suspension the fan's record is re-fetched, and § 5 stops
/// if it is gone *or belongs to another lease*. Each scenario below lands a registration under a
/// **newer lease** inside one suspension and asserts that § 5 neither restores, forgets,
/// commands nor marks that lease's fan. Changing the re-fetch to presence only
/// (`registry.record(ofFan:) != nil`) left the whole helper suite green before these.
///
/// ## Where each re-fetch is pinned
///
/// Each is a re-fetch in `ReclamationWatchdog.swift`, named by the suspension it follows. A test
/// without a suite named is in `ReclamationLeaseIdentityTests`, as this file is.
///
/// - **The control-state read**, in `examine`:
///   `aRecordRegisteredUnderANewLeaseDuringTheReadStopsTheExamination`.
/// - **The lease hop**, in `examine`: `aRecordChangedDuringTheLeaseCheckStopsTheExamination`.
/// - **The precedence check** and **the ledger hop**, in `diverged`: untested, below.
/// - **The envelope read**, in `reassert`:
///   `aRecordRegisteredUnderANewLeaseDuringTheEnvelopeReadIsLeftToIt`.
/// - **The first write**, in `reassert`:
///   `aRecordRegisteredUnderANewLeaseDuringTheFirstWriteIsLeftToIt`.
/// - **The command write**, in `reassert`:
///   `aRecordRegisteredUnderANewLeaseDuringTheCommandWriteIsLeftToIt`.
/// - **A refused command write**, in `commandWriteFailed`:
///   `ReclamationWatchdogStalenessTests.aRegrantedRecordDuringAFailedCommandWriteIsLeftAlone`.
/// - **The reconnect**, in `cycleCouldNotSee`:
///   `aRecordRegisteredUnderANewLeaseDuringTheReconnectIsLeftToIt`.
/// - **The envelope-failure branch**, which has no re-fetch of its own: `finaliseRelease`'s entry
///   guard covers it, and
///   `aTerminalActionEnteredForAnEndedLeaseLeavesTheNewerLeasesFanAlone` holds that guard.
///
/// ## The two that are not tested, and why
///
/// The precedence check and the ledger hop are suspensions on `ThermalEmergencyLatch` and
/// `ReclamationLedger`, which `ReclamationWatchdog` holds as concrete actors. There is no double
/// to park their answers in, so a registration cannot be landed in either by a suspending seam:
/// racing one in is the flakiness #109 is open about, and blocking a pool thread to hold the hop
/// open passed locally and failed in a CI runner stall. Reaching them takes the step
/// `HeldLeaseRole` took for the lease core: a role over each, in `Sources/AeolusHelper`. A
/// registration cannot land in either from an earlier suspension either, because the re-fetches
/// before them stop the examination first. This file does not claim them, and neither do
/// `docs/SAFETY.md` § 5 or the watchdog's records.
///
/// ## The newer lease
///
/// Two ways it arrives. `granted` is the shipping order: the old lease ends, § 5 is told, the lease
/// core grants another over the fan and it registers. `vouched` keeps the old lease live in the
/// lease core and has § 5's own role answer for the newer one (`ParkableHeldLeases.vouch(for:)`),
/// for the suspensions the engagement driver sits inside: its entitlement question is asked of
/// the real lease core about the *old* lease, so an old lease that has really ended is refused
/// there before § 5's re-fetch is reached.
extension ReclamationLeaseIdentityTests {

    /// How a newer lease comes to hold fan 0's record inside a suspension.
    enum NewerLease: Sendable, CaseIterable {
        /// The old lease ends, § 5 is told, and the lease core grants another over the fan.
        case granted
        /// The old lease stays live in the lease core; § 5's role answers for another id.
        case vouched
    }

    /// The newer lease's whole arrival: it holds fan 0, registers it, and commands 2,000 RPM
    /// of its own, which is what tells its record from the old lease's 2,400.
    static func arrive<Writes>(
        _ how: NewerLease, machine: ReclamationMachine<Writes>, permit: CommandableFan,
        granted: GrantedLeases
    ) async {
        do {
            let next: UUID
            switch how {
            case .granted:
                await machine.endLease()
                await machine.watchdog.manualControlReleased(fanAt: 0)
                next = try await regrant(machine).id
            case .vouched:
                await machine.watchdog.manualControlReleased(fanAt: 0)
                next = UUID()
                let hops = try #require(machine.leaseHops, "a vouched arrival needs the role")
                await hops.vouch(for: next)
            }
            await granted.record(next)
            try await machine.watchdog.manualControlEngaged(permit, under: next)
            await machine.watchdog.commandedTarget(
                CommandedTarget(fanIndex: 0, rpm: 2_000), under: next)
        } catch {
            Issue.record("the newer lease's arrival failed: \(error)")
        }
    }

    /// What every scenario here asserts last: the newer lease's record is exactly as it
    /// registered it, nothing was handed back, and nothing was marked on its fan.
    static func expectNewerLeaseUntouched<Writes>(
        _ machine: ReclamationMachine<Writes>, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        #expect(
            await machine.watchdog.fansUnderManualControl == [0],
            "§ 5 forgot the newer lease's record", sourceLocation: sourceLocation)
        #expect(
            await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000,
            "§ 5 wrote the old lease's target into the newer lease's record",
            sourceLocation: sourceLocation)
        #expect(
            await machine.didRestore(fan: 0) == false, "§ 5 handed back the newer lease's fan",
            sourceLocation: sourceLocation)
        #expect(
            await machine.ledger.causes.isEmpty, "§ 5 marked the newer lease's fan",
            sourceLocation: sourceLocation)
        #expect(
            await machine.restorer.causes.contains(.systemReclaimed) == false,
            "a lease was revoked blaming the system", sourceLocation: sourceLocation)
    }

    // MARK: - The lease hop (#344)

    /// How the record changes while the lease answer is held open.
    enum DuringTheLeaseCheck: Sendable, CaseIterable {
        /// A late release notice drops it.
        case released
        /// A newer lease registers the fan.
        case regranted
    }

    /// **#344.** The fan's lease ended and § 5 was never told, so the lease core's answer is a
    /// true `false`; it is held open, and the record changes before § 5 resumes. Acting on that
    /// answer would restore a fan a second time (released) or restore and forget on behalf of a
    /// lease whose record is no longer there (regranted); § 5 stops instead, at the lease check.
    ///
    /// Behaviourally the identity half is masked: a presence-only re-fetch lets the examination
    /// on, and `restoreAndForget`'s own identity check then declines to touch the newer record. So
    /// the log is what discriminates, as it does for the read.
    ///
    /// **Mutation (identity):** make the re-fetch after `leases.hasLiveLease` in
    /// `examine(fanAt:)` check presence only — `guard registry.record(ofFan: index) != nil, let
    /// fan = registry.record(ofFan: index)`. Run: red on the regranted case's log assertions.
    /// **Mutation (absence):** replace the whole guard with `let fan = registry.record(ofFan:
    /// index) ?? HeldFan.registering(lease, over: nil)`. Run: red on the released case, which
    /// restores the fan a second time.
    @Test(
        "A record that changes during the lease check stops the examination there",
        arguments: DuringTheLeaseCheck.allCases)
    func aRecordChangedDuringTheLeaseCheckStopsTheExamination(
        arrival: DuringTheLeaseCheck
    ) async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)], parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try Self.permit(machine)
        await machine.endLease()
        let answered = await hops.answers.count
        await hops.parkNextAnswer()
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(await yieldUntil("the lease answer to park") { await hops.isParked })

        let granted = GrantedLeases()
        switch arrival {
        case .released:
            await machine.watchdog.manualControlReleased(fanAt: 0)
        case .regranted:
            await Self.arrive(.granted, machine: machine, permit: permit, granted: granted)
        }
        await hops.release()
        try await finished("the examination", sweep)

        let answers = await hops.answers
        #expect(
            answers.indices.contains(answered) && answers[answered] == false,
            "the parked answer was not the false one")
        #expect(machine.safetyLog.lines(containing: "during the lease check").count == 1)
        #expect(
            machine.safetyLog.lines(containing: leaseLapsedNotice).isEmpty,
            "the examination went on to hand back a fan on the strength of the parked answer")
        #expect(await machine.didRestore(fan: 0) == false, "the fan was restored a second time")
        #expect(await machine.restorer.causes.contains(.systemReclaimed) == false)
        if arrival == .regranted {
            let next = try #require(await granted.ids.first)
            await Self.expectNewerLeaseUntouched(machine)
            #expect(await machine.leases.activeLease()?.id == next, "the newer lease was revoked")
        } else {
            #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        }
    }

    // MARK: - The re-assert's suspensions

    /// **The envelope read.** A newer lease registers fan 0 while § 5's re-assert reads the
    /// envelope. § 5 stops there, before it takes the fan off automatic control for a lease that
    /// no longer holds it.
    ///
    /// `granted`, the engagement driver would refuse the old lease anyway, so the log is what
    /// discriminates (and `left fan 0 alone`, which only the later, identity-checked exits write).
    /// `vouched`, the driver finds the old lease live, and a presence-only re-fetch lets the mode
    /// write land on the newer lease's fan.
    ///
    /// **Mutation:** make the re-fetch after `sensing.readEnvelope` in `reassert` check presence
    /// only — `guard registry.record(ofFan: index) != nil`. Run: red on the log, and on the mode
    /// write when `vouched`.
    @Test(
        "A record registered under a new lease during the envelope read is left to it",
        arguments: NewerLease.allCases)
    func aRecordRegisteredUnderANewLeaseDuringTheEnvelopeReadIsLeftToIt(
        how: NewerLease
    ) async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing,
            parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try Self.permit(machine)
        let granted = GrantedLeases()
        await sensing.interfere { [machine] in
            await Self.arrive(how, machine: machine, permit: permit, granted: granted)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await granted.ids.count == 1)
        #expect(
            machine.safetyLog.lines(containing: "during its envelope read").count == 1,
            "the re-assert went past the envelope read")
        #expect(
            await machine.attempts.contains(.engageManualControl(fan: 0)) == false,
            "§ 5 took the newer lease's fan off automatic control")
        #expect(await machine.commandedRPMs.isEmpty, "§ 5 commanded the newer lease's fan")
        #expect(machine.safetyLog.lines(containing: "left fan 0 alone").isEmpty)
        await Self.expectNewerLeaseUntouched(machine)
    }

    /// **The first write**, which the issue says no existing moment reaches. The mode write has
    /// landed, and before § 5 resumes a newer lease holds fan 0's record. The old lease's target
    /// must not be written onto it: § 5 hands the fan to the newer lease's record and stops.
    ///
    /// It can only be `vouched`. The engagement driver asks the real lease core about the old
    /// lease after the write, and a lease that had really ended is refused there; the instant
    /// between the driver's last answer and § 5 resuming is what this builds the state of.
    ///
    /// **Mutation:** make the re-fetch after `driver.engageManualControl` in `reassert` check
    /// presence only — `guard registry.record(ofFan: index) != nil`. Run: red on the command
    /// assertion, and on the "first write" log.
    @Test("A record registered under a new lease during the first write is left to it")
    func aRecordRegisteredUnderANewLeaseDuringTheFirstWriteIsLeftToIt() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .engageWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing,
            parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try Self.permit(machine)
        let granted = GrantedLeases()
        await sensing.interfere { [machine] in
            await Self.arrive(.vouched, machine: machine, permit: permit, granted: granted)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await granted.ids.count == 1)
        #expect(
            await machine.attempts.contains(.engageManualControl(fan: 0)),
            "the mode write never landed, so this is not the first write's gap")
        #expect(
            await machine.commandedRPMs.isEmpty,
            "§ 5 wrote the old lease's target onto the newer lease's fan")
        #expect(machine.safetyLog.lines(containing: "during its first write").count == 1)
        #expect(machine.safetyLog.lines(containing: "left fan 0 alone").count == 1)
        #expect(machine.safetyLog.lines(containing: "re-asserted").isEmpty)
        await Self.expectNewerLeaseUntouched(machine)
    }

    // MARK: - The reconnect

    /// **The reconnect.** The helper has been blind to fan 0 for the threshold's worth of cycles,
    /// and the reconnect it attempts is the suspension in which a newer lease registers the fan.
    /// § 5 stops: it does not mark the fan blind, does not restore it, and does not go on to the
    /// terminal action for the old lease.
    ///
    /// **Mutation:** make the re-fetch after `sensing.reconnect()` in `cycleCouldNotSee` check
    /// presence only — `guard registry.record(ofFan: index) != nil`. Run: red on the ledger and
    /// the "cannot read its state" line: a blind mark on the newer lease's fan.
    @Test("A record registered under a new lease during the reconnect is left to it")
    func aRecordRegisteredUnderANewLeaseDuringTheReconnectIsLeftToIt() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 2_400)], stages: [.blind()])
        let sensing = InterferingFanStateSensing(plane, during: .reconnect)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 2_400)], sensing: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try Self.permit(machine)
        let granted = GrantedLeases()
        await sensing.interfere { [machine] in
            await Self.arrive(.granted, machine: machine, permit: permit, granted: granted)
        }

        for _ in 0..<ReclamationLimits.blindCyclesBeforeDivergence {
            await machine.watchdog.cycle()
        }

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        let next = try #require(await granted.ids.first)
        #expect(await machine.attempts.contains(.reconnect))
        #expect(machine.safetyLog.lines(containing: "during the reconnect attempt").count == 1)
        #expect(
            machine.safetyLog.lines(containing: "cannot read its state").isEmpty,
            "the newer lease's fan was given up for the old lease's blindness")
        #expect(await machine.ledger.isSupervisorBlind(fanAt: 0) == false)
        #expect(await machine.leases.activeLease()?.id == next, "the newer lease was revoked")
        await Self.expectNewerLeaseUntouched(machine)
    }
}
