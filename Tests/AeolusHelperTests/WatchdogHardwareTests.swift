import FanKit
import Foundation
import SMCCore
import Testing
import os

@testable import AeolusHelper

/// The liveness watchdog against the real SMC: the one thing no double can show, which is that
/// on a healthy machine, doing its ordinary work beside a contending reader, it **never
/// fires**.
///
/// A watchdog that fired on a healthy helper would cost every user their manual control for no
/// reason, and the bounds are derived from a measurement taken on this machine. This is that
/// measurement's counterpart: the production composition, bringing up and cycling for a
/// stated time over the real SMC, with the shipping timer wrapped in a counter so that "it did
/// not fire" cannot be mistaken for "it never ticked".
///
/// ## Read-only, and opt-in
///
/// `bringUp()` over `SMCFanControlPlane` writes nothing: the write path is not built, and the
/// keystone is refused with `controlPathNotBuilt` before IOKit is touched. The test is opt-in
/// because it takes as long as it is asked to — set `AEOLUS_WATCHDOG_SOAK_SECONDS` — and
/// because the contention it is meant to be run beside is a person's decision:
///
/// ```
/// while true; do .build/debug/fanctl sensors > /dev/null; done &
/// AEOLUS_WATCHDOG_SOAK_SECONDS=60 swift test --filter WatchdogHardwareTests
/// ```
///
/// The process is never ended by this test: the terminate seam is a journal.
@Suite(
    "The liveness watchdog, real hardware",
    .serialized,
    .enabled(
        if: SMCConnection.isHardwareAvailable()
            && HardwareIdentity.current().modelIdentifier == "Mac16,5"
            && ProcessInfo.processInfo.environment["AEOLUS_WATCHDOG_SOAK_SECONDS"] != nil),
    .timeLimit(.minutes(10))
)
struct WatchdogHardwareTests {

    /// The shipping timer, with every delivered tick counted.
    final class CountingTicks: WatchdogTicking, Sendable {
        private let real = DispatchWatchdogTicks()
        private let delivered = OSAllocatedUnfairLock(initialState: 0)

        func start(_ handler: @escaping @Sendable () -> Void) async {
            await real.start { [delivered] in
                delivered.withLock { $0 += 1 }
                handler()
            }
        }

        var count: Int { delivered.withLock { $0 } }
    }

    @Test("Zero verdicts over a real bring-up and a soak beside a contending reader")
    func theWatchdogStaysSilentOnAHealthyMachine() async throws {
        let requested = ProcessInfo.processInfo.environment["AEOLUS_WATCHDOG_SOAK_SECONDS"]
        let seconds = requested.flatMap { Int($0) } ?? 60
        let journal = TeardownJournal()
        let ticks = CountingTicks()
        let helper = HelperComposition.production(
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Watchdog"),
            teardown: TeardownSeams(
                sources: RecordingSignalSources(),
                terminate: { outcome in await journal.record(.exited(outcome)) }),
            watchdogTicks: ticks)

        await helper.bringUp()

        // Snapshots as well as the supervisors' own cycles, so the one connection is shared
        // the way a client attached to the daemon shares it.
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var snapshots = 0
        while ContinuousClock.now < deadline {
            _ = try await helper.authority.snapshot()
            snapshots += 1
            try await Task.sleep(for: .seconds(1))
        }

        await helper.shutDown()

        print(
            """
            watchdog soak on Mac16,5: \(seconds) s, \(ticks.count) ticks delivered, \
            \(snapshots) snapshots, \
            \(helper.cycleProgress.reading().completions) § 3 cycles completed, \
            \(await exits(of: journal).count) process endings
            """)
        // A floor of half the ticks the period promises: a loaded host may be late, but a
        // timer that delivered almost nothing was not watching.
        #expect(
            ticks.count >= seconds / 2, "the timer ticked \(ticks.count) times in \(seconds) s")
        #expect(
            helper.cycleProgress.reading().completions > 0, "§ 3 never completed a cycle")
        #expect(await exits(of: journal).isEmpty, "the watchdog ended a healthy helper")
    }
}
