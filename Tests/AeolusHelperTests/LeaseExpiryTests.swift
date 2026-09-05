import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Expiry arithmetic, and the one property that makes it worth having: it is judged on a
/// monotonic clock, so nothing a user or an NTP daemon does to the wall clock changes when
/// a lease lapses.
///
/// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md): *"The supervisor enforces on
/// `ContinuousClock`, so a wall-clock jump — NTP, a user setting the clock back — can never
/// extend a lease, and time asleep counts against the TTL."*
@Suite("Lease expiry on the monotonic clock")
struct LeaseExpiryTests {

    @Test("A lease is live until its deadline and lapsed at it")
    func lapsesExactlyAtTheDeadline() async throws {
        let clock = TestClock()
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer, clock: clock)

        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0], timeToLive: 30), from: ConnectionID())

        clock.advance(by: .seconds(29))
        await authority.expireLapsedLeases()
        #expect(await authority.leaseCount == 1)
        #expect(await restorer.restores.isEmpty)

        clock.advance(by: .seconds(1))
        await authority.expireLapsedLeases()
        #expect(await authority.leaseCount == 0)
        #expect(await restorer.restores == [.init(fans: [0], cause: .leaseExpired)])
    }

    /// A renewal moves the deadline; it does not accumulate. Two renewals inside one TTL
    /// must not buy a lease three TTLs of life.
    @Test("Renewal restarts the TTL from now, and does not stack")
    func renewalRestartsTheTimeToLive() async throws {
        let clock = TestClock()
        let authority = LeaseFixture.authority(clock: clock)
        let connection = ConnectionID()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(timeToLive: 30), from: connection)

        clock.advance(by: .seconds(20))
        _ = try await authority.renewLease(id: lease.id, from: connection)

        clock.advance(by: .seconds(29))
        await authority.expireLapsedLeases()
        #expect(await authority.leaseCount == 1, "a renewal at t=20 must survive to t=49")

        clock.advance(by: .seconds(1))
        await authority.expireLapsedLeases()
        #expect(await authority.leaseCount == 0, "and must not survive past t=50")
    }

    /// **The wall clock cannot extend a lease.** The user sets their clock back an hour
    /// mid-lease; the monotonic clock passes the TTL; the lease still expires.
    ///
    /// This is the mutation-visible one: make `LeaseRecord.hasLapsed` compare `Date` values
    /// and this test goes red, because `expiresAt` is now an hour in the future.
    @Test("A wall clock set backwards does not extend a lease")
    func wallClockJumpingBackwardsDoesNotExtend() async throws {
        let clock = TestClock()
        let wallClock = TestWallClock()
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(
            restorer: restorer, clock: clock, wallClock: wallClock)

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0], timeToLive: 30), from: ConnectionID())
        // Proves the premise: the display expiry really is a wall-clock value derived from
        // the injected clock, so moving that clock really does move it out of reach.
        #expect(lease.expiresAt == wallClock.current.addingTimeInterval(30))

        wallClock.jump(by: -3_600)
        clock.advance(by: .seconds(30))
        await authority.expireLapsedLeases()

        #expect(await authority.leaseCount == 0)
        #expect(await restorer.causes == [.leaseExpired])
    }

    /// And the mirror: a wall clock jumping *forwards* cannot expire a lease early either.
    /// Enforcement does not consult it in either direction.
    @Test("A wall clock set forwards does not expire a lease early")
    func wallClockJumpingForwardsDoesNotExpire() async throws {
        let clock = TestClock()
        let wallClock = TestWallClock()
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(
            restorer: restorer, clock: clock, wallClock: wallClock)
        let connection = ConnectionID()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(timeToLive: 30), from: connection)

        wallClock.jump(by: 3_600)
        await authority.expireLapsedLeases()

        #expect(await authority.leaseCount == 1)
        #expect(await restorer.restores.isEmpty)
        // Still renewable, which is the client-visible half of the same fact.
        let renewed = try await authority.renewLease(id: lease.id, from: connection)
        #expect(renewed.id == lease.id)
    }

    /// Time asleep counts against the TTL, which is `ContinuousClock`'s whole reason for
    /// being chosen over `SuspendingClock`. A machine that slept through the lease wakes
    /// with the fans already back on automatic.
    @Test("A long jump on the monotonic clock expires every outstanding lease")
    func timeAsleepCountsAgainstTheTimeToLive() async throws {
        let clock = TestClock()
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer, clock: clock)

        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0, 1], timeToLive: 120), from: ConnectionID())

        clock.advance(by: .seconds(8 * 60 * 60))
        await authority.expireLapsedLeases()

        #expect(await authority.leaseCount == 0)
        #expect(await restorer.restores == [.init(fans: [0, 1], cause: .leaseExpired)])
    }

    /// An expired lease is re-acquired, never resurrected — `AeolusXPCProtocol`'s wording.
    /// The refusal has to be `.leaseExpired` and not `.leaseUnknown`: they are different
    /// facts, and only one of them tells the client what to do next.
    @Test("Renewing after expiry is refused as expired, not as unknown")
    func renewalAfterExpiryIsRefusedAsExpired() async throws {
        let clock = TestClock()
        let authority = LeaseFixture.authority(clock: clock)
        let connection = ConnectionID()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(timeToLive: 30), from: connection)
        clock.advance(by: .seconds(31))

        await #expect(throws: AeolusXPCFault.leaseExpired) {
            _ = try await authority.renewLease(id: lease.id, from: connection)
        }
    }

    @Test("A lease ID this helper never issued is unknown, not expired")
    func unknownLeaseIsRefusedAsUnknown() async throws {
        let authority = LeaseFixture.authority()

        await #expect(throws: AeolusXPCFault.leaseUnknown) {
            _ = try await authority.renewLease(id: UUID(), from: ConnectionID())
        }
    }

    /// A snapshot must never show a lease that has stopped holding the fans, so reading the
    /// active lease sweeps first.
    @Test("The reported active lease is swept before it is reported")
    func activeLeaseIsSweptBeforeItIsReported() async throws {
        let clock = TestClock()
        let authority = LeaseFixture.authority(clock: clock)

        _ = try await authority.acquireLease(
            LeaseFixture.request(timeToLive: 30), from: ConnectionID())
        #expect(await authority.activeLease() != nil)

        clock.advance(by: .seconds(30))
        #expect(await authority.activeLease() == nil)
    }
}

