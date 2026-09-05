import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The TTL supervisor's **schedule**, as distinct from its arithmetic.
///
/// [#151](https://github.com/blamechris/Aeolus/issues/151): a pass used to sleep to the
/// earliest deadline it read *before* the sleep, and nothing re-validated that across it.
/// The lease table is free to change while a pass is parked, and one direction of change —
/// a shorter lease replacing a longer one — made the TTL arbitrarily late rather than
/// merely imprecise. With `leaseTTLRange` at `5...120` the worst case was ~115 seconds of a
/// lapsed lease still holding the fans with no live claim behind it.
///
/// These tests pin the bound that closes it: **no sleep outruns the shortest TTL the helper
/// will grant**, so a lease acquired during any sleep is seen no later than its own
/// deadline. That is the argument the type already made for its idle branch, now made for
/// both branches and derived from `AeolusXPCValidation.leaseTTLRange` rather than restated.
@Suite("The TTL supervisor's schedule")
struct LeaseExpirySupervisorScheduleTests {

    /// The bound itself, at the worst case the validator permits: a 120-second lease must
    /// not buy a 120-second sleep.
    @Test("No sleep outruns the shortest TTL the helper can grant")
    func neverSleepsPastTheShortestGrantableTimeToLive() async throws {
        let start = ContinuousClock.now
        let clock = TestClock(start: start, sleepBudget: 1)
        let authority = LeaseFixture.authority(clock: clock)

        _ = try await authority.acquireLease(
            LeaseFixture.request(timeToLive: AeolusXPCValidation.leaseTTLRange.upperBound),
            from: ConnectionID()
        )

        await LeaseExpirySupervisor.run(
            authority: authority,
            clock: clock,
            idleInterval: LeaseExpirySupervisor.defaultIdleInterval,
            log: LeaseFixture.log
        )

        // Asserted against the validator's own floor rather than against the supervisor's
        // constant: the two are coupled, and a test that read the constant would agree with
        // it however wrong it was.
        let shortestGrantable = Duration.seconds(AeolusXPCValidation.leaseTTLRange.lowerBound)
        #expect(
            clock.sleeps.first == start.advanced(by: shortestGrantable),
            "a pass parked on a 120 s deadline cannot see a 5 s lease taken during it"
        )
    }

    /// The defect, end to end, with the interleaving forced rather than raced for.
    ///
    /// A client takes the longest lease the validator allows; the supervisor parks; **while
    /// it is parked** that client releases and a second client takes the shortest lease
    /// there is. The assertion is on *when* the restore happened on the monotonic timeline,
    /// because that is the harm: against the pre-#151 schedule the second lease lapsed at
    /// `start + 6` and its fans were not handed back until `start + 120`.
    ///
    /// An outcome-only assertion — `leaseCount == 0` once the loop has run — passes against
    /// the defect, because the pass that eventually wakes at the *stale* deadline does sweep
    /// the lapsed lease. Lateness is the whole defect, so lateness is what is measured.
    @Test("A shorter lease taken during a sleep is still expired at its own deadline")
    func aShorterLeaseTakenDuringASleepExpiresOnTime() async throws {
        let start = ContinuousClock.now
        let inner = TestClock(start: start, sleepBudget: 3)
        let clock = InterleavingClock(inner)
        let restorer = StampingFanRestorer(clock: inner)
        // Built here rather than through `LeaseFixture.authority`, which pins the concrete
        // `TestClock` and `RecordingFanRestorer`; this test needs a clock it can interleave
        // with and a restorer that records when, not only what.
        let authority = LeaseAuthority(
            enumeration: ScriptedFanEnumeration(),
            restorer: restorer,
            telemetry: LeaseFixture.sightedTelemetry(),
            thermalEmergency: ThermalEmergencyLatch(),
            clock: clock,
            wallClock: TestWallClock().provider,
            log: LeaseFixture.log
        )

        let holder = ConnectionID()
        let successor = ConnectionID()
        let longest = try await authority.acquireLease(
            LeaseFixture.request(
                fans: [0], timeToLive: AeolusXPCValidation.leaseTTLRange.upperBound),
            from: holder
        )

        clock.duringNextSleep = {
            // One second into the parked sleep, so the successor's deadline is a real
            // instant rather than coinciding with the wake under test.
            inner.advance(by: .seconds(1))
            do {
                try await authority.releaseLease(id: longest.id, from: holder)
                _ = try await authority.acquireLease(
                    LeaseFixture.request(
                        fans: [0],
                        timeToLive: AeolusXPCValidation.leaseTTLRange.lowerBound),
                    from: successor
                )
            } catch {
                Issue.record("the interleaved client calls must both succeed: \(error)")
            }
        }

        await LeaseExpirySupervisor.run(
            authority: authority,
            clock: clock,
            idleInterval: LeaseExpirySupervisor.defaultIdleInterval,
            log: LeaseFixture.log
        )

        // Granted at start + 1 with a 5 s TTL.
        let successorDeadline = start.advanced(by: .seconds(6))
        let expiry = try #require(
            await restorer.stamps.first { $0.cause == .leaseExpired },
            "the successor's lease must have been expired by the TTL supervisor"
        )
        #expect(
            expiry.at <= successorDeadline,
            "handed back late: the pass was parked on the deadline of a lease already gone"
        )
        #expect(await authority.leaseCount == 0)
    }
}

// MARK: - Doubles

/// A clock that lets a test run something **inside** a sleep.
///
/// The lease table changing while a pass is parked is the whole of #151, and it is not
/// something to race the scheduler for: the body runs at the suspension point itself, before
/// the wrapped clock is allowed to reach the deadline, so anything it acquires is stamped at
/// the instant the supervisor parked at rather than at the instant it wakes.
///
/// Everything else — recording, the virtual jump, the sleep budget that ends the loop — is
/// the wrapped `TestClock`'s, so this adds an interleaving point and no second clock
/// semantics.
final class InterleavingClock: MonotonicClock, @unchecked Sendable {

    private let inner: TestClock
    private let lock = NSLock()
    private var body: (@Sendable () async -> Void)?

    init(_ inner: TestClock) {
        self.inner = inner
    }

    /// Runs once, inside the next `sleep(until:)`, and is then cleared.
    var duringNextSleep: (@Sendable () async -> Void)? {
        get { lock.withLock { body } }
        set { lock.withLock { body = newValue } }
    }

    var now: ContinuousClock.Instant { inner.now }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let pending: (@Sendable () async -> Void)? = lock.withLock {
            defer { body = nil }
            return body
        }
        await pending?()
        try await inner.sleep(until: deadline)
    }
}

/// A restorer that records **when** each restore happened, on the same monotonic clock
/// expiry is judged against.
///
/// `RecordingFanRestorer` answers "which mechanism handed the fans back"; this answers "and
/// how late was it", which is the only question #151 turns on.
actor StampingFanRestorer: FanRestoring {

    struct Stamp: Sendable, Hashable {
        let fans: Set<Int>
        let cause: FanRestoreCause
        let at: ContinuousClock.Instant
    }

    private let clock: any MonotonicClock
    private(set) var stamps: [Stamp] = []

    init(clock: any MonotonicClock) {
        self.clock = clock
    }

    func restoreToAutomatic(fans: Set<Int>, because cause: FanRestoreCause) async {
        stamps.append(Stamp(fans: fans, cause: cause, at: clock.now))
    }
}
