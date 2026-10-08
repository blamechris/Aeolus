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
/// Every wait is bounded (thirty seconds), so a test that forgets to release it leaves a thread
/// that ends rather than one that lives as long as the process.
final class BlockedWriter: Sendable {

    private struct State {
        var started: [String] = []
        var consumed = ""
        var isParked = false
        var isReleased = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = DispatchSemaphore(value: 0)
    private let parkingFromLine: Int?
    private let failingFromLine: Int?
    private let outcomeWhenReleased: FileDescriptorWriter.Outcome
    private let delay: TimeInterval

    /// - Parameters:
    ///   - parkingFromLine: The one-based number of the first line that parks, and every line
    ///     after it. `nil` never parks.
    ///   - failingFromLine: The first line that fails at once with `.readerGone`, without
    ///     parking: a consumer that is gone.
    ///   - outcomeWhenReleased: What a parked write reports once released: `.readerGone` is a
    ///     consumer that left while the line was waiting.
    ///   - delay: Seconds a line takes to write when it does not park: a reader that is slow
    ///     rather than stopped. Real time, and small.
    init(
        parkingFromLine: Int? = 1, failingFromLine: Int? = nil,
        outcomeWhenReleased: FileDescriptorWriter.Outcome = .delivered, delay: TimeInterval = 0
    ) {
        self.parkingFromLine = parkingFromLine
        self.failingFromLine = failingFromLine
        self.outcomeWhenReleased = outcomeWhenReleased
        self.delay = delay
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
            state.withLock {
                $0.consumed += String(line[..<half])
                $0.isParked = true
            }
            _ = gate.wait(timeout: .now() + 30)
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
/// waits, in real time and for at most two seconds, until each pump has written everything it was
/// handed or is parked in a write that will not finish.
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
        for _ in 0..<2_000 {
            guard let sinks else { return }
            let output = sinks.standardOutput.status.isIdle || standardOutput.isParked
            let errors = sinks.standardError.status.isIdle || standardError.isParked
            if output && errors { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Releases whatever is parked and waits, in real time and for at most two seconds, until
    /// both pumps have written everything they were handed: the reader catching up.
    func drain() async {
        release()
        for _ in 0..<2_000 {
            guard let sinks else { return }
            if sinks.standardOutput.status.isIdle && sinks.standardError.status.isIdle { return }
            try? await Task.sleep(for: .milliseconds(1))
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
