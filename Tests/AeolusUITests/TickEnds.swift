import Testing

@testable import AeolusUI

extension SnapshotTestSupport {

    /// Runs one `tick()` of `viewModel` on a task of its own, and waits until it has returned.
    ///
    /// **Why no test awaits `tick()` directly** (#485 S5). A tick can wait on a source, a reader
    /// or a provider. A test's time limit ends a test by cancelling its task, and cancellation is
    /// cooperative: a tick suspended on a wait that ignores it — a continuation nothing resumes,
    /// for one — holds a test that awaited it directly, and the limit cannot end that test. This
    /// waits on a `TickReturn` instead, which the limit's cancellation does end, so a tick that
    /// never returns is a red. `LeaseScene.run(_:)` is the same shape for the lease driver's
    /// calls.
    ///
    /// The tick runs on the main actor, as it does when awaited directly; the test resumes once
    /// it has returned. Records an issue and returns `false` when the wait ended first.
    @MainActor
    @discardableResult
    static func tickEnds(
        _ viewModel: PollingViewModel, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let tick = TickReturn()
        Task { @MainActor in
            await viewModel.tick()
            tick.markReturned()
        }
        await tick.wait()
        if !tick.hasReturned {
            Issue.record("the tick did not return", sourceLocation: sourceLocation)
        }
        return tick.hasReturned
    }

    /// One tick's return, written by the task running it and waited for by the test.
    @MainActor
    final class TickReturn {
        private(set) var hasReturned = false
        private var waiter: CheckedContinuation<Void, Never>?

        func markReturned() {
            hasReturned = true
            waiter?.resume()
            waiter = nil
        }

        /// Suspends until the tick has returned, or until the waiting task is cancelled.
        func wait() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if hasReturned || Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiter = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor in self.abandon() }
            }
        }

        private func abandon() {
            waiter?.resume()
            waiter = nil
        }
    }
}
