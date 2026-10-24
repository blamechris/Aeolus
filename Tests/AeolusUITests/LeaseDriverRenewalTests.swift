import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// The lease is renewed every `timeToLive / 3`, from the instant before it was asked for,
/// including while an `apply` is outstanding; and a renewal that fails ends it for good.
///
/// Time is the hand-wound clock's. A test moves it to an instant and then waits for the clock to
/// show the heartbeat parked beyond that instant, which is what "the driver has done everything it
/// was going to do at this instant" looks like from outside. Nothing waits on a real duration.
@Suite("Lease driver: renewal", .timeLimit(.minutes(1)))
struct LeaseDriverRenewalTests {

    // MARK: - The schedule

    /// With the shipping TTL of 30 s the beat is 10 s: nothing is sent at 9.99 s, and one renewal
    /// is sent at exactly 10 s.
    ///
    /// **Mutation (TTL/2):** in `LeaseDriver.granted`, divide the TTL by 2. The heartbeat parks
    /// at 15 s instead, and the second expectation is red.
    @Test("No renewal at 9.99 s, and one at 10 s")
    func renewsAtTheThirdOfTheTTL() async throws {
        let scene = await LeaseScene()
        try await scene.hold(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { !$0.isEmpty }

        let justBefore = scene.at(.milliseconds(9_990))
        scene.clock.advance(to: justBefore)
        await scene.clock.untilParked { $0.contains { $0 > justBefore } }
        #expect(await scene.entries.renewals.isEmpty, "nothing is due before ten seconds")

        let beat = scene.at(.seconds(10))
        scene.clock.advance(to: beat)
        await scene.clock.untilParked { $0.contains { $0 > beat } }
        #expect(await scene.entries.renewals == [beat], "one renewal, at ten seconds")
        await scene.finish()
    }

    /// The schedule starts at the instant taken **before** `acquireLease` is sent, not when its
    /// answer arrives. The helper's thirty seconds start at the grant, which cannot be earlier than
    /// the request, so a schedule kept from the request is never late by the helper's clock.
    ///
    /// **Mutation (from the reply):** in `LeaseDriver.acquire`, take `requestedAt` after
    /// `acquireLease` returns. With the acquire taking 5 s the heartbeat parks at 15 s, and the
    /// renewal expectation is red.
    @Test("The schedule starts before the request is sent, not when the grant arrives")
    func scheduleStartsAtTheRequest() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .after(.seconds(5)))
        await scene.driver.hold(try LeaseScene.target([0: 3000]))
        let grantAt = scene.at(.seconds(5))
        await scene.clock.untilParked(at: grantAt)
        scene.clock.advance(to: grantAt)
        await scene.waitForState { if case .held(let held) = $0 { held.isConfirmed } else { false } }
        await scene.clock.untilParked { !$0.isEmpty }

        let entries = await scene.entries
        #expect(entries.first { $0.event.isAcquire }?.at == scene.start, "asked for at the start")
        #expect(entries.first { $0.event == .acquireAnswered }?.at == grantAt, "granted at 5 s")

        let justBefore = scene.at(.milliseconds(9_990))
        scene.clock.advance(to: justBefore)
        await scene.clock.untilParked { $0.contains { $0 > justBefore } }
        #expect(await scene.entries.renewals.isEmpty)

