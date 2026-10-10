import Foundation
import os

/// Where one stream's lines go, written by a thread of its own, so that **nothing that holds a
/// lease ever waits on a reader.**
///
/// `fanctl set` holds fans for as long as it is asked to, and it must keep proving it is alive
/// and must be able to stop. A `write(2)` to a pipe can park for as long as the kernel makes it,
/// and no look before the write says otherwise: `poll` calls a pipe writable at `PIPE_BUF` bytes
/// free (a line is longer), calls a full pipe writable once the system has run out of memory for
/// pipe buffers, and says nothing about a terminal under flow control. Chunking, polling and
/// bounding the write each fixed the case the review had found and left the next one open. So
/// the hold does not write. It hands a line over, which never blocks, and goes on.
///
/// ## What the hold asks, and what it does not
///
/// It asks `status`, which is a lock and a read:
///
/// - **Has the oldest line been waiting too long?** A consumer that is not draining is judged by
///   the *writer's progress*, not by anything `poll` says: if the oldest line handed over has
///   not been completely written within the bound, the hold ends as `outputClosed`. The time is
///   the hold's own clock, which is why the pump takes the instant with the line.
/// - **Is the writer broken?** A failed write, or a reader that has gone, ends the hold the same
///   way.
/// - **Is the stream idle, and so at a line boundary?** A closing event goes to this stream only
///   if the answer is yes (`SetOutput`): a line the writer is parked on may be a fragment already
///   (a blocking `write(2)` of a long line takes what fits and sleeps for the rest, and nothing
///   says how much it took), and gluing an event onto it makes one line that parses as neither.
///
/// ## Process exit abandons a parked writer
///
/// A thread parked in `write(2)` cannot be cancelled and is not waited for: when the process
/// exits, the thread dies with it, and so does whatever it had not yet written. That is
/// deliberate. The bytes it had already written stay in the pipe, so a stream can end with a
/// fragment of a line; the closing event is therefore written so that a fragment cannot swallow
/// it.
final class LinePump: Sendable {

    /// Writes one line to the end. May block for as long as it likes: it runs on the pump's own
    /// thread (`threaded`) or, for a suite's recorder, on the caller's (`inline`).
    typealias Write = @Sendable (_ line: String) -> FileDescriptorWriter.Outcome

    /// What the hold may ask. Never waits.
    struct Status: Equatable, Sendable {
        /// When the oldest line that is not completely written was handed over, on the hold's
        /// clock. `nil` when every line handed over has been written (or the pump is broken and
        /// has dropped them).
        var oldestUnfinished: ContinuousClock.Instant?

        /// Every line handed over has been completely written.
        var isIdle: Bool { oldestUnfinished == nil }
        /// A write failed or the reader has gone. Nothing more will be written.
        var isBroken: Bool
    }

    private struct Line {
        let text: String
        let handedOverAt: ContinuousClock.Instant
    }

    private struct State {
        var waiting: [Line] = []
        var current: Line?
        var isBroken = false
        var isClosed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let write: Write
    private let wake: DispatchSemaphore?

    /// A pump whose lines are written, one after another, by a thread of its own. The thread
    /// lives until `close()` lets it finish, or until the process exits.
    init(threaded name: String, write: @escaping Write) {
        self.write = write
        self.wake = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in self.run() }
        thread.name = name
        thread.start()
    }

    /// A pump that writes each line on the caller's thread, before `enqueue` returns. For a
    /// suite's recorder, which takes a line or does not and never makes anyone wait.
    init(inline write: @escaping Write) {
        self.write = write
        self.wake = nil
    }

    // MARK: - The hold's side

    /// Hands `text` over, to be written after every line handed over before it. Never blocks a
    /// threaded pump's caller; a broken pump drops the line.
    func enqueue(_ text: String, at instant: ContinuousClock.Instant) {
        let line = Line(text: text, handedOverAt: instant)
        let accepted = state.withLock { state -> Bool in
            guard !state.isBroken, !state.isClosed else { return false }
            state.waiting.append(line)
            return true
        }
        guard accepted else { return }
        if let wake {
            wake.signal()
        } else {
            drain()
        }
    }

    var status: Status {
        state.withLock { state in
            Status(
                oldestUnfinished: (state.current ?? state.waiting.first)?.handedOverAt,
                isBroken: state.isBroken)
        }
    }

    /// Lets the thread end once what is handed over is written. A thread parked in a write stays
    /// parked: nothing can end it but the reader, or the process.
    func close() {
        state.withLock { $0.isClosed = true }
        wake?.signal()
    }

    // MARK: - The writer's side

    private func run() {
        guard let wake else { return }
        while true {
            wake.wait()
            drain()
            if state.withLock({ $0.isClosed && $0.waiting.isEmpty }) { return }
        }
    }

    /// Writes every line there is, oldest first.
    private func drain() {
        while let line = begin() {
            end(write(line.text))
        }
    }

    private func begin() -> Line? {
        state.withLock { state -> Line? in
            guard state.current == nil, !state.waiting.isEmpty else { return nil }
            let line = state.waiting.removeFirst()
            state.current = line
            return line
        }
    }

    private func end(_ outcome: FileDescriptorWriter.Outcome) {
        state.withLock { state in
            state.current = nil
            if !outcome.isDelivered {
                state.isBroken = true
                state.waiting.removeAll()
            }
        }
    }
}

/// The two streams a `set` run writes, each with a pump of its own: a stalled standard error
/// must not be able to hold up standard output's lines or the exit, and the reverse.
struct OutputSinks: Sendable {
    let standardOutput: LinePump
    let standardError: LinePump
}
