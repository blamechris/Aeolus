import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5's re-assert acts on the fan as it stands when it writes, never on the view it judged
/// before its suspensions ([#381](https://github.com/blamechris/Aeolus/issues/381)).
///
/// Each scenario lands a re-apply under the fan's **own** lease inside one of the re-assert's
/// suspensions, the way level 6's `apply` will (ADR 0014 D6 and A6's contract: engage, register,
/// command, report). The client's write goes through level 6's real `GovernedFanWriter`, straight
/// to the plane, so it never fires the double's moment a second time.
///
/// What each pins, against the mutation it kills:
///
/// - **M1**, the envelope read's re-fetch asking identity only (`isHeld(_:under:)`): A, through its
///   stand-down line, since the first-step re-fetch masks it otherwise; B; H.
/// - **M2**, the first-step re-fetch asking identity only and reading the record's target: G.
/// - **M3**, commanding the target `diverged` read: C.
/// - **M4**, recording § 5's write over any report: D, and the value suite.
/// - **M5**, refunding the attempt on a stand-down: E.
/// - **M7**, stamping the examination at the judgement rather than before the read: H.
/// - **M8**, dropping the generation comparison from `Registry.reassertTarget(ofFan:under:)`: A,
///   B, G and H, and the value suite.
///
/// A, B, C, D, G and H were red at `main` before #381. E was green there by design: it pins the
/// accounting the fix must keep. The registry half, as values, is
/// `ReclamationReassertTargetValueTests`.
@Suite(
    "§ 5's re-assert does not overwrite a re-apply under the same lease", .timeLimit(.minutes(1)))
struct ReclamationReassertViewTests {

    /// What `reclamationReassertLeftToItsEngagement(fan:during:)` says, by moment.
    private static let leftAtTheEnvelopeRead = "held for, during its envelope read"
    private static let leftAtTheFirstStep = "held for, during its first step"

    /// What a re-engage the driver refused says.
    private static let failedReengage = "re-engage manual control of"

