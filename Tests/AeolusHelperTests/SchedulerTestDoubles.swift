import SMCCore
import Testing

@testable import AeolusHelper

// The scripted timing doubles `SMCReadSchedulerTests` drives the scheduler with.
//
// Split from the suite itself only to keep both files under the 400-line lint threshold —
// see https://github.com/blamechris/Aeolus/issues/128 for the two production files already
// over it — and because this is where `AeolusHelperTests` puts its doubles already.

// MARK: - Doubles

/// A `SensorProvider` whose timing the test owns.
///
/// Turns are released explicitly rather than waited out, so nothing here depends on how
/// fast the machine running it is. Every operation records what it was asked for, in the
/// order it was asked, which is what makes the scheduler's admission order directly
/// assertable — the trace at the provider *is* the order turns were granted.
actor GatedSensorProvider: SensorProvider {

    nonisolated let identifier = "gated"

    /// One entry per turn that reached the provider, in arrival order.
    private(set) var turns: [[String]] = []
    private(set) var readAllCount = 0
    private(set) var readAllIsInFlight = false

    private var subsetIsOpen: Bool
    private var subsetWaiter: CheckedContinuation<Void, Never>?
    /// Releases banked before the turn they release arrived, so a test may release without
    /// first proving something is there to release.
    private var subsetCredits = 0

    private var readAllIsHeld: Bool
    private var readAllWaiter: CheckedContinuation<Void, Never>?

    init(holdingSubsetReads: Bool = false, holdingReadAll: Bool = false) {
        self.subsetIsOpen = !holdingSubsetReads
        self.readAllIsHeld = holdingReadAll
    }

    var isAvailable: Bool {
        get async { true }
    }

    func readAll() async throws -> [SensorReading] {
        readAllCount += 1
        readAllIsInFlight = true
        if readAllIsHeld {
            await withCheckedContinuation { readAllWaiter = $0 }
        }
        readAllIsInFlight = false
        return []
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        turns.append(keys)
        await hold()
        return keys.map { SensorReadOutcome(key: $0, result: .reading($0, 1)) }
    }

    /// Lets the turn currently at the provider finish.
    func releaseOneTurn() {
        guard let waiter = subsetWaiter else {
            subsetCredits += 1
            return
        }
        subsetWaiter = nil
        waiter.resume()
    }

    /// Stops holding turns, so the queue drains in whatever order the scheduler admits it.
    func releaseEveryTurn() {
        subsetIsOpen = true
        guard let waiter = subsetWaiter else { return }
        subsetWaiter = nil
        waiter.resume()
    }

    func releaseReadAll() {
        readAllIsHeld = false
        guard let waiter = readAllWaiter else { return }
        readAllWaiter = nil
        waiter.resume()
    }

    private func hold() async {
        if subsetIsOpen { return }
        if subsetCredits > 0 {
            subsetCredits -= 1
            return
        }
        await withCheckedContinuation { subsetWaiter = $0 }
    }
}

/// A one-way flag, so "this task got as far as here" is a fact another task can wait on.
actor CompletionFlag {
    private(set) var isSet = false
    func mark() { isSet = true }
}

/// Spins the cooperative pool until `condition` holds, and **fails rather than hangs** when
/// it never does.
///
/// A test that waits on an unbounded condition reports a regression as a killed CI job with
/// no assertion and no line number — [#109](https://github.com/blamechris/Aeolus/issues/109)
/// filed against exactly that shape. This one records an issue and returns, so the run
/// stays red rather than hung and the caller can go on to release whatever it was holding.
///
/// ## Not `waitUntil(_:timeout:interval:_:)`, and the name matters
///
/// `AnonymousListenerTests` already declares a global poller of its own, and the two are
/// not interchangeable: that one *sleeps*, because a libxpc invalidation is delivered by
/// another process on its own schedule and no amount of yielding brings it forward. This
/// one *yields*, because everything it waits for is a task on this thread's own cooperative
/// pool that only needs a chance to run.
///
/// They were briefly the same name. Swift resolved `try await waitUntil(…)` in those tests
/// to this non-throwing overload instead — the only outward sign being a
/// "no calls to throwing functions occur within 'try'" warning — and the 5-second sleeping
/// wait became a yield spin that finishes in microseconds, so
/// `invalidationCrossesTheSeam` began failing about one run in three. Two pollers with one
/// name is a hazard the compiler reports as a warning; distinct names are the fix.
func yieldUntil(
    _ description: String,
    within yields: Int = 10_000,
    _ condition: () async -> Bool
) async {
    for _ in 0..<yields {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(description)")
}
