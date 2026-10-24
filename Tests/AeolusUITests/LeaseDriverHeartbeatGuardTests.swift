import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// The heartbeat's guards: it ends with every lease, a wake replaces it rather than doubling it,
/// a cancelled renewal is not a loss, and a renewal is stamped before it is sent and answered for
/// the lease it renewed. Each test names the mutation that turns it red.
@Suite("Lease driver: the heartbeat's guards", .timeLimit(.minutes(1)))
struct LeaseDriverHeartbeatGuardTests {

    typealias Loss = LeaseDriverLossTests

    /// A wake while a renewal is in flight cancels that renewal, and its cancellation is not a
    /// loss: `systemDidWake()` returns once the replaced beat has finished, and the lease is still
    /// held.
    ///
    /// **Mutation:** in `LeaseDriver.beat`, delete `if !Task.isCancelled` before the renewal's
    /// `lose`. Red on the state.
    @Test("A renewal cancelled by a wake is not a loss")
    func aWakeCancelledRenewalIsNotALoss() async throws {
        let scene = await LeaseScene()
        try await scene.take(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { !$0.isEmpty }
        await scene.helper.script(.renew, .parked)
        scene.clock.advance(to: scene.at(.seconds(10)))
        await scene.ledger.waitFor { $0.renewals.count == 1 }

        await scene.run { await scene.driver.systemDidWake() }

        #expect(await scene.driver.state.isHeld, "the cancelled renewal ended the lease")
        #expect(await scene.entries.lost == nil)
        await scene.ledger.waitFor { $0.renewals.count == 2 }
        await scene.finish()
    }

    /// A wake replaces the heartbeat: one beat afterwards, not two.
    ///
    /// **Mutation:** in `LeaseDriver.startHeartbeat`, delete `heartbeat?.cancel()`. The beat it
    /// replaced stays parked at 10 s: red on the parked deadlines.
    @Test("A wake leaves one heartbeat")
    func aWakeLeavesOneHeartbeat() async throws {
        let scene = await LeaseScene()
        try await scene.take(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { !$0.isEmpty }
        scene.clock.advance(to: scene.at(.seconds(5)))

        // Not awaited: a driver that left the old beat running would wait on it here.
        let waking = scene.call { await scene.driver.systemDidWake() }
        let next = scene.at(.seconds(15))
        await scene.clock.untilParked { $0.contains(next) }

        #expect(scene.clock.parked == [next], "one heartbeat after the wake")
        _ = waking
        await scene.finish()
    }

    /// A renewal that takes 3 s does not make the next one late: stamped before it is sent, the
    /// heartbeat re-arms at 20 s, not at 23 s.
    ///
    /// **Mutation:** in `LeaseDriver.beat`, take `renewedAt = clock.now` after the renewal
    /// answers. Red on the parked deadline.
    @Test("A slow renewal does not make the next one late")
    func aSlowRenewal() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.renew, .after(.seconds(3)))
        try await scene.take(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { !$0.isEmpty }
        scene.clock.advance(to: scene.at(.seconds(10)))
        let answered = scene.at(.seconds(13))
        await scene.clock.untilParked(at: answered)
        scene.clock.advance(to: answered)
        await scene.clock.untilParked { $0.contains { $0 > answered } }

        #expect(scene.clock.parked == [scene.at(.seconds(20))])
        await scene.finish()
    }

    /// The five ways a lease ends that a test can bring about.
    static let ends = ["snapshot", "refused apply", "health", "Auto", "release"]

    /// Every way a lease ends stops its heartbeat, at once: nothing stays parked on the clock. A
    /// parked sleep is removed the moment it is cancelled, so this is read straight after the end.
    ///
    /// **Mutation (Y7):** in `LeaseDriver.endLease`, delete `heartbeat?.cancel()`. **(Y9):** Y7,
    /// and delete the `isHeld` guard in `beat`. Red on every end, under both.
    @Test("Every end stops the heartbeat", arguments: Self.ends)
    func everyEndStopsTheHeartbeat(_ end: String) async throws {
        let scene = await LeaseScene()
        try await Self.hold(endingBy: end, in: scene)

        await Self.end(by: end, in: scene)

        #expect(scene.clock.parked.isEmpty, "the beat of a lease that ended is gone (\(end))")
        await scene.finish()
    }

    /// Every way a lease ends ends its health watch too. A cancelled watch lets go at once, so
    /// four of the ends are read straight after; a health loss ends the watch from inside it, as
    /// the watch returns, so that one is waited for.
    ///
    /// **Mutation (Y8):** in `LeaseDriver.endLease`, delete `healthWatch?.cancel()`. Red on
    /// snapshot, refused apply, Auto and release. **Mutation:** move the cancel from `endLease`
    /// into `beginRelease`. Red on snapshot and refused apply.
    @Test("Every end stops the health watch", arguments: Self.ends)
    func everyEndStopsTheHealthWatch(_ end: String) async throws {
        let scene = await LeaseScene()
        try await Self.hold(endingBy: end, in: scene)
        #expect(scene.helper.health.live == 1)

        await Self.end(by: end, in: scene)

        if end == "health" { await scene.helper.health.untilLive(0) }
        #expect(scene.helper.health.live == 0, "the watch outlived its lease (\(end))")
        await scene.finish()
    }

    /// A lease held, its heartbeat armed and its health watched, ready to be ended by `end`.
    static func hold(endingBy end: String, in scene: LeaseScene) async throws {
        if end == "refused apply" { await scene.helper.script(.apply, .parked) }
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        if end == "refused apply" {
            await scene.ledger.waitFor { !$0.applies.isEmpty }
        } else {
            await scene.waitForState {
                if case .held(let held) = $0 { held.isConfirmed } else { false }
            }
        }
        await scene.clock.untilParked { !$0.isEmpty }
        await scene.ledger.waitFor { $0.healthAsks >= 2 }
    }

    /// Ends the lease held by `end`.
    static func end(by end: String, in scene: LeaseScene) async {
        switch end {
        case "snapshot":
            await scene.driver.observe(
                Loss.snapshot([], listing: nil), readWith: await scene.driver.beginSnapshotRead())
        case "refused apply":
            await scene.helper.answerParked(
                .apply, throwing: AeolusXPCFault.manualControlUnavailable(reason: .supervisorBlind))
            await scene.waitForState { $0.isLost }
        case "health":
            await scene.helper.pushHealth(.interrupted)
            await scene.waitForState { $0.isLost }
        case "Auto":
            await scene.driver.selectAutomatic()
        default:
            await scene.run { await scene.driver.releaseFans() }
        }
    }

    /// The guard before a renewal is sent stops a beat whose sleep ended normally after the lease
    /// did: no renewal goes out for a lease no longer held. The clock's sleeps ignore cancellation
    /// here, so the beat's sleep returns at its deadline as one that had already ended would.
    ///
    /// **Mutation:** in `LeaseDriver.beat`, delete the guard before `renewedAt = clock.now`. Red on
    /// the renewals.
    @Test("No renewal is sent for a lease that ended while the beat slept")
    func noRenewalAfterTheLeaseEnded() async throws {
        let scene = await LeaseScene()
        scene.clock.ignoreCancellation()
        try await scene.take(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { $0.contains(scene.at(.seconds(10))) }
        let beat = try #require(await scene.driver.runningHeartbeat)
        await scene.driver.selectAutomatic()
        await scene.waitForState { $0.isReleased }

        scene.clock.advance(to: scene.at(.seconds(10)))
        // The beat has finished when this returns, whatever it did.
        await scene.run { await beat.finished() }

        #expect(await scene.entries.renewals.isEmpty, "a renewal went out for a released lease")
        await scene.finish()
    }

    /// The held lease is the one the helper last renewed, so its `expiresAt` is the helper's
    /// latest word; a renewal answered with another lease ends this one.
    ///
    /// **Mutation:** in `LeaseDriver.renewalAccepted`, delete the transition to
    /// `held.with(lease: renewed)`. Red on `expiresAt`. **Mutation:** delete the
    /// `renewed.id == leaseID` guard. Red on the loss.
    @Test("A renewal updates the lease held, and one naming another lease ends it")
    func aRenewalUpdatesTheLease() async throws {
        let scene = await LeaseScene()
        let granted = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.clock.untilParked { !$0.isEmpty }
        let beat = scene.at(.seconds(10))
        scene.clock.advance(to: beat)
        await scene.clock.untilParked { $0.contains { $0 > beat } }

        guard case .held(let renewed) = await scene.driver.state else {
            Issue.record("not held after a good renewal")
            return
        }
        #expect(renewed.lease.id == granted.lease.id)
        #expect(renewed.lease.expiresAt == granted.lease.expiresAt.addingTimeInterval(10))

        await scene.helper.renewAnotherLease()
        let next = scene.at(.seconds(20))
        scene.clock.advance(to: next)
        // Lost, or the beat re-armed past twenty seconds, as one that believed the answer would.
        await firstOf(
            { await scene.waitForState { $0.isLost } },
            { await scene.clock.untilParked { $0.contains { $0 > next } } })
        #expect(
            await scene.driver.state.loss?.cause
                == .renewal(.other("the helper renewed a different lease")))
        await scene.finish()
    }

    /// A helper that grants a shorter TTL than was asked is renewed on a third of what it
    /// granted; one that grants a TTL outside the validated range is not believed, so it cannot
    /// make the heartbeat spin.
    ///
    /// **Mutation:** in `LeaseDriver.heartbeatInterval`, ignore `granted`. Red on the 15 s grant.
    /// **Mutation:** drop the `leaseTTLRange` check. Red on the 1 s grant. **Mutation (Me):** use
    /// `believed` alone, not the shorter of the two. Red on the 60 s grant.
    @Test("The interval is a third of the shorter TTL, and only of a believable one")
    func theShorterTTL() async throws {
        for (granted, beat) in [(15.0, 5.0), (1.0, 10.0), (60.0, 10.0)] {
            let scene = await LeaseScene()
            await scene.helper.grant(timeToLive: granted)
            try await scene.take(LeaseScene.target([0: 3000]))
            await scene.clock.untilParked { !$0.isEmpty }

            let justBefore = scene.at(.seconds(beat - 0.01))
            scene.clock.advance(to: justBefore)
            await scene.clock.untilParked { $0.contains { $0 > justBefore } }
            #expect(await scene.entries.renewals.isEmpty, "granted \(granted) s: nothing before")
            let due = scene.at(.seconds(beat))
            scene.clock.advance(to: due)
            await scene.clock.untilParked { $0.contains { $0 > due } }
            #expect(await scene.entries.renewals == [due], "granted \(granted) s: one at \(beat) s")
            await scene.finish()
        }
    }

    /// A good renewal after a wake clears the wake from the record: a loss found later, for
    /// another reason, does not say control ended across a sleep.
    ///
    /// **Mutation:** in `LeaseDriver.renewalAccepted`, delete `wokeSinceRenewal = false`. Red on
    /// `afterWake`.
    @Test("A good renewal after a wake clears it")
    func aGoodRenewalAfterAWakeClearsIt() async throws {
        let scene = await LeaseScene()
        try await scene.take(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { !$0.isEmpty }

        await scene.run { await scene.driver.systemDidWake() }
        await scene.clock.untilParked { $0.contains(scene.at(.seconds(10))) }
        #expect(await scene.entries.renewals == [scene.start], "the wake's renewal")
        await scene.driver.observe(
            Loss.snapshot([], listing: nil), readWith: await scene.driver.beginSnapshotRead())

        let loss = try #require(await scene.driver.state.loss)
        #expect(!loss.afterWake, "the renewal after the wake proved the lease survived it")
        await scene.finish()
    }
}