        let beat = scene.at(.seconds(10))
        scene.clock.advance(to: beat)
        await scene.clock.untilParked { $0.contains { $0 > beat } }
        #expect(
            await scene.entries.renewals == [beat],
            "ten seconds from the request, not from the grant at five")
        await scene.finish()
    }

    /// An `apply` may lawfully take 57 s for one fan, and the helper's thirty seconds started at
    /// the grant. The heartbeat starts with the grant and runs alongside: five renewals land while
    /// the `apply` is outstanding, and the `apply` is answered only after them.
    ///
    /// **Mutation (heartbeat after the apply):** in `LeaseDriver.granted`, move `startHeartbeat`
    /// into `applyAccepted`, so it starts once the first `apply` is answered. Nothing renews while
    /// the `apply` works, the heartbeat never arms for 10 s, and the test is red on its time limit
    /// at the wait for that arming: the clock it waits on stands still, because only a renewal
    /// would be there to move it on.
    @Test("At least five renewals land during a 57 s apply")
    func renewsDuringALongApply() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .after(.seconds(57)))
        await scene.driver.hold(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.applies.isEmpty }

        for beat in 1...5 {
            let due = scene.at(.seconds(10 * beat))
            await scene.clock.untilParked(at: due)
            scene.clock.advance(to: due)
        }
        await scene.clock.untilParked(at: scene.at(.seconds(60)))

        let entries = await scene.entries
        let renewals = entries.renewals
        #expect(renewals == (1...5).map { scene.at(.seconds(10 * $0)) }, "\(renewals)")
        #expect(
            entries.index(where: \.isApplyAnswer) == nil,
            "every one of them while the apply was outstanding")
        #expect(await scene.driver.state.isHeld)

        scene.clock.advance(to: scene.at(.seconds(57)))
        await scene.waitForState { if case .held(let held) = $0 { held.isConfirmed } else { false } }
        await scene.finish()
    }

    // MARK: - A failed renewal is final

    /// A renewal the helper refuses ends the lease as `lost`, never `held`. No second renewal is
    /// sent at the next beat, and nothing asks for the fans again.
    ///
    /// **Mutation (retry):** in `LeaseDriver.beat`, on a failed renewal `continue` instead of
    /// losing the lease. The next beat renews again: red on the renewal count and the state.
    ///
    /// **Mutation (re-acquire):** in `LeaseDriver.lose`, after the transition, start an
    /// acquisition of the confirmed target. Red on the acquire count and the state.
    @Test("A refused renewal is lost, with no second renewal and no second acquire")
    func aRefusedRenewalIsLost() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.renew, .refuse(.leaseExpired))
        try await scene.hold(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { !$0.isEmpty }

        scene.clock.advance(to: scene.at(.seconds(10)))
        await scene.ledger.waitFor { $0.renewals.count == 1 }
        // The next beat's instant, so a driver that keeps beating gets its chance to.
        scene.clock.advance(to: scene.at(.seconds(20)))
        await scene.ledger.waitFor {
            $0.lost != nil || $0.renewals.count > 1 || $0.acquires.count > 1
        }

        let entries = await scene.entries
        #expect(entries.renewals.count == 1, "never retried")
        #expect(entries.acquires.count == 1, "never asked for again")
        let state = await scene.driver.state
        #expect(state.loss?.cause == .renewal(.refused(.leaseExpired)), "\(state)")
        #expect(!state.isHeld)
        await scene.finish()
    }

    // MARK: - Wake

    /// The helper releases every lease before a sleep (`docs/SAFETY.md` § 4). On wake the driver
    /// renews at once, finds the lease gone, and says control ended across the sleep. It never
    /// asks for the fans again.
    ///
    /// **Mutation (re-acquire on wake):** in `LeaseDriver.systemDidWake`, start an acquisition of
    /// the confirmed target. Red on the acquire count.
    @Test("Wake renews at once and never re-acquires")
    func wakeNeverReacquires() async throws {
        let scene = await LeaseScene()
        try await scene.hold(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { !$0.isEmpty }
        await scene.helper.script(.renew, .refuse(.leaseUnknown))

        await scene.driver.systemDidWake()
        await scene.ledger.waitFor { $0.lost != nil || $0.acquires.count > 1 }

        let entries = await scene.entries
        #expect(entries.acquires.count == 1, "the fans are not asked for again on wake")
        #expect(entries.renewals == [scene.start], "the renewal was brought forward to the wake")
        let loss = try #require(await scene.driver.state.loss)
        #expect(loss.cause == .renewal(.refused(.leaseUnknown)))
        #expect(loss.afterWake, "the state says control ended across the sleep")
        await scene.finish()
    }

    /// A wake after the lease was already lost sends nothing at all.
    @Test("Wake after a loss sends nothing")
    func wakeAfterALossSendsNothing() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.renew, .refuse(.leaseExpired))
        try await scene.hold(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { !$0.isEmpty }
        scene.clock.advance(to: scene.at(.seconds(10)))
        await scene.waitForState { $0.isLost }
        await scene.ledger.waitFor { !$0.releases.isEmpty }
        let before = await scene.entries.count

        await scene.driver.systemDidWake()
        await scene.driver.hold(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { $0.acquires.count == 2 }

        let after = Array(await scene.entries.dropFirst(before))
        #expect(after.renewals.isEmpty, "the wake renewed nothing: \(after)")
        #expect(after.acquires.count == 1, "the only acquire is the user's own")
        await scene.finish()
    }
}

extension LeaseLedger.Event {

    var isAcquire: Bool {
        if case .acquire = self { return true }
        return false
    }

    var isApplyAnswer: Bool {
        if case .applyAnswered = self { return true }
        return false
    }

    var isState: Bool {
        if case .state = self { return true }
        return false
    }
}

extension HeldLease {

    var isConfirmed: Bool {
        if case .confirmed = phase { return true }
        return false
    }
}
