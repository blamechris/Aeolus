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
///
/// ## It watches for the one thing it would otherwise hide
///
/// Two subset reads can only be inside this provider at once if `SMCReadScheduler`'s
/// mutual exclusion has broken — the single property it exists to enforce. An earlier
/// version parked waiters in one `CheckedContinuation?` slot, so a second arrival
/// *overwrote* the first and orphaned it: the suite hung, with
/// `SWIFT TASK CONTINUATION MISUSE` on stderr and no failing assertion, which is the
/// worst way for a safety fixture to react to its subject being broken. Deleting
/// `isTurnInFlight = true` from `admitNext()` — precisely the window `takeTurn`'s comment
/// warns about — left all seven tests green, because nothing here was watching.
///
/// So overlap is now *recorded* and asserted on, and every waiter is kept. Same reasoning
/// as `AnonymousListenerTests`'s `.timeLimit`, one file away: a green suite must mean the
/// tests ran.
actor GatedSensorProvider: SensorProvider {

    nonisolated let identifier = "gated"

    /// One entry per turn that reached the provider, in arrival order.
    private(set) var turns: [[String]] = []
    private(set) var readAllCount = 0
    private(set) var readAllIsInFlight = false

    /// The most subset reads that were ever inside this provider at the same moment.
    ///
    /// One, always, for as long as the scheduler grants turns one at a time. This is the
    /// mutual-exclusion assertion's only source, and it is a high-water mark rather than a
    /// flag so that a test can say how badly it broke.
    private(set) var peakConcurrentTurns = 0
    private var concurrentTurns = 0

    private var subsetIsOpen: Bool
    /// Every parked waiter, never just the latest. See this type's documentation: a single
    /// slot silently drops the evidence of the failure worth catching.
    private var subsetWaiters: [CheckedContinuation<Void, Never>] = []
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
        concurrentTurns += 1
        peakConcurrentTurns = max(peakConcurrentTurns, concurrentTurns)
        await hold()
        concurrentTurns -= 1
        return keys.map { SensorReadOutcome(key: $0, result: .reading($0, 1)) }
    }

    /// Lets the turn currently at the provider finish.
    func releaseOneTurn() {
        guard !subsetWaiters.isEmpty else {
            subsetCredits += 1
            return
        }
        subsetWaiters.removeFirst().resume()
    }

    /// Stops holding turns, so the queue drains in whatever order the scheduler admits it.
    func releaseEveryTurn() {
        subsetIsOpen = true
        let parked = subsetWaiters
        subsetWaiters.removeAll()
        for waiter in parked { waiter.resume() }
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
        await withCheckedContinuation { subsetWaiters.append($0) }
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
/// `sourceLocation` is defaulted from the call site, like the sibling `waitUntil` does, so
/// a timeout names the wait that failed rather than this function's own line — which is
/// most of the diagnostic value the `Issue.record` was added for.
func yieldUntil(
    _ description: String,
    within yields: Int = 10_000,
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<yields {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
}

/// A provider that fails the first subset read it is given and answers normally afterwards.
///
/// The fixture for the one invariant in `SMCReadScheduler` whose failure is unrecoverable:
/// a turn that is taken and not given back wedges the helper's only SMC reader for the life
/// of the process, silently, because waiting at the gate is deliberately not cancellable.
actor ThrowOnceProvider: SensorProvider {

    nonisolated let identifier = "throw-once"

    private(set) var requests = 0
    private var hasThrown = false

    var isAvailable: Bool {
        get async { true }
    }

    func readAll() async throws -> [SensorReading] { [] }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        requests += 1
        if !hasThrown {
            hasThrown = true
            throw FakeProviderError(description: "the connection dropped mid-read")
        }
        return keys.map { SensorReadOutcome(key: $0, result: .reading($0, 1)) }
    }
}

/// A provider that fails on exactly one turn, counting from one, and answers every other.
///
/// The multi-turn sibling of `ThrowOnceProvider`. `read(keys:at:)` holds its turn from
/// `takeTurn` on the first slice and from `yieldTurn` on every one after, so a throw on a
/// later slice exercises a different acquisition path to a throw on the first — and the
/// single `defer` has to cover both.
///
/// It fails on *one* turn rather than on every turn from N onwards, because the assertion
/// that follows the throw is another read: a provider that stayed broken would fail that
/// read for its own reason and say nothing about whether the turn came back.
actor ThrowOnLaterTurnProvider: SensorProvider {

    nonisolated let identifier = "throw-later"

    private let failingTurn: Int
    private(set) var requests = 0

    init(failingTurn: Int) {
        self.failingTurn = failingTurn
    }

    var isAvailable: Bool {
        get async { true }
    }

    func readAll() async throws -> [SensorReading] { [] }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        requests += 1
        guard requests != failingTurn else {
            throw FakeProviderError(description: "the connection dropped on turn \(requests)")
        }
        return keys.map { SensorReadOutcome(key: $0, result: .reading($0, 1)) }
    }
}

/// A task plus a flag it sets on its way out, so another task can tell it finished without
/// joining it.
struct ObservableWork<Value: Sendable> {
    let task: Task<Value, any Error>
    let isFinished: CompletionFlag
}

/// Starts `work` as an observable task.
///
/// The point is the pairing: `await task.value` is an **unbounded** wait, and a scheduler
/// that stops granting turns makes it hang for ever. `.timeLimit` on each suite is the
/// backstop, but a backstop reports a killed test rather than a failed assertion, at a
/// minute a time — which is [#109](https://github.com/blamechris/Aeolus/issues/109)'s
/// complaint almost exactly. Pair this with `finished(_:_:)` below and a wedged scheduler
/// is a red expectation in milliseconds, naming what never completed.
func observing<Value: Sendable>(
    _ work: @escaping @Sendable () async throws -> Value
) -> ObservableWork<Value> {
    let flag = CompletionFlag()
    let task = Task<Value, any Error> {
        do {
            let value = try await work()
            await flag.mark()
            return value
        } catch {
            await flag.mark()
            throw error
        }
    }
    return ObservableWork(task: task, isFinished: flag)
}

/// Waits for `work` to finish and returns its value, or records an issue and returns `nil`.
///
/// Never joins a task that has not finished, so a wedged scheduler ends the test instead of
/// hanging it.
@discardableResult
func finished<Value: Sendable>(
    _ description: String,
    _ work: ObservableWork<Value>,
    within yields: Int = 10_000,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> Value? {
    await yieldUntil(description, within: yields, { await work.isFinished.isSet })
    guard await work.isFinished.isSet else {
        work.task.cancel()
        Issue.record(
            "\(description) never completed — the scheduler is not granting turns",
            sourceLocation: sourceLocation)
        return nil
    }
    return try await work.task.value
}
