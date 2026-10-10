import Foundation
import os

@testable import fanctl

/// A pipe for the tests of `FileDescriptorWriter`.
///
/// `F_SETNOSIGPIPE` keeps a write to a closed one from raising SIGPIPE in a test that is not about
/// SIGPIPE, and `FileDescriptorWriter` is called with `ignoringSIGPIPE: false` for the same reason
/// (`WriterRig.write`): ignoring it is a process-wide switch, and the suites that read or count
/// SIGPIPE (`HoldEnvironmentTests`) must not have it flipped under them by an unrelated write.
struct TestPipe {
    let reader: Int32
    let writer: Int32

    init() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw CocoaError(.fileWriteUnknown) }
        reader = fds[0]
        writer = fds[1]
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

    /// Up to `count` bytes, or none if nothing arrives within two seconds. **Never a blocking
    /// read**: a test whose writer wrote nothing must fail on what it read and not park the test
    /// process on a pipe whose writer is still open.
    func read(_ count: Int) -> [UInt8] {
        var request = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
        guard poll(&request, 1, 2_000) > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        let received = Darwin.read(reader, &buffer, count)
        return Array(buffer.prefix(max(received, 0)))
    }

    func text(_ count: Int) -> String { String(decoding: read(count), as: UTF8.self) }

    /// Reads everything queued, without waiting for more.
    func drain() -> [UInt8] {
        let waiting = queued
        return waiting > 0 ? read(waiting) : []
    }

    /// Fills the pipe, then makes `free` bytes of room by reading them back.
    ///
    /// Filled with the writer non-blocking, which is this test's own pipe and never a descriptor
    /// `fanctl` inherited, then put back to blocking as production's is.
    func fill(leavingFree free: Int) {
        let flags = fcntl(writer, F_GETFL)
        _ = fcntl(writer, F_SETFL, flags | O_NONBLOCK)
        var filler: UInt8 = 0x61
        while Darwin.write(writer, &filler, 1) == 1 {}
        _ = fcntl(writer, F_SETFL, flags)
        _ = read(free)
    }
}

/// What the suites that test `FileDescriptorWriter` share.
enum WriterRig {

    /// `FileDescriptorWriter.writeLine`, with SIGPIPE left alone.
    static func write(_ text: String, to descriptor: Int32) -> FileDescriptorWriter.Outcome {
        FileDescriptorWriter.writeLine(text, to: descriptor, ignoringSIGPIPE: false)
    }

    /// Everything that arrives on `descriptor` until `total` bytes are in or nothing arrives for
    /// two seconds. For a reader thread: **never a blocking read**.
    static func readUntil(total: Int, from descriptor: Int32) -> [UInt8] {
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while received.count < total {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&request, 1, 2_000) > 0 else { break }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count <= 0 { break }
            received += chunk.prefix(count)
        }
        return received
    }

    /// The result of `work`, or `nil` if it did not come back within five seconds.
    ///
    /// A write that parks cannot be cancelled, and a test that waited for it would hang the suite
    /// instead of failing. `unblock` frees it afterwards so the thread is not left behind. The five
    /// seconds are only ever spent when the guard under test is broken. **Nothing here blocks a
    /// worker thread**: the work is on a thread of its own and the wait is a poll with
    /// `Task.sleep`, because a runner with few cores that has every worker parked in a test's
    /// wait runs nothing.
    static func promptly<Value: Sendable>(
        unblocking unblock: @Sendable () -> Void, running work: @escaping @Sendable () -> Value,
        whileRunning during: @Sendable () -> Void = {}
    ) async -> Value? {
        let result = OSAllocatedUnfairLock<Value?>(initialState: nil)
        let done = OSAllocatedUnfairLock(initialState: false)
        BackgroundThread.run {
            let value = work()
            result.withLock { $0 = value }
            done.withLock { $0 = true }
        }
        during()
        if await eventually({ done.withLock { $0 } }) { return result.withLock { $0 } }
        unblock()
        _ = await eventually({ done.withLock { $0 } })
        return nil
    }

    /// Whether `condition` holds within `seconds`, polled every millisecond without blocking a
    /// worker thread. A pass reaches it at once.
    static func eventually(seconds: Int = 5, _ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<(seconds * 1_000) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    /// A line of exactly `length` bytes, newline included.
    static func line(_ length: Int) -> String {
        String(repeating: "x", count: length - 1)
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
