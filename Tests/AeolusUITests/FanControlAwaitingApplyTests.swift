import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// #505: while the driver has stopped acting with an `apply` it sent unanswered (evidence
/// `.noRead`), the control says why Auto is not shown selected, and nothing about the fans. When the
/// evidence moves to `readFrom`, the line goes. Beside a state that acts, or has never acted, it is
/// never given.
///
/// Every screen here lists no lease and shows both fans cleared, and every read is past the floor
/// a real driver minted (`SnapshotTickets.aroundAFloor()`), so the evidence is the only thing that
/// differs between a screen that gives the line and one that does not.
@Suite(
    "FanControlPresentation — why Auto is not shown selected while an apply is unanswered",
    .timeLimit(.minutes(1)))
struct FanControlAwaitingApplyTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport
    typealias StatusLine = FanControlPresentation.StatusLine
    typealias Evidence = LeaseDriverReport.AutomaticEvidence
    typealias Control = AllFansControlPresentation

    /// The line, word for word.
    static let awaiting = StatusLine(
        text: "Waiting for the helper to answer a speed change Aeolus sent.",
        detail: "Auto is not shown as selected while Aeolus waits.")

    /// No lease listed, both fans cleared.
    static let cleared = FanControlAutomaticTests.cleared

    /// Fan 0's presentation over `cleared` read with `ticket`, beside `driver` and `evidence`.
    static func present(
        _ driver: LeaseDriverState, _ evidence: Evidence,
        readWith ticket: LeaseDriver.SnapshotTicket?
    ) throws -> FanControlPresentation {
        try Fixtures.present(
            0, on: Fixtures.screen(cleared, driver: driver, evidence: evidence, readWith: ticket))
    }

    // MARK: - The line, beside a driver that has stopped acting

    /// **Mutation (W2, "missing under noRead"):** in `FanControlPresentation.awaitingApply(_:)`,
    /// answer `nil` for `.noRead`. Run: red at `awaitingApply == awaiting`, for every argument.
    /// **Mutation (W3, "the text changed"):** in `StatusLine.awaitingApply`, change "a speed change"
    /// to "the last speed change". Run: red at the same expectation, for every argument.
    @Test(
        "While an apply is unanswered, every state that stops acting says why, beside its own line",
        arguments: FanControlAutomaticTests.stopped)
    func everyStopSaysWhy(_ driver: LeaseDriverState) async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        let waiting = try Self.present(driver, .noRead, readWith: floor.after)
        let answered = try Self.present(driver, floor.evidence, readWith: floor.after)

        #expect(waiting.awaitingApply == Self.awaiting, "\(driver)")
        #expect(waiting.selection == .unknown, "the line says Auto is not shown: \(driver)")
        #expect(waiting.status != nil, "\(driver)")
        #expect(waiting.status == answered.status, "the event's own line is kept: \(driver)")
        let whole = Self.awaiting.text + " " + (Self.awaiting.detail ?? "")
        #expect(!whole.lowercased().contains("automatic"), "Auto is the segment, not a claim")
    }

    /// The line is about the wait, never about why else Auto is not shown: a read from before the
    /// floor selects nothing too, and gives no line, because nothing is being waited for.
    ///
    /// **Mutation (W1, "shown under readFrom"):** in `FanControlPresentation.awaitingApply(_:)`,
    /// answer `.awaitingApply` for `.readFrom` too. Run: red at both `awaitingApply == nil`, for
    /// every argument.
    @Test(
        "Once a read can be evidence, the line goes, whether or not Auto is then shown",
        arguments: FanControlAutomaticTests.stopped)
    func readFromGivesNoLine(_ driver: LeaseDriverState) async throws {
        let floor = try await SnapshotTickets.aroundAFloor()

        let after = try Self.present(driver, floor.evidence, readWith: floor.after)
        #expect(after.awaitingApply == nil, "a read past the floor: \(driver)")
        #expect(after.selection == .automatic, "the floor is one a read can pass: \(driver)")

        let before = try Self.present(driver, floor.evidence, readWith: floor.before)
        #expect(before.awaitingApply == nil, "a read before the floor: \(driver)")
        #expect(before.selection == .unknown, "\(driver)")
    }

    // MARK: - Never beside a state that acts, or has never acted

    /// Every state of `tag`'s kind that this suite holds to no line: over fan 0 and over fan 1
    /// alone where the kind names fans, and in every phase where it is held. The driver keeps its
    /// evidence through these and mints a floor only on a stop, so `.noRead` beside one of them
    /// says nothing about an `apply` in flight. Exhaustive, with no `default:`.
    static func notStopped(_ tag: Fixtures.DriverTag) throws -> [LeaseDriverState] {
        let target = try LeaseScene.target([0: 3000, 1: 3000])
        switch tag {
        case .idle:
            return [.idle]
        case .acquiring:
            return [.acquiring(fans: [0]), .acquiring(fans: [1])]
        case .held:
            return Fixtures.PhaseTag.allCases.flatMap { phase in
                [[0, 1], [1]].map { fans in
                    Fixtures.held(Fixtures.ours, fans: fans, phase.phase(target))
                }
            }
        case .releasing:
            return [.releasing]
        case .released, .lost, .refused:
            return []
        }
    }

    /// **Mutation (W4, "beside any state"):** in `FanControlPresentation.init(reading:given:)`,
    /// pass `awaitingApply: Self.awaitingApply(inputs.automaticEvidence)` in place of
    /// `claim.awaitingApply`. Run: red here, for every argument.
    @Test(
        "Beside a state that acts, or has never acted, no line, whatever the evidence",
        arguments: [Fixtures.DriverTag.idle, .acquiring, .held, .releasing])
    func noLineBesideAStateThatActs(_ tag: Fixtures.DriverTag) async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        let states = try Self.notStopped(tag)
        #expect(!states.isEmpty, "\(tag)")

        for driver in states {
            let presentation = try Self.present(driver, .noRead, readWith: floor.after)
            #expect(presentation.awaitingApply == nil, "\(driver)")
        }
    }

    /// Why the line is given only beside a stop: a real driver reaches `held` with `.noRead` and
    /// no `apply` unanswered. Lease A's `apply` is parked and Auto releases it, so the stop
    /// publishes `.noRead`; lease B is taken and confirmed; A's `apply` then answers. The evidence
    /// is kept through `held`, and nothing is being waited for.
    ///
    /// **Mutation (W4):** red at `awaitingApply == nil` beside `held`.
    @Test("A held lease can keep noRead after every apply has answered, and gives no line")
    func heldCanOutliveTheWait() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000, 1: 3000]))
        await scene.ledger.waitFor { $0.applies.count == 1 }
        let mark = await scene.mark()
        await scene.driver.selectAutomatic()
        let stopped = try #require(await scene.firstReport(since: mark) { $0.isReleased })
        try #require(stopped.automaticEvidence == .noRead, "A's apply is unanswered: \(stopped)")
        let atTheStop = try Self.present(stopped.state, stopped.automaticEvidence, readWith: nil)
        #expect(atTheStop.awaitingApply == Self.awaiting, "the driver's own stop gives the line")

        try #require(await scene.take(try LeaseScene.target([0: 3000, 1: 3000])) != nil)
        let answered = await scene.mark()
        await scene.helper.answerParked(.apply)
        await scene.ledger.waitFor { entries in
            Array(entries.dropFirst(answered)).contains { $0.event.isApplyAnswer }
        }
        await scene.settle()
        let report = await scene.driver.report
        try #require(report.automaticEvidence == .noRead, "kept through held: \(report)")
        guard case .held = report.state else {
            Issue.record("lease B is held: \(report)")
            await scene.finish()
            return
        }
        let held = try Self.present(report.state, report.automaticEvidence, readWith: nil)
        #expect(held.awaitingApply == nil, "every apply has answered: \(report)")
        await scene.finish()
    }

    // MARK: - The all-fans control

    /// The evidence is the driver's, so every fan gives the same line, and the control says it
    /// once, after the event's own line, naming no fan.
    ///
    /// **Mutation (W5, "the control drops it"):** in `AllFansControlPresentation.init`, gather
    /// only `fan.presentation.status`. Run: red at the `.noRead` lines, for every argument.
    /// **Mutation (W6, "ahead of the event"):** gather `awaitingApply` before `status`. Run: red at
    /// the same expectation. **Mutation (W1):** red at the floor's lines.
    @Test(
        "The control says the wait once, after the event, naming no fan",
        arguments: [Fixtures.DriverTag.released, .lost, .refused])
    func theControlSaysItOnce(_ tag: Fixtures.DriverTag) async throws {
        let snapshot = Support.snapshot(
            fans: [Fixtures.clearedFan(0), Fixtures.clearedFan(1), Fixtures.clearedFan(2)])
        let driver = try tag.state()
        let floor = try await SnapshotTickets.aroundAFloor()
        let control = { (evidence: Evidence) in
            Control(
                fans: AllFansControlPresentationTests.fans(
                    Fixtures.screen(
                        snapshot, driver: driver, evidence: evidence, readWith: floor.after)),
                snapshot: snapshot)
        }
        let event = try #require(
            try Fixtures.present(0, on: Fixtures.screen(snapshot, driver: driver)).status)

        let waiting = control(.noRead)
        #expect(
            waiting.statusLines
                == [.init(fans: nil, value: event), .init(fans: nil, value: Self.awaiting)],
            "\(driver)")
        #expect(waiting.selection == .none, "\(driver)")

        let answered = control(floor.evidence)
        #expect(answered.statusLines == [.init(fans: nil, value: event)], "\(driver)")
        #expect(answered.selection == .automatic, "\(driver)")
    }
}
