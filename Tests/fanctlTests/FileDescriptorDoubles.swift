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

    func read(_ count: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let received = Darwin.read(reader, &buffer, count)
        return Array(buffer.prefix(max(received, 0)))
    }

    func text(_ count: Int) -> String { String(decoding: read(count), as: UTF8.self) }

    /// Reads everything queued.
    func drain() -> [UInt8] { read(queued) }

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

    /// Whether `poll` calls the writer writable: the answer the writer itself will get.
    var pollsWritable: Bool {
        var request = pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)
        return poll(&request, 1, 0) > 0 && request.revents & Int16(POLLOUT) != 0
    }
}

/// A wait that costs no real time: counts itself, says the slice passed with nothing changing,
/// and lets a test act at the n-th one.
final class ScriptedWait: Sendable {
    private let counted = OSAllocatedUnfairLock(initialState: 0)
    private let act: @Sendable (Int) -> Void

    init(_ act: @escaping @Sendable (Int) -> Void = { _ in }) { self.act = act }

    /// How many slices have been waited.
    var slices: Int { counted.withLock { $0 } }

    var wait: @Sendable (Int32, Duration) -> FileDescriptorWriter.Wait {
        { [counted, act] _, _ in
            let number = counted.withLock { value -> Int in
                value += 1
                return value
            }
            act(number)
            return .timedOut
        }
    }
}

/// What the suites that test `FileDescriptorWriter` share.
enum WriterRig {

    static func patience(
        _ wait: ScriptedWait, stop: @escaping @Sendable () -> Bool = { false },
        limit: Duration = .seconds(2)
    ) -> FileDescriptorWriter.Patience {
        FileDescriptorWriter.Patience(
            limit: limit, slice: .milliseconds(100), stop: stop, wait: wait.wait)
    }

    /// `FileDescriptorWriter.writeLine`, with SIGPIPE left alone.
    static func write(
        _ text: String, to descriptor: Int32, patience: FileDescriptorWriter.Patience? = nil
    ) -> FileDescriptorWriter.Outcome {
        FileDescriptorWriter.writeLine(
            text, to: descriptor, patience: patience, ignoringSIGPIPE: false)
    }

    /// The result of `work`, or `nil` if it did not come back within five seconds.
    ///
    /// A write that parks cannot be cancelled, and a test that waited for it would hang the suite
    /// instead of failing. `unblock` frees it afterwards so the thread is not left behind. The five
    /// seconds are only ever spent when the guard under test is broken.
    static func promptly<Value: Sendable>(
        unblocking unblock: () -> Void, running work: @escaping @Sendable () -> Value
    ) -> Value? {
        let result = OSAllocatedUnfairLock<Value?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        BackgroundThread.run {
            let value = work()
            result.withLock { $0 = value }
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            unblock()
            _ = done.wait(timeout: .now() + 5)
            return nil
        }
        return result.withLock { $0 }
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
