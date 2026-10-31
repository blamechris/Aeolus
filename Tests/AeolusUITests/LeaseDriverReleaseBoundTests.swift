import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// The value `LeaseDriver.releaseFans()` returns for each way its bounded wait can end (#510).
///
/// `LeaseLifecycleTests` pins the **timing** of the bound: a quit is answered when the clock
/// reaches it. This pins the **value** a caller reads there. `ReleaseOutcome.notAnswered` says the
/// release may still be in flight; `nothingHeld` says nothing was held, and `released` says the
/// helper answered. A timeout that returned either of those would tell a caller the fans are back
/// (or were never taken) while a lease may still be live, and every production caller discards
/// the value today, so nothing else would notice (`CLAUDE.md` rule 6).
///
/// Every wait here is on the ledger or the clock, so a driver that never returns is a red at the
/// suite's time limit, not a `swift test` that never exits (`LeaseScene.call`).
@Suite("LeaseDriver.releaseFans: the value of the bounded wait", .timeLimit(.minutes(1)))
struct LeaseDriverReleaseBoundTests {

    /// Takes the fans, parks the helper's reply to `releaseLease`, calls `releaseFans()` on a task
    /// of its own, and returns what it returned once the hand-wound clock reaches the bound.
    ///
    /// The clock is the test's, so the deadline is the instant of the call plus `scene`'s bound,
    /// exactly. The release has reached the helper and the driver's timer is parked on that
    /// deadline before the clock moves, and the call has not returned before it does.
    ///
    /// **The wait for the timer ends if the call returns instead**, so a driver that lets the
    /// caller go before its bound is red at the "still waiting" check below, not at the time limit.
    ///
    /// **Mutation (the timer answers at once):** in `LeaseDriver.outcome(of:until:bound:on:)`,
    /// delete the timer's `clock.sleep(until:)` line. Red at "still waiting before the bound".
    private static func returnedAtTheBound(
        _ scene: LeaseScene, bound: Duration
    ) async throws -> ReleaseOutcome? {
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, .parked)
        let deadline = scene.clock.now.advanced(by: bound)
        let outcome = ResultBox<ReleaseOutcome>()

        let releasing = scene.call { outcome.set(await scene.driver.releaseFans()) }
        await scene.ledger.waitFor { $0.releases == [held.lease.id] }
        await firstOf(
            { await scene.clock.untilParked(at: deadline) },
            { await scene.waitForReturn(of: releasing) })
        await scene.settle()
        #expect(!(await scene.hasReturned(releasing)), "still waiting before the bound")
        #expect(outcome.value == nil)

        scene.clock.advance(to: deadline)
        await scene.waitForReturn(of: releasing)
        let entries = await scene.entries
        #expect(
            entries.index(of: .releaseAnswered(held.lease.id)) == nil,
            "the helper never answered: this is the bound's value, not the release's")
        return outcome.value
    }

    /// **Mutation (timer answers `nothingHeld`):** in `LeaseDriver.outcome(of:until:bound:on:)`,
    /// return `.nothingHeld` from the timer branch. Red at the value, in this test and in
    /// `theDurationIsTheDriversBound`.
    ///
    /// **Mutation (timer answers `released`):** the same, with `.released`. Red at the value.
    ///
    /// **Mutation (a different duration):** the same branch, with
    /// `.notAnswered(within: bound * 2)`. Red at the value.
    ///
    /// **Mutation (the timer never answers):** the same branch resumes nothing. The caller is
    /// never let go, and the test is red on its time limit at the wait for the return, which ends
    /// when cancelled.
    @Test("A release the helper never answers returns notAnswered, within the bound")
    func aReleaseNeverAnsweredIsNotAnswered() async throws {
        let scene = await LeaseScene()

        let outcome = try await Self.returnedAtTheBound(scene, bound: LeaseDriver.releaseBound)

        #expect(outcome == .notAnswered(within: LeaseDriver.releaseBound))
        await scene.finish()
    }

    /// The duration is the bound the driver was built with, not the default's: a driver given
    /// another bound names that one.
    ///
    /// **Mutation (the default, not the driver's):** in the same branch,
    /// `.notAnswered(within: LeaseDriver.releaseBound)`. Green on the default bound above, so only
    /// this is red at the value.
    @Test("The duration notAnswered names is the driver's bound")
    func theDurationIsTheDriversBound() async throws {
        let bound = Duration.seconds(7)
        let scene = await LeaseScene(releaseBound: bound)

        let outcome = try await Self.returnedAtTheBound(scene, bound: bound)

        #expect(outcome == .notAnswered(within: bound))
        #expect(outcome != .notAnswered(within: LeaseDriver.releaseBound))
        await scene.finish()
    }

    /// An answered release returns `released`, with the clock where the test left it: the value is
    /// the helper's answer, not a timeout's.
    ///
    /// **Mutation (the answer is not carried):** in `LeaseDriver.outcome(of:until:bound:on:)`,
    /// resume with `.notAnswered(within: bound)` where the release task resumes with the release's
    /// own outcome. Red at the value, in this test alone.
    @Test("A release the helper answers returns released")
    func anAnsweredReleaseIsReleased() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))

        let outcome = await scene.result { await scene.driver.releaseFans() }

        #expect(outcome == .released)
        #expect(await scene.entries.releases == [held.lease.id])
        #expect(scene.clock.now == scene.start, "answered without the clock moving")
        await scene.finish()
    }

    /// With nothing held, `releaseFans()` returns `nothingHeld` and sends nothing.
    ///
    /// **Mutation (nothing held waits):** in `LeaseDriver.releaseFans`, return `.released` for a
    /// driver with no release to wait for. Red at the value.
    @Test("With nothing held, releaseFans returns nothingHeld and sends no release")
    func nothingHeldIsNothingHeld() async throws {
        let scene = await LeaseScene()

        let outcome = await scene.result { await scene.driver.releaseFans() }

        #expect(outcome == .nothingHeld)
        #expect(await scene.entries.releases.isEmpty, "nothing held sends nothing")
        #expect(await scene.driver.state == .idle)
        await scene.finish()
    }
}
