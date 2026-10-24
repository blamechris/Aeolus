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
        scene.runLoop.runParked()
        await scene.lease.ledger.waitFor { !$0.terminationReplies.isEmpty }
        let entries = await scene.lease.entries
        let disconnected = try #require(entries.index(of: .disconnect))
        let replied = try #require(entries.index(of: .terminationReplied(true)))
        #expect(disconnected < replied)
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

        // Bounded at forty turns of 50 ms. Each turn runs the main run loop, nested in this job,
        // in its default mode, which is one of its common modes.
        for _ in 0..<40 where !ran.withLock({ $0 }) {
            _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, true)
        }

        #expect(ran.withLock { $0 }, "the block waited for the main actor")
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
