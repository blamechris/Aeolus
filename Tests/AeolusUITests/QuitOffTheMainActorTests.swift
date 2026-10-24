import AeolusXPC
import AeolusXPCClient
import Foundation
import Testing
import os

@testable import AeolusLeaseControl
@testable import AeolusUI

/// A quit never waits for the main actor (#493's review, C-1).
///
/// After `.terminateLater`, AppKit spins the run loop inside the callout that asked to quit, and
/// when that callout is a main-queue job nothing else on the main actor runs until the reply. These
/// tests hold the main actor the same way, without AppKit: the test's own main-actor job does not
/// return or suspend until what it waits for has happened, and each wait is bounded.
///
/// What only an AppKit probe can show is that AppKit's nested loop really does hold the main
/// actor; the reviewers' standalone probes did, and the PR records them. What these show is that
/// the quit's release, and the shipping run loop's reply, need nothing from a held main actor.
@Suite("Quit — never waits for the main actor", .timeLimit(.minutes(1)))
@MainActor
struct QuitOffTheMainActorTests {

    /// The release goes out while the main actor stays held by the job that asked to quit.
    ///
    /// **Mutation (R3, "the shutdown on the main actor"):** in
    /// `LeaseLifecycle.applicationShouldTerminate`, start the shutdown with `Task {` instead of
    /// `Task.detached {`, so it inherits the main actor, as before #493's review. Red at `sent`,
    /// after the five-second bound.
    @Test("A quit asked for inside a main-actor job releases while that job still holds the actor")
    func aQuitFromAHeldMainActorStillReleases() async throws {
        let scene = await CompositionScene(runLoop: .parked)
        let held = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        let releaseSent = DispatchSemaphore(value: 0)
        let ledger = scene.lease.ledger
        let watcher = Task.detached {
            await ledger.waitFor { $0.releases == [held.lease.id] }
            releaseSent.signal()
        }

        #expect(
            scene.root.applicationShouldTerminate(reply: scene.lease.recordReply) == .terminateLater
        )
        // This job now holds the main actor, as the callout that called `terminate(_:)` would.
        let sent = Self.holdTheMainActor(until: releaseSent, atMost: 5)
        watcher.cancel()

