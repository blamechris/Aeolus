import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// ADR 0015 D5: while the driver is `held` over fans F, a fan outside F reads Automatic only when
/// a licensed snapshot lists exactly the held lease, by identifier, and no emergency; its read's
/// ticket is admitted by the driver's evidence; and it reports the fan cleared. In `acquiring` and
/// `releasing` such a fan still reads `.unknown`.
///
/// Every refusal here meets every other condition: the held lease over fan 0 listed, no emergency,
/// fan 1 cleared, a licensed snapshot, and a read past a real driver's floor
/// (`SnapshotTickets.aroundAFloor()`), so only the condition under test can refuse it. The positive
/// control shows the rule say yes on that screen.
@Suite(
    "FanControlPresentation — Automatic beside the driver's own held lease (ADR 0015 D5)",
    .timeLimit(.minutes(1)))
struct FanControlUncoveredTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport
    typealias Evidence = LeaseDriverReport.AutomaticEvidence
    typealias Ticket = LeaseDriver.SnapshotTicket
    typealias Control = AllFansControlPresentation

    /// The target the held lease over fan 0 carries.
    static func target() throws -> LeaseTarget { try Fixtures.target([0: 3000]) }

    /// The driver holding `ours` over fan 0, in each phase.
    static func heldStates() throws -> [LeaseDriverState] {
        try Fixtures.PhaseTag.allCases.map {
            Fixtures.held(Fixtures.ours, fans: [0], $0.phase(try target()))
        }
    }

    /// Fan 0 held under `lease`, fan 1 as given (cleared by default).
    static func snapshot(
        listing lease: Lease? = Fixtures.ours, emergency: Bool = false,
        fan1: FanState = Fixtures.clearedFan(1)
    ) -> SystemSnapshot {
        Support.snapshot(
            fans: [Fixtures.heldFan(0), fan1], activeLease: lease,
            isThermalEmergencyActive: emergency)
    }

    /// Fan `index`'s presentation over `snapshot` read with `ticket`, beside `driver` and the
    /// `evidence` published with it.
    static func present(
        _ index: Int, _ driver: LeaseDriverState, _ evidence: Evidence, readWith ticket: Ticket?,
        over snapshot: SystemSnapshot = snapshot()
    ) throws -> FanControlPresentation {
        try Fixtures.present(
            index,
            on: Fixtures.screen(snapshot, driver: driver, evidence: evidence, readWith: ticket))
    }

    // MARK: - The positive control

    /// **Mutation (U0, the positive control):** make `uncoveredClaim` always answer `.unknown`.
    /// Run: red here, so the refusals below can see the rule say yes.
    @Test("The held lease listed, an admitted read, the fan outside it cleared: Automatic")
    func thePositiveControl() async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        for driver in try Self.heldStates() {
            let fan1 = try Self.present(1, driver, floor.evidence, readWith: floor.after)
            #expect(fan1.selection == .automatic, "\(driver)")
            #expect(fan1.status == nil, "\(driver)")
            #expect(fan1.awaitingApply == nil, "\(driver)")
            #expect(!fan1.canRelease, "\(driver): the lease does not cover it")
            // `.anyRead` too: a driver that never let go of a lease.
            let never = try Self.present(1, driver, .anyRead, readWith: nil)
            #expect(never.selection == .automatic, "\(driver)")
        }
    }

    /// The commonest per-fan screen: fan 0 Custom, fan 1 Automatic beside it. The all-fans control
    /// claims no more than each fan does, so it selects nothing.
    @Test("Fan 0 Custom and fan 1 Automatic: the all-fans control selects nothing")
    func customBesideAutomatic() async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        let driver = Fixtures.held(Fixtures.ours, fans: [0], .confirmed(try Self.target()))
        let snapshot = Self.snapshot()
        let screen = Fixtures.screen(
            snapshot, driver: driver, evidence: floor.evidence, readWith: floor.after)

        #expect(
            try Fixtures.present(0, on: screen).selection
                == .custom(try Fixtures.speed(try Self.target(), 0)))
        #expect(try Fixtures.present(1, on: screen).selection == .automatic)
        let control = Control(
            fans: AllFansControlPresentationTests.fans(screen), snapshot: snapshot)
        #expect(control.selection == .none)
        #expect(control.offersRelease, "fan 0 can be given back")
    }

    // MARK: - Condition 1: exactly the held lease, by identifier, and no emergency

    /// Another client's lease, and one whose holder string is ours word for word.
    ///
    /// **Mutation (M4a, "any listed lease"):** red here for both leases (in
    /// `SystemSnapshot.showsAutomatic(_:besideLease:covering:)`).
    /// **Mutation (M14, "by holder"):** in `uncoveredClaim`, pass
    /// `besideLease: snapshot.activeLease.flatMap { $0.holderDescription ==
    /// held.lease.holderDescription ? $0.id : nil } ?? held.lease.id`. Run: red for the impostor.
    @Test(
        "Another lease listed beside the held one, whatever its holder says: nothing selected",
        arguments: [Fixtures.theirs, Fixtures.impostor])
    func anotherLeaseListed(_ listed: Lease) async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        for driver in try Self.heldStates() {
            let fan1 = try Self.present(
                1, driver, floor.evidence, readWith: floor.after,
                over: Self.snapshot(listing: listed))
            #expect(fan1.selection == .unknown, "\(driver)")
        }
    }

    /// No lease listed beside a held one: a read from before the grant, or a loss not yet judged.
    ///
    /// **Mutation (M4b, "no lease or the driver's"):** red here (in the predicate).
    @Test("No lease listed beside the held one: nothing selected")
    func noLeaseListed() async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        for driver in try Self.heldStates() {
            let fan1 = try Self.present(
                1, driver, floor.evidence, readWith: floor.after, over: Self.snapshot(listing: nil))
            #expect(fan1.selection == .unknown, "\(driver)")
        }
    }

    /// **Mutation (M6, "no emergency check"):** red here (in the predicate).
    @Test("The held lease listed during a thermal emergency: nothing selected")
    func anEmergency() async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        for driver in try Self.heldStates() {
            let fan1 = try Self.present(
                1, driver, floor.evidence, readWith: floor.after,
                over: Self.snapshot(emergency: true))
            #expect(fan1.selection == .unknown, "\(driver)")
        }
    }

    // MARK: - Condition 2: the read's timing

    /// A read from before the floor, a read with no ticket, and any read while an `apply` is
    /// unanswered. Only the ticket and the evidence differ from the positive control.
    ///
    /// **Mutation (M7, "no admits in the uncovered arm"):** delete
    /// `inputs.automaticEvidence.admits(inputs.renderedReadTicket)` from `uncoveredClaim`. Run: red
    /// at all three, for every phase.
    @Test("A read the evidence does not admit: nothing selected")
    func aReadNotAdmitted() async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        for driver in try Self.heldStates() {
            let early = try Self.present(1, driver, floor.evidence, readWith: floor.before)
            #expect(early.selection == .unknown, "before the floor: \(driver)")
            let unticketed = try Self.present(1, driver, floor.evidence, readWith: nil)
            #expect(unticketed.selection == .unknown, "no ticket: \(driver)")
            let waiting = try Self.present(1, driver, .noRead, readWith: floor.after)
            #expect(waiting.selection == .unknown, "an apply unanswered: \(driver)")
        }
    }

    // MARK: - Condition 3: the fan cleared

    /// **Mutation (M8, "no clearance check"):** red here for every argument (in the predicate).
    @Test(
        "A fan outside the lease the helper has not cleared: nothing selected",
        arguments: FanRowModelTests.notClearing)
    func anUnclearedFan(_ reason: ManualControlAvailability.Reason) async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        let fan1 = Support.fan(1, mode: .automatic, availability: .unavailable(reason))
        for driver in try Self.heldStates() {
            let presented = try Self.present(
                1, driver, floor.evidence, readWith: floor.after, over: Self.snapshot(fan1: fan1))
            #expect(presented.selection == .unknown, "\(reason), \(driver)")
        }
    }

    // MARK: - A covered fan never reaches D5

    /// Fan 0, which the lease covers, reads cleared, as it does before its first `apply` lands;
    /// every D5 condition holds for it but coverage. It is the held claim's, never Automatic.
    ///
    /// **Mutation (M5b, "the arm order"):** in `claim`, move the `.held(let held)` arm for a fan
    /// the lease does not cover above the one for a fan it covers. Run: red at both phases'
    /// selections (the predicate's `covering` check then answers `.unknown`, and without it,
    /// `.automatic`).
    @Test("A fan the held lease covers is the held claim's, never D5's")
    func aCoveredFanIsTheHeldClaims() async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        let target = try Self.target()
        let snapshot = Support.snapshot(
            fans: [Fixtures.clearedFan(0), Fixtures.clearedFan(1)], activeLease: Fixtures.ours)

        let applying = try Self.present(
            0, Fixtures.held(Fixtures.ours, fans: [0], .applying(target, queued: nil)),
            floor.evidence, readWith: floor.after, over: snapshot)
        #expect(applying.selection == .applying(try Fixtures.speed(target, 0)))
        #expect(applying.status?.text == "Asked the helper for 3000 RPM. Not confirmed yet.")

        let confirmed = try Self.present(
            0, Fixtures.held(Fixtures.ours, fans: [0], .confirmed(target)), floor.evidence,
            readWith: floor.after, over: snapshot)
        #expect(confirmed.selection == .unknown, "not held in the snapshot: no Custom either")
        #expect(
            confirmed.status?.text
                == "Not confirmed: the helper's snapshot does not show this lease holding its fans."
        )
    }

    // MARK: - Acquiring and releasing keep `.unknown`

    /// The snapshot lists the driver's lease, as one read after a grant the driver has not yet
    /// processed, or before a release it has sent, would. Every D5 condition but the state holds.
    ///
    /// **Mutation (M9, "the uncovered arm in acquiring and releasing"):** in `claim`'s
    /// `.acquiring` and `.releasing` arms, answer `.automatic` when the licensed snapshot lists a
    /// lease, the read is admitted, and `showsAutomatic([state], besideLease: listed.id, covering:
    /// fans)` (`[]` while releasing) holds. Run: red at both states.
    @Test("Acquiring or releasing, a fan outside the request reads nothing, with no wait line")
    func acquiringAndReleasingKeepUnknown() async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        let snapshot = Self.snapshot()
        for driver in [LeaseDriverState.acquiring(fans: [0]), .releasing] {
            let fan1 = try Self.present(1, driver, floor.evidence, readWith: floor.after)
            #expect(fan1.selection == .unknown, "\(driver)")
            let waiting = try Self.present(
                1, driver, .noRead, readWith: floor.after, over: snapshot)
            #expect(waiting.awaitingApply == nil, "\(driver): the line is held's and stopped's")
        }
    }

    // MARK: - The wait line

    /// Under `.noRead` beside a held lease, an `apply` is unanswered since the last let-go, so a
    /// fan the lease does not cover gives the line, and the covered fan, which says what is being
    /// applied, does not.
    ///
    /// **Mutation (W7, "no line for an uncovered fan"):** in `uncoveredClaim`, pass
    /// `awaitingApply: nil`. Run: red at the uncovered fan's line, for every phase.
    @Test("Beside a held lease, a fan it does not cover says the wait; the covered fan does not")
    func theWaitBesideAHeldLease() async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        for driver in try Self.heldStates() {
            let waiting = try Self.present(1, driver, .noRead, readWith: floor.after)
            #expect(waiting.awaitingApply == FanControlAwaitingApplyTests.awaiting, "\(driver)")
            #expect(waiting.status == nil, "\(driver)")
            let covered = try Self.present(0, driver, .noRead, readWith: floor.after)
            #expect(covered.awaitingApply == nil, "\(driver)")
            let answered = try Self.present(1, driver, floor.evidence, readWith: floor.after)
            #expect(answered.awaitingApply == nil, "\(driver)")
        }
    }

    /// The all-fans control names the fans that give the wait, as it names any line only some
    /// fans give.
    @Test("The all-fans control names the uncovered fan beside the wait")
    func theControlNamesTheWait() async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        let driver = Fixtures.held(
            Fixtures.ours, fans: [0], .applying(try Self.target(), queued: nil))
        let snapshot = Self.snapshot()
        let screen = Fixtures.screen(
            snapshot, driver: driver, evidence: .noRead, readWith: floor.after)
        let control = Control(
            fans: AllFansControlPresentationTests.fans(screen), snapshot: snapshot)

        let asked = FanControlPresentation.StatusLine(
            text: "Asked the helper for 3000 RPM. Not confirmed yet.", detail: nil)
        #expect(
            control.statusLines
                == [
                    .init(fans: ["Fan 0"], value: asked),
                    .init(fans: ["Fan 1"], value: FanControlAwaitingApplyTests.awaiting),
                ])
    }

    // MARK: - With a real driver

    /// Both fans held; fan 1 back on Auto releases the lease and acquires one over fan 0. The
    /// report the driver publishes then admits a read ticketed after the release answered, and not
    /// one ticketed before, so fan 1 reads Automatic only from the later read, which lists the new
    /// lease.
    @Test("After per-fan Auto, the other fan reads Automatic only from a read after the let-go")
    func afterPerFanAuto() async throws {
        let scene = await LeaseScene()
        try #require(await scene.take(try LeaseScene.target([0: 3000, 1: 3200])) != nil)
        await scene.helper.script(.release, .parked)
        await scene.driver.releaseFan(1)
        await scene.ledger.waitFor { !$0.releases.isEmpty }
        let before = await scene.driver.beginSnapshotRead()
        let mark = await scene.mark()
        await scene.helper.answerParked(.release)
        let rest = try LeaseScene.target([0: 3000])
        await LeaseDriverPerFanTests.confirmed(rest, in: scene, since: mark)
        let report = await scene.driver.report
        let after = await scene.driver.beginSnapshotRead()
        let leaseB = try #require(report.state.heldLease?.lease)
        let snapshot = Self.snapshot(listing: leaseB)

        let early = try Self.present(
            1, report.state, report.automaticEvidence, readWith: before, over: snapshot)
        #expect(early.selection == .unknown, "a read before the let-go: \(report)")
        let late = try Self.present(
            1, report.state, report.automaticEvidence, readWith: after, over: snapshot)
        #expect(late.selection == .automatic, "\(report)")
        let fan0 = try Self.present(
            0, report.state, report.automaticEvidence, readWith: after, over: snapshot)
        #expect(fan0.selection == .custom(try Fixtures.speed(rest, 0)))
        await scene.finish()
    }
}
