import Foundation

/// Runs a block on the main thread from the main **run loop**, not from the main actor's queue.
///
/// ## Why the quit's reply cannot go through the main actor
///
/// `NSApplication.TerminateReply.terminateLater` makes AppKit run the main run loop in
/// `NSModalPanelRunLoopMode` *inside* the callout that asked to quit, until
/// `reply(toApplicationShouldTerminate:)` is called. The main actor's executor is the main dispatch
/// queue, which is serial. When `terminate(_:)` is reached from inside a main-queue job, a
/// `@MainActor` `Task` or a `DispatchQueue.main` block, that job is still running for as long as
/// the nested loop spins, so nothing else on the main queue runs: a `@MainActor` task that was to
/// release the lease and reply never starts. The release is never sent, the heartbeat, which runs
/// off the main actor, goes on renewing, and the process never exits (#493's review, by probe).
///
/// A block added to the main run loop in its common modes does run there: AppKit adds
/// `NSModalPanelRunLoopMode` to them. So the quit's release runs off the main actor entirely, and
/// only its reply comes back to the main thread, through this.
public protocol MainRunLoopPerforming: Sendable {

    /// Runs `block` on the main thread, from the main run loop in its common modes, soon.
    func perform(_ block: @escaping @MainActor @Sendable () -> Void)
}

/// The shipping conformance: `CFRunLoopPerformBlock` on the main run loop, in its common modes,
/// then `CFRunLoopWakeUp` so a run loop asleep in `NSModalPanelRunLoopMode` notices it.
public struct MainRunLoop: MainRunLoopPerforming {

    public init() {}

    public func perform(_ block: @escaping @MainActor @Sendable () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { block() }
        }
        CFRunLoopWakeUp(main)
    }
}
