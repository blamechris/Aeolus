import Foundation

// The default bound on how long a caller of `releaseFans()` waits for a release, and the wait
// itself.
//
// **Nothing here touches the driver's state**, which is why it can live outside
// `LeaseDriver.swift` (#504); everything that does stays `private` there. The wait is handed the
// release, the deadline, the bound and the clock.
extension LeaseDriver {

    /// How long a release waits for the helper's answer before its caller is let go.
    ///
    /// **Two seconds, stated rather than measured.** It bounds how long a quit, a logout or a
    /// window close waits. Past it the release is still in flight, and the lease ends on the
    /// helper's answer or, at the latest, at its TTL, since nothing renews it any more; on a quit
    /// the teardown that follows ends it at once. Shorter than `HelperClientDeadlines.gatedVerb`,
    /// so it is this bound, not the client's, that lets a quit go.
    public static let releaseBound: Duration = .seconds(2)

    /// Waits for `release`, or until `deadline` on `clock`, whichever is first.
    static func outcome(
        of release: Task<ReleaseOutcome, Never>, until deadline: ContinuousClock.Instant,
        bound: Duration, on clock: any HeartbeatClock
    ) async -> ReleaseOutcome {
        await withCheckedContinuation { continuation in
            let first = FirstAnswer(continuation)
            let timer = Task {
                do { try await clock.sleep(until: deadline) } catch { return }
                await first.resume(returning: .notAnswered(within: bound))
            }
            Task {
                let outcome = await release.value
                timer.cancel()
                await first.resume(returning: outcome)
            }
        }
    }
}

/// Resumes a continuation once, with whichever answer reaches it first.
private actor FirstAnswer {
    private var continuation: CheckedContinuation<ReleaseOutcome, Never>?

    init(_ continuation: CheckedContinuation<ReleaseOutcome, Never>) {
        self.continuation = continuation
    }

    func resume(returning outcome: ReleaseOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
