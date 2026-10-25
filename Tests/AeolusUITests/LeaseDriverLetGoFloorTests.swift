import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// ADR 0015 D5's floor: it marks the driver's last let-go, not only its last stop. A release that
/// answers ahead of an acquisition, a change of which fans are held, sets one before the
/// acquisition starts, or publishes `noRead` while an `apply` is unanswered; and the floor that
/// waits for applies is minted when the last one answers, in any state, a held lease's included.
///
/// Every `apply` that must stay unanswered is parked at the fake helper and answered by hand, so
/// the order is the test's, never a clock's. Each ticket is taken immediately before the event it
/// is compared against.
@Suite(
    "LeaseDriver — the floor at a let-go, and at the last apply's answer in any state",
    .timeLimit(.minutes(1)))
struct LeaseDriverLetGoFloorTests {

    static func isAcquiring(_ state: LeaseDriverState) -> Bool {
        if case .acquiring = state { return true }
        return false
    }

    /// A change of set with nothing unanswered: the report published with `acquiring` carries a
    /// floor a read ticketed before the release answered does not pass. The driver had never
    /// stopped, so without this mint its evidence would still be `anyRead`.
    ///
    /// **Mutation (M1, "no mint at a let-go"):** in `LeaseDriver.releaseAnswered`, delete the
    /// assignment to `evidence`. Run: red at `!admits(before)`, the evidence still `.anyRead`.
    @Test("A change of set's release publishes a floor with acquiring")
    func aChangeOfSetSetsAFloor() async throws {
        let scene = await LeaseScene()
        try #require(await scene.take(try LeaseScene.target([0: 3000])) != nil)
        #expect(await scene.driver.report.automaticEvidence == .anyRead, "it has never stopped")
        await scene.helper.script(.release, .parked)
        await scene.driver.takeFan(1, at: try LeaseDriverPerFanTests.speed(4000))
        await scene.ledger.waitFor { !$0.releases.isEmpty }

        let before = await scene.driver.beginSnapshotRead()
        let mark = await scene.mark()
        await scene.helper.answerParked(.release)
        let report = try #require(
            await scene.firstReport(since: mark, where: Self.isAcquiring))
        let after = await scene.driver.beginSnapshotRead()

