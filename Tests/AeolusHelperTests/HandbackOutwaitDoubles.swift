import Foundation
import Testing

@testable import AeolusHelper

// The seams #368's tests park a teardown and a revocation on. Every park is a continuation —
// an `AsyncSignal`, or the lease core's own waiter — so no thread is blocked, and every wait the
// fix could turn into a hang is bounded by a wall clock that only a failure reaches.

/// How long a test waits for something the fix might park before it calls it a hang.
///
/// **Failure-only, by margin, not by construction.** Nothing about a correct revocation, sweep or
/// § 5 cycle keeps it short of this: passing tests hold these waits for tenths of a second, and
/// `ParkingCeilingTests` held one for 3.4 s. Every return of `revocationProgress` and
/// `finishedBeforeCeiling` was timed over twelve whole non-hardware runs on `Mac16,5` (58 holds
/// each, from 41 calling lines; #461). The longest hold, and how many times it fits under this
/// ceiling, by load added with `yes`:
///
/// - none, three runs: 0.27 s over the 30 settling sites (37 times); 0.57 s over the 11 in
///   `ParkingCeilingTests` (17 times).
/// - two `yes`, four runs: 0.35 s (28 times); 3.4 s (2.9 times).
/// - 32 `yes`, three runs: 0.46 s (22 times); 2.5 s (4.1 times).
/// - 64 `yes`, two runs: 0.42 s (24 times); 2.2 s (4.5 times).
///
/// The machine was shared and never idle: its load average read 45 to 60 at the start of the
/// runs with none added. The longest hold came from a run with two `yes`, so its other work moved
/// these figures more than the load added did. In that run `ParkingCeilingTests`' wait that is
/// signalled at once held 3.2 s, which no park ceiling explains; the cause was not found.
///
/// So this leaves 2.9 times the worst hold seen, and lowering it below about 3.4 s would have
/// expired a passing test's wait. It does not cover a stall longer than itself: this is wall-clock
/// time, and a CI runner was starved for about 30 s in #439.
///
/// It exists so a mutant that never resumes a waiter fails red, naming what never finished,
/// instead of wedging the run behind a continuation nothing resumes — `CeilingedRefusal`'s
/// purpose, measured in seconds rather than in attempts because what it bounds is a wait, not a
/// retry loop.
let outwaitCeiling = Duration.seconds(10)

/// A `FanRestoring` decorator that can hold one restore **before** it forwards it (#368).
///
/// Armed, the next call signals `entered` and waits on `release`, and only then hands the fans to
/// the restorer it wraps. Over `HelperFanRestorer` that is the instant a lease-core teardown has
/// taken its lease out of the table and counted its fans into `releasing`, with its release
/// notice to § 5 not yet sent: the window #368 is about, held open. One-shot, like the signals.
actor ParkingFanRestorer: FanRestoring {

    let entered = AsyncSignal()
    let release = AsyncSignal()

    private let wrapped: any FanRestoring
    private var armed = false

    /// How many calls reached the wrapped restorer.
    private(set) var forwarded = 0

    init(over wrapped: any FanRestoring) {
        self.wrapped = wrapped
    }

    /// Holds the next call until `release` is signalled.
    func armNext() { armed = true }

    func restoreToAutomatic(fans: Set<Int>, because cause: FanRestoreCause) async -> Set<Int> {
        if armed {
            armed = false
            await entered.signal()
            // Swallowed for `RecordingFanRestorer`'s reason: `FanRestoring` does not throw, and
            // a cancelled wait is the test being torn down, not a restore that failed.
            try? await release.wait()
        }
        forwarded += 1
        return await wrapped.restoreToAutomatic(fans: fans, because: cause)
    }
}

/// Where a revocation that may be outwaiting a handback has got to.
enum RevocationProgress: Sendable, Equatable {
    /// It has returned.
    case finished
    /// The lease core holds it parked on the fan's handback.
    case waiting
}

/// The one poll (#368): waits until `work` has finished **or** `leases` holds a revocation
/// parked on `fan`, and says which.
///
/// Both states are absorbing until the test acts — a finished task stays finished, and a parked
/// revocation stays parked until the handback it outwaits is let go — so this waits for a state,
/// not for a number of yields, and whichever it finds is the answer
/// (`SnapshotAvailabilityDoubles.parkedHandback`'s shape). `nil`, with an issue recorded, when
/// neither arrives within `outwaitCeiling`.
func revocationProgress(
    of work: ObservableWork<some Sendable>,
    outwaiting fan: Int,
    in leases: LeaseAuthority,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> RevocationProgress? {
    let deadline = ContinuousClock.now + outwaitCeiling
    while ContinuousClock.now < deadline {
        if await work.isFinished.isSet { return .finished }
        if await leases.fansARevocationAwaits.contains(fan) { return .waiting }
        await Task.yield()
    }
    Issue.record(
        "the revocation neither finished nor parked on fan \(fan) within \(outwaitCeiling)",
        sourceLocation: sourceLocation)
    return nil
}

/// Waits for `work` to finish within `outwaitCeiling` of wall-clock time and returns its value,
/// or records an issue and returns `nil` **without joining it**.
///
/// `finished(_:_:within:)`'s contract with a wall clock in place of a yield count: a revocation a
/// mutant never resumes cannot be cancelled — the outwait installs no handler, by design — so
/// joining it would hang the run, and a yield count is a statement about the scheduler rather
/// than about time.
@discardableResult
func finishedBeforeCeiling<Value: Sendable>(
    _ description: String,
    _ work: ObservableWork<Value>,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> Value? {
    let deadline = ContinuousClock.now + outwaitCeiling
    while await !work.isFinished.isSet, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    guard await work.isFinished.isSet else {
        Issue.record(
            """
            \(description) did not finish within \(outwaitCeiling): something it awaits was \
            never resumed
            """,
            sourceLocation: sourceLocation)
        return nil
    }
    return try await work.task.value
}

/// § 5's cycles up to the terminal action, under `outwaitCeiling`.
///
/// The terminal action's revocation can park: a `.gone` answers only once the fan's handback has
/// returned (#368). In the tests that cycle to it, nothing is under way when it runs, so nothing
/// parks; a regression that parked it anyway would hang the test behind a continuation nothing
/// resumes, and `.timeLimit` cannot end a wait that is not cancellable. So every such test comes
/// through here — `FinaliseReleaseLedgerTests.cycleToTheTerminalAction(_:sourceLocation:)`
/// delegates to it — and a near-identical unbounded loop is not left beside it.
func cycledToTheTerminalAction<Plane: FanControlPlane>(
    _ watchdog: ReclamationWatchdog<Plane>,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let cycles = observing {
        for _ in 1...ReclamationLimits.blindCyclesBeforeDivergence { await watchdog.cycle() }
    }
    try await finishedBeforeCeiling(
        "§ 5's cycles to the terminal action", cycles, sourceLocation: sourceLocation)
}
