import Foundation
import os

@testable import fanctl

/// Every line a command wrote, in order, with the stream it went to.
///
/// It can also be a terminal whose standard output **stops taking lines**: the consumer that went
/// away. Such a line is still recorded, flagged as not delivered, so a test can assert both what
/// a consumer would have read (`standardOutput`) and what the command tried to say
/// (`attemptedStandardOutput`).
final class RecordingTerminal: Sendable {

    struct Line: Sendable, Hashable {
        let stream: Terminal.Stream
        let text: String
        let delivered: Bool

        init(stream: Terminal.Stream, text: String, delivered: Bool = true) {
            self.stream = stream
            self.text = text
            self.delivered = delivered
        }
    }

    private let recorded = OSAllocatedUnfairLock<[Line]>(initialState: [])
    private let acceptedStandardOutputLines: Int?
    private let onStandardOutput: (@Sendable (Int, String) -> Void)?

    /// - Parameters:
    ///   - acceptingStandardOutputLines: Standard output takes this many lines and then fails
    ///     every write. `nil` takes all of them.
    ///   - onStandardOutput: Called after each standard-output line is recorded, with its
    ///     one-based number. It is how a test makes time pass during a write.
    init(
        acceptingStandardOutputLines: Int? = nil,
        onStandardOutput: (@Sendable (Int, String) -> Void)? = nil
    ) {
        self.acceptedStandardOutputLines = acceptingStandardOutputLines
        self.onStandardOutput = onStandardOutput
    }

    var terminal: Terminal {
        let recorded = recorded
        let limit = acceptedStandardOutputLines
        let onStandardOutput = onStandardOutput
        return Terminal(delivering: { stream, text in
            let (delivered, number) = recorded.withLock { lines -> (Bool, Int) in
                let attempted = lines.filter { $0.stream == .standardOutput }.count
                var delivered = true
                if stream == .standardOutput, let limit {
                    delivered = attempted < limit
                }
                lines.append(Line(stream: stream, text: text, delivered: delivered))
                return (delivered, attempted + 1)
            }
            if stream == .standardOutput { onStandardOutput?(number, text) }
            return delivered
        })
    }

    var lines: [Line] { recorded.withLock { $0 } }

    /// What a consumer of standard output would have read.
    var standardOutput: String {
        lines.filter { $0.stream == .standardOutput && $0.delivered }.map(\.text)
            .joined(separator: "\n")
    }

    /// Everything the command tried to write to standard output, delivered or not.
    var attemptedStandardOutput: [String] {
        lines.filter { $0.stream == .standardOutput }.map(\.text)
    }

    var standardError: String {
        lines.filter { $0.stream == .standardError }.map(\.text).joined(separator: "\n")
    }

    /// Standard output as NDJSON: one decoded object per delivered line.
    func events() throws -> [[String: Any]] {
        try Self.decode(lines.filter { $0.stream == .standardOutput && $0.delivered })
    }

    /// The same, for every line the command tried to write.
    func attemptedEvents() throws -> [[String: Any]] {
        try Self.decode(lines.filter { $0.stream == .standardOutput })
    }

    private static func decode(_ lines: [Line]) throws -> [[String: Any]] {
        try lines.map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.text.utf8))
            guard let dictionary = object as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            return dictionary
        }
    }
}

/// A real pipe, for the tests that are about what happens when a reader is slow, stopped or gone.
///
/// The writer is left **blocking**, as the one `fanctl` inherits is, and is only made non-blocking
/// for the length of `fill`, on this test's own pipe. `F_SETNOSIGPIPE` is set so that a write to a
/// pipe whose reader the test closed fails with EPIPE in a test that is not about SIGPIPE.
struct RealPipe {
    let reader: Int32
    let writer: Int32

    init() throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw CocoaError(.fileWriteUnknown) }
        reader = descriptors[0]
        writer = descriptors[1]
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
    }

    func close() {
        Darwin.close(reader)
        Darwin.close(writer)
    }

    /// Bytes waiting to be read.
    var queued: Int {
        var count: Int32 = 0
        _ = ioctl(reader, 0x4004_667F, &count)  // FIONREAD, _IOR('f', 127, int)
        return Int(count)
    }

    func read(_ count: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let received = Darwin.read(reader, &buffer, count)
        return Array(buffer.prefix(max(received, 0)))
    }

    /// Everything queued.
    func drain() -> [UInt8] { read(queued) }

    /// Fills the pipe, then makes `free` bytes of room by reading them back.
    func fill(leavingFree free: Int) {
        let flags = fcntl(writer, F_GETFL)
        _ = fcntl(writer, F_SETFL, flags | O_NONBLOCK)
        var filler: UInt8 = 0x61
        while Darwin.write(writer, &filler, 1) == 1 {}
        _ = fcntl(writer, F_SETFL, flags)
        _ = read(free)
    }

    /// Whether `poll` calls the writer writable: the answer a writer will get.
    var pollsWritable: Bool {
        var request = pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)
        return poll(&request, 1, 0) > 0 && request.revents & Int16(POLLOUT) != 0
    }
}

/// How one `run()` left: `nil` for a normal return, otherwise the exit code it would exit
/// with — read through swift-argument-parser's own mapping, not a copy of it.
func exitCode(of run: () async throws -> Void) async -> Int32? {
    do {
        try await run()
        return nil
    } catch {
        return Fanctl.exitCode(for: error).rawValue
    }
}

/// Runs `work` on a thread of its own, and returns at once.
///
/// Not `DispatchQueue.global().async`. A test that waits on a pipe or a semaphore holds a worker
/// thread for as long as it waits, the pool those workers come from is only as wide as the
/// machine's cores, and on a three-core CI runner enough of them at once leave work queued behind
/// them that never starts: the review of this suite on CI saw readers that never began, and
/// unrelated tests timing out waiting for a pool with no free thread. A thread of its own always
/// starts.
enum BackgroundThread {
    static func run(_ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        thread.start()
    }
}
