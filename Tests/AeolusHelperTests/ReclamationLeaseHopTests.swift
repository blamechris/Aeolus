import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5 across its **lease hop** — the one suspension in `ReclamationWatchdog.examine(fanAt:)`
/// that no seam double wraps.
///
/// `leases` is the concrete `LeaseAuthority`, so nothing can stand in for the hop the way
/// `InterferingFanStateSensing` stands in for a read. What the hop does do is read the lease
/// core's injected `MonotonicClock`, synchronously and inside the actor, in
/// `LeaseAuthority.hasLiveLease(coveringFan:)`. `LeaseHopClock` runs a release from inside that
/// read, so the release lands while `examine(fanAt:)` is suspended on the hop.
///
/// ## Why it blocks, and why it cannot hang
///
/// `now` is synchronous, so the release can only land inside the hop if `now` starts it and
/// waits for it there. The release runs on a task of its own while the lease core's thread
/// waits on a semaphore, and that needs a second thread in Swift's cooperative pool: with one,
/// the waiting thread is the one the release needs. So the suite is skipped where the pool
/// cannot be wider than one thread — fewer than two active processors, or
/// `LIBDISPATCH_COOPERATIVE_POOL_STRICT` set — and the wait is bounded by
/// `LeaseHopClock.releaseBudget` anyway. A wait that runs out is recorded as `.timedOut` and the
/// test fails on that assertion rather than hanging. The budget is a ceiling on a deadlock, not
/// a sleep: a passing run waits only as long as the release takes.
@Suite(
    "The reclamation watchdog, across its lease hop",
    .enabled(
        if: LeaseHopClock.poolCanRunTheRelease,
        """
        needs a cooperative pool wider than one thread: the lease core's thread waits inside \
        `now` for a release that has to run on another one
        """),
    .timeLimit(.minutes(1)))
struct ReclamationLeaseHopTests {

    /// **The re-fetch across the lease hop.** A fan released while § 5 is asking the lease core
    /// about it gets no second hand-back, and no fault claiming it may still be pinned.
    ///
    /// The lease has lapsed with nobody told, so the hop answers "not live" — the answer whose
    /// branch acts — and the release lands inside that very question. The firmware refuses
    /// writes, so a hand-back that should not happen leaves both a restore attempt and a
    /// `.fault` behind to be seen.
    ///
    /// **Mutation (M4):** move `guard entitled else { … }` above `guard let fan = held[index]`
    /// in `examine(fanAt:)`. Run: red on the abandonment log, the restore, the lease-lapse
    /// line and the "may still be pinned" fault.
    @Test("A fan released during the lease hop is not handed back a second time")
    func aFanReleasedDuringTheLeaseHopIsNotHandedBackAgain() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .held(at: 2_400)],
            stages: [.nominal(writes: .refused(reason: "firmware said no"))])
        let clock = LeaseHopClock()
        let latch = ThermalEmergencyLatch()
        let leases = LeaseAuthority(
            enumeration: ScriptedFanEnumeration(),
            restorer: RecordingFanRestorer(),
            writeCapability: LeaseFixture.writePathBuilt(),
            telemetry: LeaseFixture.sightedTelemetry(),
            foreignControl: LeaseFixture.automaticFans(),
            thermalEmergency: latch,
            clock: clock,
            log: LeaseFixture.log)
        let log = RecordedLog()
        let watchdog = ReclamationWatchdog(
            sensing: plane,
            writer: SafetyActorWriter(plane: plane, level: .reclamationWatchdog),
            leases: leases,
            latch: latch,
            ledger: ReclamationLedger(),
            log: SafetyLog(recording: { [log] in log.append($0, $1) }))

        _ = try await leases.acquireLease(LeaseFixture.request(fans: [0]), from: ConnectionID())
        await watchdog.manualControlEngaged(try commandableFan(0, declaring: .held(at: 2_400)))
        await watchdog.commandedTarget(CommandedTarget(fanIndex: 0, rpm: 2_400))
        clock.advance(by: .seconds(Lease.defaultTimeToLive + 1))
        clock.armRelease { await watchdog.manualControlReleased(fanAt: 0) }

        await watchdog.cycle()

        #expect(
            clock.releaseOutcome == .finished,
            "the release never finished inside the lease hop, so this proves nothing")
        #expect(
            log.lines(containing: "during the lease check").count == 1,
            "the examination was not abandoned at the re-fetch across the lease hop")
        #expect(
            await plane.attempts.contains(.restoreToAutomatic(.fan(0))) == false,
            "a fan released during the lease hop was handed back a second time")
        #expect(log.lines(containing: "no live lease covers it").isEmpty)
        #expect(
            log.lines(containing: "may still be under manual control").isEmpty,
            "a fault claimed a released fan may still be pinned")
    }
}

/// A lease-core clock that, once armed, runs one release **inside** the next `now` read.
///
/// `@unchecked Sendable` for `TestClock`'s reason, and under the same discipline: every piece
/// of mutable state is behind `lock`. `Mutex` would make the claim checkable, but it needs
/// macOS 15 and this package's floor is 13.
final class LeaseHopClock: MonotonicClock, @unchecked Sendable {

    enum ReleaseOutcome: Sendable, Equatable {
        case notArmed
        case armed
        case finished
        case timedOut
    }

    /// The most `now` waits for the release before giving up and recording `.timedOut`.
    static let releaseBudget: DispatchTimeInterval = .seconds(5)

    /// Whether Swift's cooperative pool can have a second thread to run the release on while
    /// the lease core's thread waits for it.
    static var poolCanRunTheRelease: Bool {
        ProcessInfo.processInfo.activeProcessorCount >= 2
            && ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == nil
    }

    private let base = TestClock()
    private let lock = NSLock()
    private var release: (@Sendable () async -> Void)?
    private var outcome = ReleaseOutcome.notArmed

    var releaseOutcome: ReleaseOutcome { lock.withLock { outcome } }

    func advance(by duration: Duration) {
        base.advance(by: duration)
    }

    /// Runs `release` inside the next `now` read, once.
    func armRelease(_ release: @escaping @Sendable () async -> Void) {
        lock.withLock {
            self.release = release
            outcome = .armed
        }
    }

    var now: ContinuousClock.Instant {
        let pending: (@Sendable () async -> Void)? = lock.withLock {
            defer { release = nil }
            return release
        }
        if let pending {
            let done = DispatchSemaphore(value: 0)
            Task {
                await pending()
                done.signal()
            }
            let waited = done.wait(timeout: .now() + Self.releaseBudget)
            lock.withLock { outcome = waited == .success ? .finished : .timedOut }
        }
        return base.now
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await base.sleep(until: deadline)
    }
}
