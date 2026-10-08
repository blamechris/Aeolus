import Foundation
import os

/// Writes a line to a file descriptor with `write(2)`, and says how it went.
///
/// **Why not `FileHandle.write`.** It raises an Objective-C exception on EPIPE, which Swift
/// cannot catch: a consumer that went away would crash the process instead of letting the command
/// leave with its own exit code ([#317](https://github.com/blamechris/Aeolus/issues/317)).
///
/// ## Two ways to write
///
/// **To the end** (`patience == nil`, every command but `set`). Every byte is written, and the
/// write waits as long as the reader needs. A reader that has gone is `readerGone`, and the
/// command goes on to leave with the exit code it already had: nobody is left to mislead.
///
/// **Within a bound** (`patience`, `fanctl set`). A process holding a lease must keep renewing
/// it, so a write may not park it. Three things follow, and each is a finding of the review of
/// #324 that an earlier version got wrong.
///
/// 1. *The write is only ever as big as the room `poll` promises.* macOS reports a pipe writable
///    once `PIPE_BUF` (512) bytes are free, and a blocking write of a whole `set --json` line
///    (560 to 1,127 bytes) into a pipe with 512 free parks until the reader drains it. The line
///    is therefore written in chunks of at most `PIPE_BUF`, each after the pipe has said it has
///    room for one. `O_NONBLOCK` is never set: the flag lives on the open file description,
///    which the shell and every other process holding the descriptor share.
/// 2. *The wait is short and asks whether to go on.* Each wait is one `slice` of `poll`; between
///    waits the caller's `stop` is asked, and a stop request (a signal, the parent exiting, the
///    deadline) wins over the rest of the line.
/// 3. *The wait is bounded.* A reader that has not made room within `limit` is treated as gone.
///
/// A write that other processes on the same pipe race for the room it was promised can still
/// park for as long as they hold it. That is the one case this does not close.
///
/// ## Which descriptors are asked
///
/// Only pipes and sockets. macOS answers `POLLNVAL` for `/dev/null` and other devices, so asking
/// every descriptor would read `fanctl set … > /dev/null` as a consumer that had gone and end the
/// hold the moment it began. A socket needs the same treatment as a pipe, not a special case: its
/// low-water mark (2,048 bytes by default) is above `PIPE_BUF`, so the chunk always fits where
/// `poll` says it does. A file is written to; a terminal is written to too, and **a terminal
/// under flow control (Ctrl-S) can park a write**, which no poll tells us about. Text mode shows
/// a terminal only the start and closing lines, and the lease's lifetime covers the rest.
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
        /// The reader has gone: EPIPE, or the pipe reported it hung up.
        case readerGone
        /// The reader is still there and did not make room in time, or the caller asked to stop
        /// while the write was waiting. Part of the line may have been written.
        case gaveUp
        /// Any other failure, with its `errno`: a closed or invalid descriptor, no space left.
        case failed(Int32)

        var isDelivered: Bool { self == .delivered }
    }

    /// What a bounded write's wait came to.
    enum Wait: Equatable, Sendable {
        /// The slice passed with no change.
        case timedOut
        /// The pipe changed (room, or the reader left) or the wait was interrupted: look again.
        case changed
    }

    /// How a write that must not park the caller waits.
    struct Patience: Sendable {
        /// The most time the line may spend waiting, in whole `slice`s that timed out.
        let limit: Duration
        /// The longest single wait before `stop` is asked again.
        let slice: Duration
        /// Whether the caller has been asked to stop.
        let stop: @Sendable () -> Bool
        /// Waits up to `slice` for room. `pollForRoom` in production; a suite substitutes a wait
        /// that costs no real time.
        let wait: @Sendable (_ descriptor: Int32, _ slice: Duration) -> Wait

        init(
            limit: Duration, slice: Duration, stop: @escaping @Sendable () -> Bool,
            wait: @escaping @Sendable (Int32, Duration) -> Wait = FileDescriptorWriter.pollForRoom
        ) {
            self.limit = limit
            self.slice = slice
            self.stop = stop
            self.wait = wait
        }
    }

    /// The most a bounded write asks for at once: `PIPE_BUF`, the room a pipe that `poll` calls
    /// writable is promised to have.
    static let chunk = Int(PIPE_BUF)

    /// Writes `text` and a newline.
    ///
    /// - Parameters:
    ///   - text: The line, without its newline.
    ///   - descriptor: Where it goes.
    ///   - patience: How long to wait for a reader to make room, and for whom; `nil` waits as
    ///     long as the reader needs.
    ///   - shouldIgnore: Whether SIGPIPE is ignored for the length of the write, which is the
    ///     only thing standing between a reader that has gone and the process's default death
    ///     (see the type's notes). A seam: it is a process-wide switch, so the suites that are
    ///     not about it turn it off and cannot disturb the ones that are.
    /// - Returns: How it went.
    static func writeLine(
        _ text: String, to descriptor: Int32, patience: Patience? = nil,
        ignoringSIGPIPE shouldIgnore: Bool = true
    ) -> Outcome {
        let bytes = Array((text + "\n").utf8)
        // A descriptor `fstat` cannot describe leaves `status` zeroed, which is neither a pipe
        // nor a socket; the write then fails with EBADF and says so.
        var status = stat()
        _ = fstat(descriptor, &status)
        let kind = status.st_mode & S_IFMT
        let canStall = kind == S_IFIFO || kind == S_IFSOCK
        let patience = canStall ? patience : nil
        guard shouldIgnore else { return write(bytes, to: descriptor, patience: patience) }
        return ignoringSIGPIPE { write(bytes, to: descriptor, patience: patience) }
    }

    // MARK: - Writing

    private static func write(
        _ bytes: [UInt8], to descriptor: Int32, patience: Patience?
    ) -> Outcome {
        var written = 0
        var waited = Duration.zero
        while written < bytes.count {
            var size = bytes.count - written
            if let patience {
                switch room(on: descriptor) {
                case .gone:
                    return .readerGone
                case .none:
                    if patience.stop() || waited >= patience.limit { return .gaveUp }
                    if patience.wait(descriptor, patience.slice) == .timedOut {
                        waited += patience.slice
                    }
                    continue
                case .some:
                    size = min(size, chunk)
                }
            }
            let count = bytes[written...].withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, size)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return errno == EPIPE ? .readerGone : .failed(errno)
            }
            written += count
        }
        return .delivered
    }

    private enum Room {
        case some, none, gone
    }

    /// Whether a write of `chunk` bytes would be accepted now, without waiting: `POLLOUT`, and
    /// none of `POLLERR`, `POLLHUP` or `POLLNVAL`, which is how a pipe whose reader closed
    /// announces itself.
    private static func room(on descriptor: Int32) -> Room {
        var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        while true {
            let ready = poll(&request, 1, 0)
            if ready < 0 {
                if errno == EINTR { continue }
                return .gone
            }
            guard ready > 0 else { return .none }
            let broken = Int16(POLLERR | POLLHUP | POLLNVAL)
            if request.revents & broken != 0 { return .gone }
            return request.revents & Int16(POLLOUT) != 0 ? .some : .none
        }
    }

    /// One `slice` of `poll(2)` for room, the production wait.
    static func pollForRoom(_ descriptor: Int32, _ slice: Duration) -> Wait {
        var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let parts = slice.components
        let milliseconds = Int32(
            clamping: parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
        return poll(&request, 1, milliseconds) == 0 ? .timedOut : .changed
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
