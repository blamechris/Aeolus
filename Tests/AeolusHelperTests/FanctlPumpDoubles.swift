import Foundation
import os

@testable import fanctl

/// A writer that parks, and a reader's view of what it wrote.
///
/// `fanctl set` must never wait on a write, whatever the kernel does with it: a pipe at the
/// system's pipe-memory ceiling answers `poll` "writable" and then parks a write past every stop
/// request, and a pty under XOFF parks one too. Those states are not ones a test can make on this
/// machine without taking it to the ceiling, so this is the seam instead: a writer, given to a
/// `LinePump`, that **blocks until it is released**, for exactly as long as the test says.
///
/// It models the stream as a reader sees it (`consumed`): whole lines as they complete, and, while
/// parked, the **first half of the line it is parked on**, which is what a blocking `write(2)` of
/// a long line leaves in a pipe. Releasing it completes the line.
///
/// ## What ends a park
///
/// **The test does.** A park that ended on a clock would end when the clock said, not when the
/// test did, and a test waiting for its turn on the cooperative pool cannot say when that is. On
/// CI's pool of one (run 41341626972) three tests that had parked a writer ran for 198 s, the
/// whole step; a test that only wrote a line to a pipe and read it back was open for 174.6 s. The
/// ten-second bound this type used to have let the writer go at ten, and when the tests next
/// looked, it had finished its line and begun the next. So a park on the pump's own thread waits
/// for `release()`, which every test calls from a `defer`, and has a bound (`failsafe`) only so
/// that a thread nothing can release ends with the process: it is longer than any run
/// (docs/TESTING.md, "The rule").
///
/// **The exception is a write that a task is running**, which is a write on a caller's thread:
/// the regression `LinePump` exists to prevent. The thread that would call `release()` is the one
/// that is parked, so nothing can release it, and it lets go after `callerFailsafe` so that the
/// test fails on what it then sees and does not hang the process. A slow pool cannot trip that
/// bound, because a correct pump never writes there.
///
/// **No pool thread is held while a pump's thread is parked**: the parked thread is the pump's
/// own `Thread`, and the test only suspends.
final class BlockedWriter: Sendable {

    /// How long a write parked on a pump's own thread waits to be released: thirty minutes, the
    /// longest limit any job in `ci.yml` has (`Test (release)`). The pool-of-one step is limited
    /// to ten, and `docs/TESTING.md` runs it under twenty. The suite's `.timeLimit` is no guide:
    /// it is a minute, and on a pool of one the tests it covers ran for up to 198 s.
    static let failsafe: TimeInterval = 30 * 60

    /// How long a write parked on a task's thread waits. Nothing can release it, so this is only
    /// how long a regression takes to show.
    static let callerFailsafe: TimeInterval = 10

    private struct State {
        var started: [String] = []
        var consumed = ""
        var isParked = false
        var isReleased = false
        var lastPark: Park?
    }

    /// Whose thread a write parked, which is what picks its bound.
    enum Park: Sendable, Equatable {
        /// The pump's own `Thread`: only the test's `release()` ends it, or `failsafe`.
        case pumpThread
        /// A thread a task is running: the pump's guarantee was broken. Only `callerFailsafe`.
        case callerThread
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = DispatchSemaphore(value: 0)
    private let parkingFromLine: Int?
    private let failingFromLine: Int?
    private let outcomeWhenReleased: FileDescriptorWriter.Outcome
    private let delay: TimeInterval
    private let pumpWait: TimeInterval
    private let callerWait: TimeInterval

    /// - Parameters:
    ///   - parkingFromLine: The one-based number of the first line that parks, and every line
    ///     after it. `nil` never parks.
    ///   - failingFromLine: The first line that fails at once with `.readerGone`, without
    ///     parking: a consumer that is gone.
    ///   - outcomeWhenReleased: What a parked write reports once released: `.readerGone` is a
    ///     consumer that left while the line was waiting.
    ///   - delay: Seconds a line takes to write when it does not park: a reader that is slow
    ///     rather than stopped. Real time, and small.
    ///   - failsafe: How long a park on a pump's thread waits for `release()`. For the tests of
    ///     this type only; every other caller takes ``failsafe``.
    ///   - callerFailsafe: The same for a park on a task's thread. For the tests of this type.
    init(
        parkingFromLine: Int? = 1, failingFromLine: Int? = nil,
        outcomeWhenReleased: FileDescriptorWriter.Outcome = .delivered, delay: TimeInterval = 0,
        failsafe: TimeInterval = BlockedWriter.failsafe,
        callerFailsafe: TimeInterval = BlockedWriter.callerFailsafe
    ) {
        self.parkingFromLine = parkingFromLine
        self.failingFromLine = failingFromLine
        self.outcomeWhenReleased = outcomeWhenReleased
        self.delay = delay
        self.pumpWait = failsafe
        self.callerWait = callerFailsafe
    }