        #expect(sent, "the release waited for the main actor")
        try #require(
            await SnapshotTestSupport.eventually { scene.runLoop.performed == 1 },
            "the reply was handed to the main run loop")
        // Read before the test delivers anything, so it is the quit's own order that is looked at
        // and not the order the test chose for the delivery. It is a sample taken after the
        // hand-over was seen, so it is the weaker half; the stronger one, `performed == 0` while
        // the release is parked, is `AppCompositionLeaseTests.quitRepliesAfterTheTeardown`.
        #expect(
            await scene.lease.entries.index(of: .disconnect) != nil,
            "the connection was not torn down when the reply was handed over")
        scene.runLoop.runParked()
        await scene.lease.ledger.waitFor { !$0.terminationReplies.isEmpty }
        #expect(await scene.lease.entries.terminationReplies == [true])
        await scene.finish()
    }

    /// The shipping `MainRunLoop` runs its block on the main thread while a main-actor job is still
    /// running: this test's job, which spins the main run loop in a nested mode instead of
    /// returning, as AppKit's `.terminateLater` loop does.
    ///
    /// **Mutation (R4, "the run loop through the main actor"):** in `MainRunLoop.perform`, replace
    /// `CFRunLoopPerformBlock` and `CFRunLoopWakeUp` with `Task { @MainActor in block() }`. Red at
    /// `ran`: the block waits for this job to end, which it does not while it waits.
    @Test("The main run loop delivers a block inside a main-actor job that has not returned")
    func theMainRunLoopDeliversInsideAHeldMainActor() {
        let ran = OSAllocatedUnfairLock(initialState: false)
        MainRunLoop().perform { ran.withLock { $0 = true } }

        // At most forty turns; each returns at once if the mode has nothing queued, so the block,
        // queued before the loop, runs on the first. Each turn runs the main run loop, nested in
        // this job, in its default mode, which is one of its common modes. That is why this cannot
        // pin the wake-up or the modes: a loop that spins in short turns wakes itself, and the
        // default mode is the one every spelling of `perform` reaches. The next test pins both.
        for _ in 0..<40 where !ran.withLock({ $0 }) {
            _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, true)
        }

        #expect(ran.withLock { $0 }, "the block waited for the main actor")
    }

    /// The shipping `MainRunLoop` wakes a main run loop that is asleep in a mode other than the
    /// default one, and its block runs there (#495, from #493's review).
    ///
    /// AppKit's `.terminateLater` loop sleeps in `NSModalPanelRunLoopMode` with a long timeout. A
    /// block queued from another thread reaches it only if the queue also wakes the loop, and only
    /// if the block is queued for that mode. Otherwise the reply waits for the next unrelated
    /// event: the quit hangs and the heartbeat goes on renewing, which was C-1's symptom. The test
    /// above cannot see either, because it spins in short turns of the default mode.
    ///
    /// This puts the main run loop to sleep in a mode of its own, which it adds to its common
    /// modes as AppKit does for its modal mode, with a timer an hour away so the mode has
    /// something to wait on (without one the run returns at once). A thread of its own queues the
    /// block through `MainRunLoop` once the loop is about to sleep.
    ///
    /// **Mutation (M1, "no wake-up"):** in `MainRunLoop.perform`, delete `CFRunLoopWakeUp(main)`.
    /// Red at the elapsed bound: the block runs only when the nested run times out, after the full
    /// five seconds, and `ran` is true by then.
    /// **Mutation (M2, "the default mode"):** in `MainRunLoop.perform`, queue for
    /// `CFRunLoopMode.defaultMode.rawValue` instead of `.commonModes.rawValue`. Red at `ran` and at
    /// the elapsed bound: the block belongs to a mode this loop is not in.
    @Test("The main run loop wakes a loop asleep in another common mode, and runs the block there")
    func theMainRunLoopWakesALoopAsleepInAnotherMode() throws {
        // The nested run below is this thread's. On any other thread it would be that thread's
        // own run loop, and the shipping one would never be asked to deliver anything.
        try #require(pthread_main_np() != 0, "this test must run on the main thread")

        let main = CFRunLoopGetMain()
        let mode = CFRunLoopMode("dev.aeolus.tests.quit-reply-wake-up" as CFString)
        CFRunLoopAddCommonMode(main, mode)
        let idle = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0
        ) { _ in }
        let asleep = DispatchSemaphore(value: 0)
        let aboutToSleep = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { _, _ in asleep.signal() }
        CFRunLoopAddTimer(main, idle, mode)
        CFRunLoopAddObserver(main, aboutToSleep, mode)
        defer {
            CFRunLoopRemoveObserver(main, aboutToSleep, mode)
            CFRunLoopRemoveTimer(main, idle, mode)
            CFRunLoopTimerInvalidate(idle)
        }

        // `nested` is true only while this test's own run is in progress, and the block stops a
        // run only then. A block that arrives late runs in the test runner's own loop, and a stop
        // there ends that loop: the process exits 0 with a truncated log (#495's trap).
        let state = OSAllocatedUnfairLock(initialState: NestedRun())
        Thread.detachNewThread {
            // Bounded: if the observer never fires, it is queued anyway and the elapsed bound fails.
            _ = asleep.wait(timeout: .now() + 5)
            MainRunLoop().perform {
                let stop = state.withLock { run -> Bool in
                    run.ran = true
                    return run.nested
                }
                if stop { CFRunLoopStop(CFRunLoopGetMain()) }
            }
        }

        let began = ContinuousClock.now
        _ = CFRunLoopRunInMode(mode, 5, false)
        let elapsed = ContinuousClock.now - began
        let ran = state.withLock { run -> Bool in
            run.nested = false
            return run.ran
        }

        #expect(ran, "the block never ran in the loop that was asleep")
        #expect(elapsed < .seconds(3), "the loop slept until its own timeout: nothing woke it")
    }

    /// The quit's reply is handed to the run loop from a thread that is not the main thread: the
    /// shutdown before it runs on a detached task, not on the main actor (#495, from #493's
    /// review).
    ///
    /// The same mutation as the first test's, with no budget. That test waits on a held main
    /// actor under a five-second bound of real time, so it can fail on a stalled runner, and in
    /// the safe direction only. This one reads which thread `perform` was called on, and the first
    /// stays as the end-to-end proof.
    ///
    /// **Mutation (R3, "the shutdown on the main actor"):** in
    /// `LeaseLifecycle.applicationShouldTerminate`, start the shutdown with `Task {` instead of
    /// `Task.detached {`. Its continuation after `shutDown()` resumes on the main actor, so the
    /// hand-over comes from the main thread. Red at the expectation that it did not.
    @Test("A quit hands its reply to the run loop from off the main thread")
    func theQuitHandsTheReplyOverFromOffTheMainThread() async throws {
        let scene = await LeaseScene()
        _ = try #require(await scene.take(LeaseScene.target([0: 3000])))
        let runLoop = ThreadRecordingRunLoop()
        let lifecycle = LeaseLifecycle(driver: scene.driver, mainRunLoop: runLoop)

        lifecycle.applicationShouldTerminate(reply: { _ in })
        // This test's job suspends here, so it holds nothing: the quit is free to take the main
        // actor if it was written to.
        try #require(
            await SnapshotTestSupport.eventually { runLoop.fromMainThread.count == 1 },
            "the reply was handed to the run loop")

        #expect(runLoop.fromMainThread == [false], "the hand-over came from the main thread")
        await scene.finish()
    }

    /// Blocks the calling thread, the main thread here, until `semaphore` is signalled or `seconds`
    /// pass, and says which. Synchronous on purpose: it is the main actor held, not suspended. Only
    /// the main thread is blocked; every task the quit needs runs on the cooperative pool.
    nonisolated static func holdTheMainActor(
        until semaphore: DispatchSemaphore, atMost seconds: Double
    ) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}

/// What the main-thread-run's block has seen: whether it ran, and whether the run it was queued
/// for is still in progress.
private struct NestedRun: Sendable {
    var ran = false
    var nested = true
}

/// A `MainRunLoopPerforming` that records, for each hand-over, whether the thread that made it was
/// the main thread, and runs nothing.
private final class ThreadRecordingRunLoop: MainRunLoopPerforming {

    private let handOvers = OSAllocatedUnfairLock(initialState: [Bool]())

    /// For each block handed to `perform`, in order: whether `perform` was called on the main thread.
    var fromMainThread: [Bool] { handOvers.withLock { $0 } }

    func perform(_ block: @escaping @MainActor @Sendable () -> Void) {
        handOvers.withLock { $0.append(pthread_main_np() != 0) }
    }
}
