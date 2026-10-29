import Foundation
import Testing

@testable import AeolusHelper

// The seams #368's tests park a teardown and a revocation on. Every park is a continuation —
// an `AsyncSignal`, or the lease core's own waiter — so no thread is blocked, and every wait the
// fix could turn into a hang is bounded by a budget that only a failure reaches.

/// How long a test waits for something the fix might park before it calls it a hang: scheduled
/// waiting time, not wall time ([#547](https://github.com/blamechris/Aeolus/issues/547)).
///
/// **Failure-only, by margin, not by construction.** Nothing but this ceiling bounds the 30
/// settling waits (revocations, sweeps, § 5 cycles). Every return of `revocationProgress` and
/// `finishedBeforeCeiling` was timed in twelve `swift test` runs on `Mac16,5`, the three hardware
/// suites skipped (58 holds each in `AeolusHelperTests`, from 41 calling lines; #461). The longest
/// hold, and about how many times it fits under this ceiling, by load added with `yes`:
///
/// - none, three runs: 0.27 s over the 30 settling sites (about 37 times); 0.57 s over the 11 in
///   `ParkingCeilingTests` (about 17 times).
/// - two `yes`, four runs: 0.35 s (about 28 times); 3.4 s (2.9 times).
/// - 32 `yes`, three runs: 0.46 s (about 21 times); 2.5 s (4.0 times).
/// - 64 `yes`, two runs: 0.42 s (about 23 times); 2.2 s (4.4 times).
///
/// The machine was shared and never idle. The maxima rose from the runs with none added to the
/// loaded runs, but not steadily with the load added: the longest hold came from a run with two
/// `yes`, not 64. In that run six `ParkingCeilingTests` waits, including one signalled at once,
/// were held 3.2 to 3.4 s, ending within about 0.26 s of one another; the same six end close
/// together in every run, with no load added too. No park ceiling explains it; the cause was not
/// found.
///
/// So this leaves 2.9 times the worst hold seen, and lowering it below about 3.4 s would have
/// expired a passing test's wait.
///
/// **A stall is not spent from it.** Both outwaits below, `finishedBeforeCeiling` and
/// `revocationProgress`, are `waitUntil` over this budget, so a poll that comes back more than
/// 250 ms late has the difference added to its deadline (`StallTolerantWait`), up to that wait's
/// 50 s cap. They used to measure it on the wall clock, and a runner that stopped the test
/// process for longer than this (about 30 s in #439; tests that take milliseconds took 30 to 44 s
/// in the two runs #547 is about) spent every wait in flight at once, so a double that had done
/// nothing wrong read as one that had lost its ceiling.
///
/// **A slow or stuck hold is not what is compensated; a late poll is.** The condition is a flag
/// read and the 1 ms sleep is asked for again each time it returns, so a hold that is merely slow
/// or stuck adds nothing, and what a wait that really is stuck reports depends on the pool it ran
/// on. On a real clock, a test of `finishedBeforeCeiling` on work that never finishes (removed in
/// #558 for its 10 s, which was CI's slowest test at 52 s of a 60 s limit) gave up at "10.0 s of
/// waiting (plus 0.0 s of runner stall compensated)" in all 20 runs of the four outwait and park
/// suites alone, 10 debug and 10 release. In a run of the whole target, with nothing stopped, the
/// same wait was compensated for a pool busy with other tests: 2.3 s in a local debug run, 0.5 s
/// in a local release run, and 7.8 s in CI's debug step and 4.0 s in its release step (run
/// 40828896951). So a stuck wait runs past this ceiling by what the pool made its polls late, to
/// the 50 s cap at most. What compensation cannot tell from a stall is an iteration the process
/// did not run for another reason: the OS descheduling it, or a cooperative pool with every
/// thread blocked. Those are compensated as well, and the issue says how much.
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
/// neither arrives within `outwaitCeiling` of scheduled waiting time, which a runner stall does
/// not spend (#547).
///
/// `clock` and `note` are `waitUntil`'s. There is one function and not a shipping forward over an
/// injectable overload, so a test that drives it with a clock that can come back late runs the
/// body every call site runs (#551).
func revocationProgress(
    of work: ObservableWork<some Sendable>,
    outwaiting fan: Int,
    in leases: LeaseAuthority,
    clock: some WaitClock = SystemWaitClock(),
    note: (String) -> Void = StallTolerantWait.writeToStandardError,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> RevocationProgress? {
    // The poll's last evaluation is what `waitUntil` acted on, so `progress` is `nil` exactly
    // when it recorded the timeout.
    var progress: RevocationProgress?
    try await outwait(
        (event: "the revocation to finish or park on fan \(fan)", ifItTimesOut: "it did neither"),
        clock: clock, note: note, sourceLocation: sourceLocation
    ) {
        if await work.isFinished.isSet {
            progress = .finished
        } else if await leases.fansARevocationAwaits.contains(fan) {
            progress = .waiting
        } else {
            progress = nil
        }
        return progress != nil
    }
    return progress
}

/// Waits for `work` to finish within `outwaitCeiling` of scheduled waiting time and returns its
/// value, or records an issue and returns `nil` **without joining it**.
///
/// `finished(_:_:within:)`'s contract with a clock in place of a yield count: a revocation a
/// mutant never resumes cannot be cancelled — the outwait installs no handler, by design — so
/// joining it would hang the run, and a yield count is a statement about the scheduler rather
/// than about time. A runner that stops the test process for longer than `outwaitCeiling` does
/// not turn a double that is about to return into one that never did (#547). The poll only
/// sleeps, so a `.timeLimit` that expires first cancels it; joining the task is the one
/// uncancellable step, and it is reached only for work that has finished.
///
/// `clock` and `note` are `waitUntil`'s. There is one function and not a shipping forward over an
/// injectable overload, so a test that drives it with a clock that can come back late runs the
/// body every call site runs (#551).
@discardableResult
func finishedBeforeCeiling<Value: Sendable>(
    _ description: String,
    _ work: ObservableWork<Value>,
    clock: some WaitClock = SystemWaitClock(),
    note: (String) -> Void = StallTolerantWait.writeToStandardError,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> Value? {
    // `waitUntil` records the timeout, and the last look at the flag is what it decided on, so
    // the work is joined exactly when no issue was recorded: a flag that flips between the
    // final look and a second one here would otherwise return a value beside a failure.
    var done = false
    try await outwait(
        (
            event: "\(description) to finish",
            ifItTimesOut: "something it awaits was never resumed"
        ), clock: clock, note: note, sourceLocation: sourceLocation
    ) {
        done = await work.isFinished.isSet
        return done
    }
    guard done else { return nil }
    return try await work.task.value
}

/// The one budget both outwaits above are held to: `outwaitCeiling` of waiting, polled each
/// millisecond, with `waitUntil`'s stall compensation and its cap.
///
/// `waiting.event` is what is waited for, and is all a passing wait's note says.
/// `waiting.ifItTimesOut` is why a timeout is a failure, and goes into the issue a timeout records
/// and nowhere else.
private func outwait(
    _ waiting: (event: String, ifItTimesOut: String),
    clock: some WaitClock,
    note: (String) -> Void,
    sourceLocation: SourceLocation,
    _ condition: () async -> Bool
) async throws {
    try await waitUntil(
        waiting.event, timeout: outwaitCeiling, interval: .milliseconds(1), clock: clock,
        note: note, ifItTimesOut: waiting.ifItTimesOut, condition,
        sourceLocation: sourceLocation)
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