        #expect(report.state == .acquiring(fans: [0, 1]), "\(report)")
        #expect(!report.automaticEvidence.admits(before), "a read before the let-go: \(report)")
        #expect(report.automaticEvidence.admits(after), "\(report)")
        await scene.finish()
    }

    /// Lease A over both fans, its `apply` parked; a change to fan 0 alone releases A while that
    /// `apply` is unanswered, so the report published with `acquiring` says `noRead`. Lease B is
    /// granted and its own `apply` answered; A's is still unanswered, so `noRead` is kept through
    /// `held`. When A's `apply` answers, the floor is minted as a new report with `held` unchanged,
    /// and a read ticketed while A's `apply` was unanswered does not pass it.
    ///
    /// **Mutation (M2, "the let-go ignores an unanswered apply"):** in `releaseAnswered`, set
    /// `.readFrom(mintFloor())` whatever `appliesUnanswered` is. Run: red at
    /// `acquiring == .noRead`.
    /// **Mutation (M3, "only a stop mints"):** in `applyAnswered()`, restore
    /// `Self.hasStoppedActing(current)` to the guard. Run: red at the floor's `#require`, once
    /// `LeaseScene.floorBound` has passed with the evidence still `.noRead` beside `held`.
    @Test("A let-go with an apply unanswered says noRead, until the last apply answers in held")
    func anUnansweredApplyHoldsTheLetGoBack() async throws {
        let scene = await LeaseScene()
        let scenario = try await Self.changeOfSetDuringAnApply(in: scene)

        try #require(scenario.acquiring.automaticEvidence == .noRead, "\(scenario.acquiring)")
        try #require(
            await scene.driver.report.automaticEvidence == .noRead,
            "B's apply answered; A's has not")

        let during = await scene.driver.beginSnapshotRead()
        let answered = await scene.mark()
        await scene.helper.answerParked(.apply)
        let published = await scene.firstFloor(since: answered)
        let now = await scene.driver.report
        let report = try #require(published, "minted beside held: \(now)")
        let after = await scene.driver.beginSnapshotRead()

        #expect(report.state.heldLease?.lease.id == scenario.leaseB.lease.id, "\(report)")
        #expect(!report.automaticEvidence.admits(during), "a read before A's apply answered")
        #expect(report.automaticEvidence.admits(after))
        #expect(now == report, "the driver's report is the one it published: \(now)")
        let since = Array(await scene.entries.dropFirst(answered))
        #expect(since.states.isEmpty, "the evidence moved alone: no state was published")
        await scene.finish()
    }

    /// The floor minted beside a held lease moves no ticket across the grant's mark: a read
    /// ticketed before B's grant is still not judged against B, and one ticketed after it still is
    /// (see `LeaseDriver`, "Minting cannot change what `observe(_:readWith:)` decides").
    ///
    /// **Mutations (M1, M2):** red at `.noRead`, before A's `apply` answers: the let-go set
    /// `.anyRead` (M1) or a floor (M2), so no floor is minted beside `held`. **(M3):** red at the
    /// floor's `#require`, once `LeaseScene.floorBound` has passed.
    @Test("A floor minted while a lease is held leaves observe alone")
    func aFloorWhileHeldLeavesObserveAlone() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .now, .parked)
        let scenario = try await Self.changeOfSetDuringAnApply(in: scene, parkingB: true)
        try #require(
            await scene.driver.report.automaticEvidence == .noRead, "A's apply is unanswered")
        let answered = await scene.mark()
        await scene.helper.answerParked(.apply)
        let published = await scene.firstFloor(since: answered)
        let now = await scene.driver.report
        try #require(published != nil, "minted beside held: \(now)")
        let gone = LeaseDriverLossTests.snapshot([], listing: nil)

        await scene.driver.observe(gone, readWith: scenario.beforeGrant)
        #expect(await scene.driver.state.isHeld, "a read from before B's grant proves nothing")
        await scene.driver.observe(gone, readWith: scenario.afterGrant)
        #expect(await scene.driver.state.isLost, "one from after it still ends B")
        await scene.finish()
    }

    // MARK: - Mint (b) on its other legs (#515's panel, completeness S2)

    /// Lease A's `apply` is parked and Auto releases it, so `released` says `noRead`. A `takeFan`
    /// then asks again, its acquire parked, and A's `apply` answers while the driver is
    /// `acquiring`: the floor is minted there, as a report beside `acquiring`.
    ///
    /// **Mutation (mA, "(b) skips acquiring and releasing"):** in `applyAnswered()`, return
    /// before minting while `current` is `.acquiring` or `.releasing`. Run: red at the floor's
    /// `#require` in `answerTheParkedApply`, once `LeaseScene.floorBound` has passed, here and in
    /// `theLastApplyMintsWhileReleasing`.
    @Test("The last apply's answer mints the floor while acquiring")
    func theLastApplyMintsWhileAcquiring() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { $0.applies.count == 1 }
        let stop = await scene.mark()
        await scene.driver.selectAutomatic()
        let stopped = try #require(await scene.firstReport(since: stop) { $0.isReleased })
        try #require(stopped.automaticEvidence == .noRead, "\(stopped)")
        await scene.helper.script(.acquire, .parked)
        await scene.driver.takeFan(0, at: try LeaseDriverPerFanTests.speed(3000))
        await scene.ledger.waitFor { $0.acquires.count == 2 }

        let report = try await Self.answerTheParkedApply(in: scene)

        #expect(report.state == .acquiring(fans: [0]), "\(report)")
        await scene.finish()
    }

    /// Lease A's `apply` is parked and Auto releases it. Lease B is taken over both fans and its
    /// own `apply` answered, so `noRead` is kept through `held`. Fan 1 back on Auto releases B,
    /// the release parked, and A's `apply` answers while the driver is `releasing`.
    ///
    /// **Mutation (mA):** red at the floor's `#require` in `answerTheParkedApply`.
    @Test("The last apply's answer mints the floor while releasing")
    func theLastApplyMintsWhileReleasing() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked)
        let both = try LeaseScene.target([0: 3000, 1: 3000])
        await scene.driver.take(both)
        await scene.ledger.waitFor { $0.applies.count == 1 }
        let stop = await scene.mark()
        await scene.driver.selectAutomatic()
        let stopped = try #require(await scene.firstReport(since: stop) { $0.isReleased })
        try #require(stopped.automaticEvidence == .noRead, "\(stopped)")
        try #require(await scene.take(both) != nil)
        try #require(await scene.driver.report.automaticEvidence == .noRead, "A's is unanswered")
        await scene.helper.script(.release, .parked)
        await scene.driver.releaseFan(1)
        try #require(await scene.driver.state == .releasing, "fan 1 on Auto releases lease B")
        await scene.ledger.waitFor { $0.releases.count == 2 }

        let report = try await Self.answerTheParkedApply(in: scene)

        #expect(report.state == .releasing, "\(report)")
        await scene.finish()
    }

    /// Answers the one parked `apply` and returns the report the driver published when it handled
    /// the answer, required to carry a floor that a read ticketed before the answer does not pass
    /// and one after it does, with the state unchanged, and to be the driver's report then.
    ///
    /// Waits on the published report (`LeaseScene.firstFloor(since:)`), never on `settle()`: the
    /// fake's answer reaches the ledger before the driver has handled it (#519).
    static func answerTheParkedApply(in scene: LeaseScene) async throws -> LeaseDriverReport {
        let state = await scene.driver.state
        let during = await scene.driver.beginSnapshotRead()
        let answered = await scene.mark()
        await scene.helper.answerParked(.apply)
        let published = await scene.firstFloor(since: answered)
        let now = await scene.driver.report
        let report = try #require(published, "minted beside \(state): \(now)")
        #expect(report.state == state, "the state did not move")
        #expect(!report.automaticEvidence.admits(during))
        #expect(report.automaticEvidence.admits(await scene.driver.beginSnapshotRead()))
        #expect(now == report, "the driver's report is the one it published: \(now)")
        return report
    }

    // MARK: - The scenario

    struct ChangeOfSet {
        /// The report published with `acquiring`, after A's release answered.
        let acquiring: LeaseDriverReport
        let leaseB: HeldLease
        /// Taken while B's acquire was parked, when `parkingB`.
        let beforeGrant: LeaseDriver.SnapshotTicket
        /// Taken once B was confirmed.
        let afterGrant: LeaseDriver.SnapshotTicket
    }

    /// Lease A over fans 0 and 1, with its first `apply` parked; then fan 1 back on Auto, which
    /// releases A and acquires lease B over fan 0, whose `apply` is answered at once. With
    /// `parkingB`, B's acquire is parked (the caller scripts it) and answered here.
    static func changeOfSetDuringAnApply(
        in scene: LeaseScene, parkingB: Bool = false
    ) async throws -> ChangeOfSet {
        await scene.helper.script(.apply, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000, 1: 3000]))
        await scene.ledger.waitFor { $0.applies.count == 1 }

        await scene.helper.script(.release, .parked)
        let mark = await scene.mark()
        await scene.driver.releaseFan(1)
        try #require(await scene.driver.state == .releasing, "fan 1 on Auto releases lease A")
        await scene.ledger.waitFor { !$0.releases.isEmpty }
        await scene.helper.answerParked(.release)
        let acquiring = try #require(await scene.firstReport(since: mark, where: Self.isAcquiring))
        if parkingB { await scene.ledger.waitFor { $0.acquires.count == 2 } }
        let beforeGrant = await scene.driver.beginSnapshotRead()
        if parkingB { await scene.helper.answerParked(.acquire) }
        let rest = try LeaseScene.target([0: 3000])
        await LeaseDriverPerFanTests.confirmed(rest, in: scene, since: mark)
        let leaseB = try #require(await scene.driver.state.heldLease)
        let afterGrant = await scene.driver.beginSnapshotRead()
        return ChangeOfSet(
            acquiring: acquiring, leaseB: leaseB, beforeGrant: beforeGrant, afterGrant: afterGrant)
    }
}
