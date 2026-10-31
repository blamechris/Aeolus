import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// `take(_:)` is the one call that acquires; `adjust(_:)` only moves a lease that is acquiring or
/// held. A slider wired to `adjust` can therefore never ask for the fans again after a loss, and
/// never retries a refusal.
@Suite("Lease driver: take and adjust", .timeLimit(.minutes(1)))
struct LeaseDriverTakeAdjustTests {

    /// Where a test starts before it adjusts.
    enum Start: String, CaseIterable, Sendable {
        case idle, refused, lost, released
    }

    /// From every state that holds nothing, `adjust` sends nothing and changes nothing. The state
    /// is read straight after each call, which is the moment a call that acquired would already
    /// have moved it to `acquiring`.
    ///
    /// **Mutation (adjust acquires):** in `LeaseDriver.adjust`, make the `.idle, .released,
    /// .refused, .lost` case call `startAcquisition(of: target)`. Red on the state, for each start.
    @Test("adjust from a state that holds nothing sends nothing", arguments: Start.allCases)
    func adjustNeverAcquires(_ start: Start) async throws {
        let scene = await LeaseScene()
        try await Self.reach(start, in: scene)
        let before = await scene.driver.state
        let entriesBefore = await scene.entries

        for rpm in [2500.0, 2600, 2700] {
            await scene.driver.adjust(try LeaseScene.target([0: rpm]))
            #expect(await scene.driver.state == before, "adjust moved \(start) on")
        }

        await scene.settle()
        let entries = await scene.entries
        #expect(entries.acquires.count == entriesBefore.acquires.count, "no acquire from \(start)")
        #expect(entries.applies.count == entriesBefore.applies.count, "no apply from \(start)")
        await scene.finish()
    }

    /// From `refused`, any number of adjusts is no acquire at all: a refusal is not retried at the
    /// pace of a slider.
    @Test("Five adjusts from refused send no acquire")
    func adjustDoesNotRetryARefusal() async throws {
        let scene = await LeaseScene()
        try await Self.reach(.refused, in: scene)

        for rpm in stride(from: 2000.0, through: 2400, by: 100) {
            await scene.driver.adjust(try LeaseScene.target([0: rpm]))
        }

        await scene.settle()
        #expect(await scene.entries.acquires.count == 1, "only the take that was refused")
        #expect(await scene.driver.state == .refused(.thermalEmergencyActive))
        await scene.finish()
    }

    /// From `lost`, a `take` is a new user action: exactly one acquire, and the lease is held
    /// again.
    @Test("take from lost sends exactly one acquire")
    func takeFromLostAcquiresOnce() async throws {
        let scene = await LeaseScene()
        try await Self.reach(.lost, in: scene)
        #expect(await scene.entries.acquires.count == 1)

        try #require(await scene.take(LeaseScene.target([0: 3100])) != nil)

        #expect(await scene.entries.acquires.count == 2, "one acquire for the one take")
        await scene.finish()
    }

    /// Once a quit has begun, a `take` does nothing.
    ///
    /// **Mutation:** in `LeaseDriver.take`, delete `guard !shuttingDown`. Red on the state.
    @Test("No take after shutdown begins")
    func noTakeAfterShutdown() async throws {
        let scene = await LeaseScene()
        try await scene.take(LeaseScene.target([0: 3000]))
        await scene.run { await scene.driver.shutDown() }
        let after = await scene.driver.state

        await scene.driver.take(try LeaseScene.target([0: 3000]))

        #expect(await scene.driver.state == after, "nothing is acquired after a quit began")
        #expect(after == .released)
        await scene.finish()
    }

    // MARK: - While releasing

    /// A `take` while a release is in flight is acquired once it has answered, and an `adjust`
    /// over the same fans refines that `take` rather than starting anything of its own.
    @Test("take while releasing acquires after the release; adjust refines it")
    func takeWhileReleasing() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, .parked)
        await scene.driver.selectAutomatic()
        await scene.ledger.waitFor { $0.releases == [held.lease.id] }

        await scene.driver.take(try LeaseScene.target([0: 4000]))
        let refined = try LeaseScene.target([0: 4200])
        await scene.driver.adjust(refined)
        #expect(await scene.driver.state == .releasing)
        await scene.helper.answerParked(.release)
        await scene.waitForState { state in
            if case .held(let now) = state { now.phase == .confirmed(refined) } else { false }
        }

        let entries = await scene.entries
        let answered = try #require(entries.index(of: .releaseAnswered(held.lease.id)))
        let second = try #require(
            entries.indices.filter { entries[$0].event.isAcquire }.dropFirst().first)
        #expect(answered < second, "acquired once the release answered")
        #expect(entries.applies.last == refined.settings)
        await scene.finish()
    }

    /// An `adjust` while Auto's release is in flight is ignored: nothing was asked for after it,
    /// so nothing is acquired when it answers.
    ///
    /// **Mutation:** in `LeaseDriver.adjust`, make `.releasing` set `wanted = target`
    /// unconditionally. Red on the acquire count and the state.
    @Test("adjust while Auto's release is in flight is ignored")
    func adjustWhileReleasingAfterAuto() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, .parked)
        await scene.driver.selectAutomatic()
        await scene.ledger.waitFor { $0.releases == [held.lease.id] }

        await scene.driver.adjust(try LeaseScene.target([0: 4000]))
        let from = await scene.mark()
        await scene.helper.answerParked(.release)
        await scene.waitForState(since: from) { $0.isReleased || $0.isHeld }
        await scene.settle()

        #expect(await scene.driver.state == .released)
        #expect(await scene.entries.acquires.count == 1)
        await scene.finish()
    }

    // MARK: - Reaching a start

    static func reach(_ start: Start, in scene: LeaseScene) async throws {
        switch start {
        case .idle:
            return
        case .refused:
            await scene.helper.script(.acquire, .refuse(.thermalEmergencyActive))
            await scene.driver.take(try LeaseScene.target([0: 3000]))
            await scene.waitForState { if case .refused = $0 { true } else { false } }
        case .lost:
            let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
            await scene.driver.observe(
                LeaseDriverLossTests.snapshot([], listing: nil, emergency: true),
                readWith: await scene.driver.beginSnapshotRead())
            try #require(await scene.driver.state.isLost)
            await scene.ledger.waitFor { $0.releases == [held.lease.id] }
        case .released:
            try await scene.take(LeaseScene.target([0: 3000]))
            await scene.run { await scene.driver.releaseFans() }
            try #require(await scene.driver.state == .released)
        }
    }
}
