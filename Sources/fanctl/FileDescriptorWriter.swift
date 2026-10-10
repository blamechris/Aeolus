import Foundation
import os

/// Writes a line to a file descriptor with `write(2)`, to the end, and says how it went.
///
/// **Why not `FileHandle.write`.** It raises an Objective-C exception on EPIPE, which Swift
/// cannot catch: a consumer that went away would crash the process instead of letting the command
/// leave with its own exit code ([#317](https://github.com/blamechris/Aeolus/issues/317)).
///
/// ## A write may park, and nothing here tries to prevent it
///
/// Every byte is written, and the write waits as long as the kernel makes it wait. That is the
/// right behaviour for `status` and `auto`, whose reader is merely slow when it is slow, and it
/// is why `fanctl set` never calls this from its hold: its lines go to a `LinePump`, whose own
/// thread makes these calls, and the hold never waits on it. Nothing in this file bounds a write,
/// polls for room before one, or chunks one. An earlier version did all three, and the review of
/// #324 found each claim false in a case it could not see: `poll` calls a pipe writable at
/// `PIPE_BUF` bytes free, which a line is longer than; calls a pipe at the system's pipe-memory
/// ceiling writable when it is full; and says nothing about a terminal under flow control.
///
/// A reader that has gone is `readerGone` (EPIPE, or the descriptor reporting a hang-up), and the
/// command goes on to leave with the exit code it already had: nobody is left to mislead.
///
/// ## An inherited `O_NONBLOCK`
///
/// A child of a Node process inherits a pipe that libuv made non-blocking, and a slow reader is
/// then `EAGAIN` and not a wait. `poll` is used for exactly that case, after `EAGAIN`, to wait
/// until the descriptor can take bytes, and the write is retried. The flag is never set or
/// cleared here: it lives on the open file description, which every process sharing the
/// descriptor shares too. `poll` is also only an invitation to try: where it says "writable" and
/// the next write is `EAGAIN` again, the retry backs off instead of spinning.
///
/// ## SIGPIPE
///
/// A write that finds the reader gone raises SIGPIPE, whose default action ends the process with
/// 141 and no chance to leave with the command's own code. **It is ignored for the length of the
/// write, process-wide, and the previous disposition is put back after it.** Blocking it on the
/// writing thread does not work: measured on macOS, the kernel raises this SIGPIPE at the
/// *process*, and delivers it to whichever other thread has it unblocked, so a command with a
/// cooperative thread pool is killed by a signal its writing thread was shielded from.
/// `F_SETNOSIGPIPE` on the descriptor would work and is not touched: the flag lives on the open
/// file description, which every process sharing the pipe shares too.
enum FileDescriptorWriter {

    /// What came of writing a line.
    enum Outcome: Equatable, Sendable {
        case delivered
        /// The reader has gone: EPIPE, or the descriptor reported it hung up.
        case readerGone
        /// Any other failure, with its `errno`: a closed or invalid descriptor, no space left.
        case failed(Int32)

        var isDelivered: Bool { self == .delivered }
    }

    /// Writes `text` and a newline.
    ///
    /// - Parameters:
    ///   - text: The line, without its newline.
    ///   - descriptor: Where it goes.
    ///   - shouldIgnore: Whether SIGPIPE is ignored for the length of the write, which is the
    ///     only thing standing between a reader that has gone and the process's default death
    ///     (see the type's notes). A seam: it is a process-wide switch, so the suites that are
    ///     not about it turn it off and cannot disturb the ones that are.
    /// - Returns: How it went.
    static func writeLine(
        _ text: String, to descriptor: Int32, ignoringSIGPIPE shouldIgnore: Bool = true
    ) -> Outcome {
        let bytes = Array((text + "\n").utf8)
        guard shouldIgnore else { return write(bytes, to: descriptor) }
        return ignoringSIGPIPE { write(bytes, to: descriptor) }
    }

    // MARK: - Writing

    private static func write(_ bytes: [UInt8], to descriptor: Int32) -> Outcome {
        var written = 0
        var refusals = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                let code = errno
                switch code {
                case EINTR:
                    continue
                case EAGAIN:
                    // Wait for the descriptor to say it can take bytes, and try again; what
                    // `poll` reports is only an invitation, and the retried write is the answer
                    // (EPIPE for a reader that has gone). Every refusal after the first is one
                    // `poll` did not predict, so it backs off instead of spinning.
                    if refusals > 0 { usleep(10_000) }
                    refusals += 1
                    var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&request, 1, -1)
                    continue
                case EPIPE:
                    return .readerGone
                default:
                    return .failed(code)
                }
            }
            refusals = 0
            written += count
        }
        return .delivered
    }

    // MARK: - SIGPIPE

    private struct Ignoring {
        var depth = 0
        var previous: (@convention(c) (Int32) -> Void)?
    }

    /// Writers inside `ignoringSIGPIPE` right now, and what SIGPIPE was before the first of them.
    /// Counted so that two writes that overlap restore it once, when the last of them is done,
    /// instead of one restoring what the other had just set.
    private static let ignoring = OSAllocatedUnfairLock(initialState: Ignoring())

    /// Runs `body` with SIGPIPE ignored, and puts the previous disposition back afterwards.
    private static func ignoringSIGPIPE<Result>(_ body: () -> Result) -> Result {
        ignoring.withLock { state in
            if state.depth == 0 { state.previous = signal(SIGPIPE, SIG_IGN) }
            state.depth += 1
        }
        defer {
            ignoring.withLock { state in
                state.depth -= 1
                if state.depth == 0 { _ = signal(SIGPIPE, state.previous) }
            }
        }
        return body()
    }
}