    var write: LinePump.Write {
        { [self] line in
            let (parks, fails) = state.withLock { state -> (Bool, Bool) in
                state.started.append(line)
                let number = state.started.count
                let fails = failingFromLine.map { number >= $0 } ?? false
                guard let from = parkingFromLine, !state.isReleased else { return (false, fails) }
                return (number >= from, fails)
            }
            if fails { return .readerGone }
            guard parks else {
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                state.withLock { $0.consumed += line + "\n" }
                return .delivered
            }
            let half = line.index(line.startIndex, offsetBy: line.count / 2)
            // A task running this write means it is on a caller's thread, where nothing can
            // release it: a pump's thread is a `Thread` and runs no task.
            let park: Park = withUnsafeCurrentTask { $0 != nil } ? .callerThread : .pumpThread
            state.withLock {
                $0.consumed += String(line[..<half])
                $0.isParked = true
                $0.lastPark = park
            }
            _ = gate.wait(timeout: .now() + (park == .callerThread ? callerWait : pumpWait))
            state.withLock {
                $0.isParked = false
                if self.outcomeWhenReleased.isDelivered {
                    $0.consumed += String(line[half...]) + "\n"
                }
            }
            return outcomeWhenReleased
        }
    }

    /// Lets every parked write finish, and none after this park.
    func release() {
        state.withLock { $0.isReleased = true }
        for _ in 0..<16 { gate.signal() }
    }

    var isParked: Bool { state.withLock { $0.isParked } }

    /// Whose thread the most recent park was on, or `nil` if none has happened.
    var lastPark: Park? { state.withLock { $0.lastPark } }

    /// Every line the writer was given, whole.
    var started: [String] { state.withLock { $0.started } }

    /// What a reader of the stream has: complete lines, and the first half of one that is parked.
    var consumed: String { state.withLock { $0.consumed } }

    /// The newline-terminated lines of `consumed`.
    var completeLines: [String] {
        let parts = consumed.components(separatedBy: "\n")
        return Array(parts.dropLast())
    }

    /// What follows the last newline: a fragment, or nothing.
    var fragment: String { consumed.components(separatedBy: "\n").last ?? "" }

    /// The complete lines that are JSON objects, decoded.
    func events() -> [[String: Any]] {
        completeLines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }
}

/// The pumps one run built, with the writers under them, so a test can wait for them.
///
/// A real thread under a virtual clock is a race: the hold can sleep ten virtual seconds in the
/// microseconds before the pump's thread has written a line it was handed. `quiesce` is the
/// answer, and it belongs in the clock's script, so it runs before any virtual time passes: it
/// waits until each pump has written everything it was handed or is parked in a write that will
/// not finish, for `StallTolerantWait.deliveryBudget` of scheduled time (a runner stall is not
/// spent from it; it was two seconds of wall time, the budget `LinePumpTests` ran out of on CI).
final class PumpRig: Sendable {

    let standardOutput: BlockedWriter
    let standardError: BlockedWriter
    private let built = OSAllocatedUnfairLock<OutputSinks?>(initialState: nil)
    private let acted = OSAllocatedUnfairLock(initialState: false)

    /// Standard output parks from `parkingFromLine`; standard error takes everything unless a
    /// writer of its own is given.
    convenience init(
        parkingFromLine: Int? = nil, failingFromLine: Int? = nil,
        standardError: BlockedWriter = BlockedWriter(parkingFromLine: nil)
    ) {
        self.init(
            standardOutput: BlockedWriter(
                parkingFromLine: parkingFromLine, failingFromLine: failingFromLine),
            standardError: standardError)
    }

    init(standardOutput: BlockedWriter, standardError: BlockedWriter) {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// A terminal whose `set` lines go to threaded pumps over the two writers.
    var terminal: Terminal {
        Terminal(sinks: { [self] in
            let sinks = OutputSinks(
                standardOutput: LinePump(
                    threaded: "test.standard-output", write: standardOutput.write),
                standardError: LinePump(threaded: "test.standard-error", write: standardError.write)
            )
            built.withLock { $0 = sinks }
            return sinks
        })
    }

    var sinks: OutputSinks? { built.withLock { $0 } }

    func release() {
        standardOutput.release()
        standardError.release()
    }

    func quiesce() async {
        await settle { [self] sinks in
            let output = sinks.standardOutput.status.isIdle || standardOutput.isParked
            let errors = sinks.standardError.status.isIdle || standardError.isParked
            return output && errors
        }
    }

    /// Releases whatever is parked and waits, as `quiesce` does, until both pumps have written
    /// everything they were handed: the reader catching up.
    func drain() async {
        release()
        await settle { $0.standardOutput.status.isIdle && $0.standardError.status.isIdle }
    }

    /// Polls `done` until it holds, or there are no pumps yet, or the delivery budget is spent:
    /// then returns, as the two-second loops it replaced did, and leaves the assertions after it
    /// to say what was wrong.
    private func settle(_ done: @Sendable (OutputSinks) -> Bool) async {
        _ = try? await StallTolerantWait.poll(
            timeout: StallTolerantWait.deliveryBudget, interval: .milliseconds(1),
            clock: SystemWaitClock()
        ) { [self] in
            guard let sinks else { return true }
            return done(sinks)
        }
    }

    /// A clock script that quiesces before each sleep, and runs `action` once, the first time
    /// standard output is parked: the moment something happens to a hold whose consumer has
    /// stopped.
    func script(onceParked action: (@Sendable () -> Void)? = nil) -> VirtualHoldTime.Script {
        { [self] _, _ in
            await quiesce()
            guard let action, standardOutput.isParked else { return }
            let first = acted.withLock { acted -> Bool in
                defer { acted = true }
                return !acted
            }
            if first { action() }
        }
    }
}