    /// Fan 0's permit, minted from its declared condition as the fixture mints one.
    static func permit<Writes>(_ machine: ReclamationMachine<Writes>) throws -> CommandableFan {
        try commandableFan(0, declaring: try #require(machine.fanConditions[0]))
    }

    /// A re-apply under `lease`: optionally engage, optionally register, then command `rpm`
    /// through level 6's writer straight to the plane, and report what was put on the wire.
    static func reapply<Writes>(
        _ machine: ReclamationMachine<Writes>, under lease: UUID, permit: CommandableFan,
        rpm: Double, engaging: Bool = false, registering: Bool = true
    ) async {
        do {
            if engaging { _ = try await machine.plane.engageManualControl(of: permit) }
            if registering { try await machine.watchdog.manualControlEngaged(permit, under: lease) }
            let written = try await GovernedFanWriter(plane: machine.plane)
                .command(towards: rpm, of: permit, since: .zero)
            await machine.watchdog.commandedTarget(written, under: lease)
        } catch {
            Issue.record("the same-lease re-apply failed: \(error)")
        }
    }

    static func lease<Writes>(_ machine: ReclamationMachine<Writes>) async throws -> UUID {
        try #require(await machine.leases.activeLease()).id
    }

    static func firmwareTarget<Writes>(
        _ machine: ReclamationMachine<Writes>
    ) async throws -> Double? {
        let state = try await machine.plane.readControlState(ofFan: 0)
        if case .rpm(let rpm) = state.target { return rpm }
        return nil
    }

    /// **A, the issue's acceptance test.** The firmware holds 1,800 against a commanded 2,400, so
    /// the target diverged. The client re-applies 2,000 under the same lease while § 5 reads the
    /// envelope. § 5 must not command 2,400 over it, and it leaves the mark to the episode: the
    /// next readable cycle reads 2,000 held and clears it.
    ///
    /// **Mutations:** M1, red on the stand-down line only; M8, red on every write assertion.
    @Test("A re-apply during the envelope read is not overwritten (target diverged)")
    func aReapplyDuringTheEnvelopeReadIsNotOverwritten() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await Self.reapply(machine, under: lease, permit: permit, rpm: 2_000)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            await machine.commandedRPMs.last == 2_000,
            "the re-assert commanded its stale target over the re-apply")
        #expect(try await Self.firmwareTarget(machine) == 2_000)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)
        #expect(await machine.commandedRPMs == [2_000], "the re-assert wrote at all")
        #expect(await machine.restorer.causes.isEmpty, "a lease was ended")
        #expect(
            machine.safetyLog.lines(containing: Self.leftAtTheEnvelopeRead).count == 1,
            "the envelope read's re-fetch did not stand the re-assert down")
        #expect(await machine.ledger.isReclaimed(fanAt: 0), "the stand-down decided the mark")

        await machine.watchdog.cycle()

        #expect(
            await machine.ledger.isReclaimed(fanAt: 0) == false,
            "the readable cycle that read the re-apply held left the mark")
        #expect(await machine.commandedRPMs == [2_000], "a held target was re-asserted")
    }

    /// **B, the mode half.** The fan reads automatic: the system took it. The client re-engages
    /// it under the same lease and commands 2,000 while § 5 reads the envelope. § 5 must not try
    /// to engage it a second time, report a failed write, or command over it.
    ///
    /// **Mutations:** M1 and M8, red on the failed re-engage line and the engagement count.
    @Test("A re-engagement during the envelope read is not re-engaged again (mode reclaimed)")
    func aReengagementDuringTheEnvelopeReadIsLeftToIt() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await Self.reapply(
                machine, under: lease, permit: permit, rpm: 2_000, engaging: true)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            machine.safetyLog.lines(containing: Self.failedReengage).isEmpty,
            "a failed re-engage was reported for a fan its own lease had re-engaged")
        let engages = await machine.attempts.filter { $0 == .engageManualControl(fan: 0) }
        #expect(engages.count == 1, "§ 5 tried to engage the fan a second time")
        #expect(await machine.commandedRPMs == [2_000])
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)
        #expect(machine.safetyLog.lines(containing: Self.leftAtTheEnvelopeRead).count == 1)
    }

    /// **C, the re-fetch.** A target reported with no registration, a control loop's tick, while
    /// § 5 reads the envelope. § 5 still re-asserts, but the record's target as it stands.
    ///
    /// **Mutation:** M3. Run: red on the commanded targets, the record and the re-assert line.
    @Test("A target reported during the envelope read is the one re-asserted")
    func aTargetReportedDuringTheEnvelopeReadIsTheOneReasserted() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await Self.reapply(
                machine, under: lease, permit: permit, rpm: 2_000, registering: false)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.commandedRPMs == [2_000, 2_000], "the stale target was re-asserted")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)
        #expect(
            machine.safetyLog.lines(containing: "re-asserted 2000 RPM, attempt 1 of").count == 1)
    }

    /// **D, the record.** A re-apply lands while § 5's own command write is in flight, so the
    /// client's 2,000 lands after § 5's 2,400. § 5 must not record 2,400 over the client's
    /// report, or the next cycle reads 2,000 as diverged and re-asserts 2,400 over it.
    ///
    /// **Mutation:** M4. Run: red on the record after the first cycle, and on the second cycle's
    /// writes and the firmware's target.
    @Test("A report during the command write is not overwritten in the record")
    func aReportDuringTheCommandWriteKeepsTheRecord() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .commandWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await Self.reapply(machine, under: lease, permit: permit, rpm: 2_000)
        }

        await machine.watchdog.cycle()
        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)

        await machine.watchdog.cycle()

        #expect(
            await machine.commandedRPMs == [2_400, 2_000],
            "the next cycle re-asserted the stale target over the client's")
        #expect(try await Self.firmwareTarget(machine) == 2_000)
    }

    /// **E, the budget.** The firmware discards every target write. A re-apply during the first
    /// re-assert's envelope read is that round's write, so the attempt stays spent: the next
    /// re-assert is the second, and the terminal action comes on the cycle it would have.
    ///
    /// **Mutation:** M5, `registry.refundReassertAttempt(ofFan:)` in the envelope read's
    /// stand-down. Run: red on the terminal action's cycle.
    @Test("A re-assert left to a re-apply keeps its attempt spent")
    func aReassertLeftToAReapplyKeepsItsAttemptSpent() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .held(at: 1_800)], stages: [.nominal(targetWrites: .reverted)])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await Self.reapply(machine, under: lease, permit: permit, rpm: 2_000)
        }

        for _ in 0..<ReclamationLimits.reassertAttemptBudget {
            await machine.watchdog.cycle()
        }
        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            machine.safetyLog.lines(containing: "attempt 2 of").count == 1,
            "the attempt the re-apply stood in for was given back")
        #expect(await machine.restorer.causes.contains(.systemReclaimed) == false)

        await machine.watchdog.cycle()

        #expect(
            await machine.restorer.causes.contains(.systemReclaimed),
            "the budget was not spent on the cycle it should have been")
    }

    /// **G, the second re-fetch.** A registration under the same lease lands while § 5's own mode
    /// write is in flight, and the client commands 2,000. § 5 must not command after it, and must
    /// not hand back a fan its own lease holds and watches.
    ///
    /// **Mutations:** M2 and M8. Run: red on the commanded targets and the stand-down line.
    @Test("A registration during the re-assert's own mode write is left to that engagement")
    func aRegistrationDuringTheModeWriteIsLeftToIt() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .engageWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await Self.reapply(machine, under: lease, permit: permit, rpm: 2_000)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.commandedRPMs == [2_000], "§ 5 commanded after the re-apply")
        #expect(await machine.didRestore(fan: 0) == false, "§ 5 handed back its own lease's fan")
        #expect(machine.safetyLog.lines(containing: Self.leftAtTheFirstStep).count == 1)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
    }

    /// **H, where the stamp is taken.** § 5's lease answer is held open after its control-state
    /// read, and the client re-engages the fan under the same lease and commands 2,000 meanwhile.
    /// The reading predates the re-engagement, so § 5 judges the mode reclaimed; the re-assert it
    /// decides on must still stand down, because the stamp was taken before the read.
    ///
    /// **Mutations:** M7, M1 and M8. Run: red on the failed re-engage line and the stand-down line.
    @Test("A re-engagement during the examination's lease check stands the re-assert down")
    func aReengagementDuringTheLeaseCheckStandsTheReassertDown() async throws {
        let machine = ReclamationMachine(
            fans: [0: .automatic(at: 1_800)], parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await hops.parkNextAnswer()
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(await yieldUntil("the lease answer to park") { await hops.isParked })

        await Self.reapply(machine, under: lease, permit: permit, rpm: 2_000, engaging: true)
        await hops.release()
        try await finished("the examination", sweep)

        #expect(
            machine.safetyLog.lines(containing: Self.failedReengage).isEmpty,
            "a failed re-engage was reported for a fan its own lease had re-engaged")
        #expect(await machine.commandedRPMs == [2_000])
        #expect(machine.safetyLog.lines(containing: Self.leftAtTheEnvelopeRead).count == 1)
    }
}
