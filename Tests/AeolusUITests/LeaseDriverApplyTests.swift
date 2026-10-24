import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// What the driver asks for and sends: the request itself, one `apply` at a time with the latest
/// target queued, Auto as a release sent at once, and a change of fans as release, acquire, apply.
@Suite("Lease driver: the request and its applies", .timeLimit(.minutes(1)))
struct LeaseDriverApplyTests {

    // MARK: - The request

    /// The app's lease is a heartbeat lease, never a self-renewing one: `CLAUDE.md` rule 2's
    /// "persist across quit" is the helper's to offer, and the app does not ask for it.
    ///
    /// **Mutation (self-renewing):** in `LeaseDriver.acquire`, pass `isSelfRenewing: true`. Red.
    @Test(
        "The request is Aeolus.app's, at the default TTL, and never self-renewing"
    )
    func theRequest() async throws {
        let scene = await LeaseScene()
        await scene.driver.take(try LeaseScene.target([1: 4000, 0: 3000]))
        await scene.ledger.waitFor { !$0.acquires.isEmpty }

        let request = try #require(await scene.entries.acquires.first)
        #expect(request.isSelfRenewing == false)
        #expect(request.holderDescription == LeaseScene.holder)
        #expect(request.fanIndices == [0, 1])
        #expect(request.timeToLive == Lease.defaultTimeToLive)
        await scene.finish()
    }

    @Test("The holder is Aeolus.app and its short version")
    func theHolderDescription() {
        #expect(LeaseDriver.holderDescription(shortVersion: "0.3.0") == "Aeolus.app 0.3.0")
        #expect(LeaseDriver.holderDescription(shortVersion: nil) == "Aeolus.app")
        #expect(LeaseDriver.holderDescription(shortVersion: "") == "Aeolus.app")
    }

    @Test("A target over no fans cannot be made, and its settings are fixed speeds in fan order")
    func theTarget() throws {
        #expect(LeaseTarget(speeds: [:]) == nil)
        let target = try LeaseScene.target([1: 4000, 0: 3000])
        #expect(target.fans == [0, 1])
        #expect(
            target.settings == [
                FanSetting(fanIndex: 0, control: .fixed(rpm: 3000)),
                FanSetting(fanIndex: 1, control: .fixed(rpm: 4000)),
            ])
    }

    // MARK: - One apply in flight

    /// While an `apply` is in flight, newer targets over the same fans replace one another in the
    /// queue and nothing is sent until it answers; then only the latest is sent.
    ///
    /// **Mutation (send immediately):** in `LeaseDriver.requestApply`, make the `.applying` case
    /// do what the `.confirmed` case does. Red on the applies sent and on how many were in flight.
    @Test("One apply in flight, and the latest target wins")
    func oneApplyInFlightLatestWins() async throws {
        let scene = await LeaseScene()
        let first = try LeaseScene.target([0: 2000])
        let second = try LeaseScene.target([0: 3000])
        let latest = try LeaseScene.target([0: 4000])
        await scene.helper.script(.apply, .parked)
        await scene.driver.take(first)
        await scene.ledger.waitFor { $0.applies.count == 1 }

        await scene.driver.take(second)
        await scene.driver.take(latest)
        if case .held(let held) = await scene.driver.state {
            #expect(held.phase == .applying(first, queued: latest))
        } else {
            Issue.record("not held while the first apply is in flight")
        }

        await scene.helper.answerParked(.apply)
        await scene.ledger.waitFor { entries in
            entries.applies.count >= 3
                || entries.filter({ $0.event.isApplyAnswer }).count >= 2
                || entries.states.contains { state in
                    if case .held(let held) = state {
                        held.phase == .confirmed(latest)
                    } else {
                        false
                    }
                }
        }

        #expect(await scene.entries.applies == [first.settings, latest.settings])
        #expect(await scene.helper.mostAppliesAtOnce == 1, "nothing was sent concurrently")
        #expect(await scene.entries.acquires.count == 1, "a re-apply under the same lease")
        await scene.finish()
    }

    // MARK: - Auto

    /// Auto is a release, sent at once even while an `apply` is in flight, and the `apply` is left
    /// to answer rather than cancelled (#419).
    ///
    /// **Mutation (wait for the apply first):** in `LeaseDriver.beginRelease`, start the release
    /// only once the `apply` in flight has answered. The release is never sent while the `apply`
    /// is parked, and the test is red on its time limit at the wait for that release: the `apply`
    /// it would wait for is answered only after it.
    @Test("Auto during an apply releases immediately")
    func autoDuringAnApplyReleasesImmediately() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.applies.isEmpty }
        let lease = try #require(await scene.helper.heldLeases.values.first)

        await scene.driver.selectAutomatic()
        await scene.ledger.waitFor { $0.releases == [lease.id] }
        #expect(await scene.entries.releases == [lease.id], "the release was sent")

        #expect(
            await scene.entries.index(where: \.isApplyAnswer) == nil,
            "released while the apply was still outstanding")
        await scene.helper.answerParked(.apply)
        await scene.ledger.waitFor { $0.index(where: \.isApplyAnswer) != nil }
        let answered = await scene.entries.compactMap { entry -> Bool? in
            if case .applyAnswered(_, let cancelled) = entry.event { cancelled } else { nil }
        }
        #expect(answered == [false], "the apply was left to answer, never cancelled")
        await scene.waitForState { $0.isReleased }
        await scene.finish()
    }

    /// Auto with nothing in flight: the release, then `released`.
    @Test("Auto releases, and nothing is held afterwards")
    func autoReleases() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))

        await scene.driver.selectAutomatic()
        await scene.waitForState { $0.isReleased }

        #expect(await scene.entries.releases == [held.lease.id])
        #expect(await scene.helper.heldLeases.isEmpty)
        await scene.finish()
    }

    // MARK: - A change of fans

    /// A change to which fans are held is a release, then an acquire, then an apply, in that
    /// order: the acquire is sent only once the release has answered.
    @Test("A change of fans is release, then acquire, then apply")
    func aChangeOfFans() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        let wider = try LeaseScene.target([0: 3000, 1: 3000])

        try #require(await scene.take(wider) != nil)

        let entries = await scene.entries
        let released = try #require(entries.index(of: .releaseAnswered(held.lease.id)))
        let acquired = try #require(
            entries.index {
                if case .acquire(let request) = $0 { request.fanIndices == [0, 1] } else { false }
            })
        let applied = try #require(
            entries.index(of: .apply(wider.settings, lease: entries.lastGrant)))
        #expect(released < acquired && acquired < applied)
        await scene.finish()
    }
}

extension [LeaseLedger.Entry] {

    /// The lease the last apply was sent under.
    var lastGrant: UUID {
        for entry in reversed() {
            if case .apply(_, let lease) = entry.event { return lease }
        }
        return UUID()
    }
}