/// The TTL supervisor: the loop that makes expiry happen with nothing else running.
///
/// Driven against `TestClock`, whose `sleep(until:)` jumps virtual time and returns
/// immediately, and which cancels the run after a fixed number of passes. So these exercise
/// `LeaseExpirySupervisor.run` itself — the real scheduling arithmetic — deterministically
/// and in no wall-clock time at all.
@Suite("The TTL supervisor")
struct LeaseExpirySupervisorTests {

    @Test("The loop expires a lease with no connection event of any kind")
    func loopExpiresALeaseUnprompted() async throws {
        // Seven passes because no sleep may outrun `maximumWake` — a 30 s lease is reached
        // in six five-second wakes, and the seventh pass is the one that sweeps it.
        let clock = TestClock(sleepBudget: 7)
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer, clock: clock)

        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0], timeToLive: 30), from: ConnectionID())

        await LeaseExpirySupervisor.run(
            authority: authority,
            clock: clock,
            idleInterval: LeaseExpirySupervisor.defaultIdleInterval,
            log: LeaseFixture.log
        )

        #expect(await authority.leaseCount == 0)
        #expect(await restorer.causes == [.leaseExpired])
    }

    /// The scheduling half: with a lease outstanding the loop sleeps to that lease's
    /// deadline, not to the idle interval. Sleeping to the idle interval would still expire
    /// the lease eventually, so a test that only checked the outcome would pass on a
    /// supervisor that polled — and polling a root daemon awake every second forever is not
    /// what this is.
    ///
    /// The clock is advanced to within `maximumWake` of the deadline first, so that the cap
    /// #151 added is not the thing being measured: this is the case where the deadline is
    /// the sooner of the two, and the pass must sleep to it exactly. `maximumWake` itself is
    /// covered by `LeaseExpirySupervisorScheduleTests`.
    @Test("A pass sleeps to the outstanding deadline, not to the idle interval")
    func sleepsToTheDeadline() async throws {
        let start = ContinuousClock.now
        let clock = TestClock(start: start, sleepBudget: 1)
        let authority = LeaseFixture.authority(clock: clock)

        _ = try await authority.acquireLease(
            LeaseFixture.request(timeToLive: 45), from: ConnectionID())
        clock.advance(by: .seconds(43))

        await LeaseExpirySupervisor.run(
            authority: authority,
            clock: clock,
            idleInterval: .seconds(1),
            log: LeaseFixture.log
        )

        #expect(clock.sleeps.first == start.advanced(by: .seconds(45)))
    }

    /// With nothing outstanding it sleeps for the idle interval — short enough that a lease
    /// acquired during one cannot have lapsed before the next pass sees it, because the
    /// shortest TTL the helper grants is five seconds.
    @Test("An empty table sleeps for the idle interval, which is under the shortest TTL")
    func idlesBelowTheShortestGrantableTimeToLive() async throws {
        let start = ContinuousClock.now
        let clock = TestClock(start: start, sleepBudget: 1)
        let authority = LeaseFixture.authority(clock: clock)

        await LeaseExpirySupervisor.run(
            authority: authority,
            clock: clock,
            idleInterval: LeaseExpirySupervisor.defaultIdleInterval,
            log: LeaseFixture.log
        )

        let idle = LeaseExpirySupervisor.defaultIdleInterval
        #expect(clock.sleeps.first == start.advanced(by: idle))
        // And it keeps that cadence rather than tightening: two passes, one interval apart.
        #expect(clock.sleeps.count >= 2)
        #expect(clock.sleeps.first?.duration(to: clock.sleeps[1]) == idle)
        #expect(
            LeaseExpirySupervisor.defaultIdleInterval
                < .seconds(AeolusXPCValidation.leaseTTLRange.lowerBound),
            "an idle sleep longer than the shortest grantable TTL could make an expiry late"
        )
    }

    /// A deadline already in the past must not turn the loop into a spin. The sweep should
    /// make that unreachable; the floor is what stops "should" from becoming a root daemon
    /// burning a core.
    @Test("A pass never sleeps for zero, even asked to wake in the past")
    func neverSleepsForZero() async throws {
        let start = ContinuousClock.now
        let clock = TestClock(start: start, sleepBudget: 3)
        let authority = LeaseFixture.authority(clock: clock)

        await LeaseExpirySupervisor.run(
            authority: authority, clock: clock, idleInterval: .zero, log: LeaseFixture.log)

        for (index, deadline) in clock.sleeps.enumerated() {
            #expect(deadline > start, "sleep \(index) did not advance the clock")
        }
    }

    /// Starting twice must run one supervisor, not two. Two loops sharing one authority
    /// would double every sweep and every wake, which is invisible in the outcome and very
    /// visible in a battery graph — so the guard reports whether it fired rather than
    /// swallowing the second call.
    @Test("Starting twice runs one loop, and stopping ends it")
    func lifecycleStartsOneLoop() async throws {
        let clock = TestClock(sleepBudget: 2)
        let authority = LeaseFixture.authority(clock: clock)
        let supervisor = LeaseExpirySupervisor(
            authority: authority, clock: clock, idleInterval: .seconds(1),
            log: LeaseFixture.log)

        #expect(await supervisor.start() == true)
        #expect(await supervisor.start() == false, "the second start must not run a second loop")
        #expect(await supervisor.isRunning)

        await supervisor.stop()
        #expect(await supervisor.isRunning == false)
        #expect(await supervisor.start() == true, "and it can be started again after a stop")
        await supervisor.stop()
    }
}
