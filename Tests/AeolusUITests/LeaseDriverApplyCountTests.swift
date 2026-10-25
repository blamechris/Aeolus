import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// #498's S2 bookkeeping: the driver counts every `apply` it sends as unanswered until it answers,
/// across leases, and mints the floor only when the count is back to zero with the driver stopped.
/// Every assertion is on a report the driver published, or on `driver.report` once the answer
/// that would change it has been handled.
@Suite("LeaseDriver — every apply holds the floor back until it answers", .timeLimit(.minutes(1)))
struct LeaseDriverApplyCountTests {

    static func isFloor(_ evidence: LeaseDriverReport.AutomaticEvidence) -> Bool {
        if case .readFrom = evidence { true } else { false }
    }

    /// The first report published after `mark` with the driver `released`.
    static func released(_ scene: LeaseScene, since mark: Int) async throws -> LeaseDriverReport {
        await scene.waitForState(since: mark) { $0.isReleased }
        return try #require(
            Array(await scene.entries.dropFirst(mark)).reports.first { $0.state == .released })
    }

    /// Waits until the ledger shows a floor published after `mark`.
    static func floorPublished(_ scene: LeaseScene, since mark: Int) async {
        await scene.ledger.waitFor { entries in
            Array(entries.dropFirst(mark)).reports.contains { isFloor($0.automaticEvidence) }
        }
    }

    /// Two leases' applies in flight at a stop: Auto during apply 1, a second lease and its
    /// apply 2, Auto again. Apply 1 answers first, with apply 2 still at the helper: no read is
    /// evidence yet.
    ///
    /// **Mutation (O2, "the first answer mints"):** in `LeaseDriver.applyAnswered()`, delete
    /// `appliesUnanswered == 0,`. Run: red at `.noRead` and at `!admits(during)`.
    @Test("The floor waits for every apply, not the first to answer")
    func theFloorWaitsForEveryApply() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { $0.applies.count == 1 }
        let first = await scene.mark()
        await scene.driver.selectAutomatic()
        _ = try await Self.released(scene, since: first)

        await scene.driver.take(try LeaseScene.target([0: 3200]))
        await scene.ledger.waitFor { $0.applies.count == 2 }
        let second = await scene.mark()
        await scene.driver.selectAutomatic()
        let stopped = try await Self.released(scene, since: second)
        #expect(stopped.automaticEvidence == .noRead, "\(stopped)")

        let answered = await scene.mark()
        try #require(await scene.helper.answerOldestParked(.apply), "apply 1 was parked")
        await scene.ledger.waitFor { entries in
            Array(entries.dropFirst(answered)).contains { $0.event.isApplyAnswer }
        }
        await scene.settle()
        let during = await scene.driver.beginSnapshotRead()
        let report = await scene.driver.report
        #expect(
            report.automaticEvidence == .noRead,
            "apply 1 answered, apply 2 is still at the helper: \(report)")
        #expect(!report.automaticEvidence.admits(during))

        let last = await scene.mark()
        await scene.helper.answerParked(.apply)
        await Self.floorPublished(scene, since: last)
        #expect(await scene.driver.report.automaticEvidence.admits(during) == false)
        await scene.finish()
    }

    /// A queued apply, sent when the first one answers, is counted: Auto while it is unanswered
    /// publishes `.noRead`, and the floor follows its answer.
    ///
    /// **Mutation (O16, "the queued apply uncounted"):** in `LeaseDriver.runApplies`, delete the
    /// `appliesUnanswered += 1` before `sending = next`. Run: red at `.noRead`, and in the next
    /// test.
    @Test("A queued apply in flight at a stop holds the floor back")
    func aQueuedApplyHoldsTheFloorBack() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { $0.applies.count == 1 }
        await scene.driver.adjust(try LeaseScene.target([0: 3500]))
        try #require(await scene.helper.answerOldestParked(.apply))
        await scene.ledger.waitFor { $0.applies.count == 2 }

        let mark = await scene.mark()
        await scene.driver.selectAutomatic()
        let stopped = try await Self.released(scene, since: mark)
        #expect(stopped.automaticEvidence == .noRead, "the queued apply is unanswered: \(stopped)")
        let during = await scene.driver.beginSnapshotRead()

        let answered = await scene.mark()
        await scene.helper.answerParked(.apply)
        await Self.floorPublished(scene, since: answered)
        #expect(!(await scene.driver.report.automaticEvidence.admits(during)))
        await scene.finish()
    }

    /// The count balances across a queued apply: with nothing in flight a stop mints at once, and
    /// a later lease's apply in flight at a stop still holds the floor back. A count left negative
    /// would refuse the first floor; one left positive would refuse it too.
    ///
    /// **Mutation (O16):** red at the first stop's floor, the count left at -1.
    @Test("After a queued apply has answered, a stop with nothing in flight mints at once")
    func theCountBalancesAcrossAQueuedApply() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { $0.applies.count == 1 }
        await scene.driver.adjust(try LeaseScene.target([0: 3500]))
        try #require(await scene.helper.answerOldestParked(.apply))
        await scene.ledger.waitFor { $0.applies.count == 2 }
        await scene.helper.answerParked(.apply)
        await scene.waitForState { state in
            if case .held(let held) = state, case .confirmed = held.phase { return true }
            return false
        }

        var mark = await scene.mark()
        await scene.driver.selectAutomatic()
        let first = try await Self.released(scene, since: mark)
        #expect(Self.isFloor(first.automaticEvidence), "nothing in flight, yet no floor: \(first)")

        await scene.helper.script(.apply, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { $0.applies.count == 3 }
        mark = await scene.mark()
        await scene.driver.selectAutomatic()
        let second = try await Self.released(scene, since: mark)
        #expect(second.automaticEvidence == .noRead, "an apply in flight: \(second)")
        let answered = await scene.mark()
        await scene.helper.answerParked(.apply)
        await Self.floorPublished(scene, since: answered)
        await scene.finish()
    }

    /// `scheduleApplies`' second site: a confirmed lease's re-apply in flight at Auto.
    ///
    /// **Mutation (O17, "the re-apply uncounted"):** in `requestApply`'s `.confirmed` arm, start
    /// `runApplies` directly instead of through `scheduleApplies`. Run: red at `.noRead`.
    @Test("A confirmed lease's re-apply in flight at a stop holds the floor back")
    func aReApplyHoldsTheFloorBack() async throws {
        let scene = await LeaseScene()
        try #require(await scene.take(try LeaseScene.target([0: 3000])) != nil)
        await scene.helper.script(.apply, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3500]))
        await scene.ledger.waitFor { $0.applies.count == 2 }

        let mark = await scene.mark()
        await scene.driver.selectAutomatic()
        let stopped = try await Self.released(scene, since: mark)
        #expect(stopped.automaticEvidence == .noRead, "\(stopped)")
        let answered = await scene.mark()
        await scene.helper.answerParked(.apply)
        await Self.floorPublished(scene, since: answered)
        await scene.finish()
    }

    /// An earlier lease's apply still holds a later stop's floor back: lease A's apply parked,
    /// Auto, lease B taken and confirmed, Auto again with A's apply still at the helper.
    @Test("An earlier lease's apply still holds a later stop's floor back")
    func anEarlierLeasesApplyHoldsALaterFloor() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { $0.applies.count == 1 }
        var mark = await scene.mark()
        await scene.driver.selectAutomatic()
        _ = try await Self.released(scene, since: mark)
        try #require(await scene.take(try LeaseScene.target([0: 3000])) != nil)

        mark = await scene.mark()
        await scene.driver.selectAutomatic()
        let second = try await Self.released(scene, since: mark)
        #expect(second.automaticEvidence == .noRead, "lease A's apply is unanswered: \(second)")
        let answered = await scene.mark()
        await scene.helper.answerParked(.apply)
        await Self.floorPublished(scene, since: answered)
        await scene.finish()
    }
}
