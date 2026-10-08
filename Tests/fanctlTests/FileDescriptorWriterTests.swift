import Foundation
import Testing
import os

@testable import fanctl

/// The one way `fanctl set` writes to standard output: `write(2)`, and an answer to "did it
/// arrive".
///
/// `FileHandle.write` raises an Objective-C exception on EPIPE, which Swift cannot catch, so a
/// consumer that went away would have crashed the process holding a lease instead of ending the
/// hold ([#317](https://github.com/blamechris/Aeolus/issues/317)). These tests use real pipes
/// and never touch the process's own standard output.
@Suite("Writing a line to a file descriptor")
struct FileDescriptorWriterTests {

    private struct Pipe {
        let reader: Int32
        let writer: Int32

        init() throws {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw CocoaError(.fileWriteUnknown) }
            reader = fds[0]
            writer = fds[1]
            // No SIGPIPE from this pipe: a write to a closed one must return EPIPE here, as it
            // does in production once `fanctl set` has ignored the signal.
            _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        }

        func close() {
            Darwin.close(reader)
            Darwin.close(writer)
        }

        func read(_ count: Int) -> String {
            var buffer = [UInt8](repeating: 0, count: count)
            let received = Darwin.read(reader, &buffer, count)
            return String(decoding: buffer.prefix(max(received, 0)), as: UTF8.self)
        }
    }

    @Test("A line is written whole, with its newline")
    func writesTheLine() throws {
        let pipe = try Pipe()
        defer { pipe.close() }
        #expect(FileDescriptorWriter.writeLine("{\"event\":\"holding\"}", to: pipe.writer))
        #expect(pipe.read(100) == "{\"event\":\"holding\"}\n")
    }

    @Test("Several lines arrive in order")
    func writesLinesInOrder() throws {
        let pipe = try Pipe()
        defer { pipe.close() }
        #expect(FileDescriptorWriter.writeLine("one", to: pipe.writer))
        #expect(FileDescriptorWriter.writeLine("two", to: pipe.writer))
        #expect(pipe.read(100) == "one\ntwo\n")
    }

    /// The consumer that went away. This is `outputClosed`, and it must be an answer, not a
    /// crash and not a signal.
    ///
    /// **Mutation:** make `writeLine` return `true` unconditionally. Run: red.
    @Test("A pipe whose reader has gone reports failure")
    func closedReader() throws {
        let pipe = try Pipe()
        Darwin.close(pipe.reader)
        defer { Darwin.close(pipe.writer) }
        #expect(!FileDescriptorWriter.writeLine("anyone there?", to: pipe.writer))
    }

    /// A consumer that is alive and not reading would block `write(2)` for as long as it likes,
    /// and a process blocked in a write is a process that has stopped renewing its lease. A
    /// pipe with no room is reported as failed, without waiting.
    ///
    /// **Mutation:** delete the `poll` in `writeLine`. Run: red — the write blocks, the five
    /// seconds pass, and the assertion that it came back fails; the reader is then drained so
    /// the blocked write finishes and the thread is not left behind.
    ///
    /// The write runs on its own thread because a write that blocks cannot be cancelled, and a
    /// test that waited for it would hang the suite instead of failing. The five seconds are
    /// only ever spent when the guard is broken: a pass returns at once.
    @Test("A pipe with no room reports failure instead of blocking")
    func fullPipe() throws {
        let pipe = try Pipe()
        defer { pipe.close() }
        let flags = fcntl(pipe.writer, F_GETFL)
        _ = fcntl(pipe.writer, F_SETFL, flags | O_NONBLOCK)
        var filler: UInt8 = 0x61
        while Darwin.write(pipe.writer, &filler, 1) == 1 {}
        // Back to blocking: the production descriptor is, and the answer must not depend on
        // the write being the thing that refuses.
        _ = fcntl(pipe.writer, F_SETFL, flags)

        let outcome = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let writer = pipe.writer
        DispatchQueue.global().async {
            let delivered = FileDescriptorWriter.writeLine("no room", to: writer)
            outcome.withLock { $0 = delivered }
            done.signal()
        }
        let returned = done.wait(timeout: .now() + 5) == .success
        if !returned {
            _ = pipe.read(65_536)
            _ = done.wait(timeout: .now() + 5)
        }

        #expect(returned, "the write blocked instead of reporting failure")
        #expect(outcome.withLock { $0 } == false)
    }

    /// macOS answers `POLLNVAL` for `/dev/null`, so a writer that polled every descriptor would
    /// read `fanctl set … > /dev/null` as a consumer that had gone and end the hold at once.
    ///
    /// **Mutation:** poll every descriptor, not only pipes and sockets (`canStall = true` in
    /// `writeLine`). Run: red here.
    @Test("/dev/null takes the line: a device is not a consumer that has gone")
    func devNull() {
        let descriptor = open("/dev/null", O_WRONLY)
        defer { Darwin.close(descriptor) }
        #expect(descriptor >= 0)
        #expect(FileDescriptorWriter.writeLine("into the void", to: descriptor))
    }

    @Test("A regular file receives the line")
    func regularFile() throws {
        let path = NSTemporaryDirectory() + "fanctl-writer-\(UUID().uuidString)"
        defer { unlink(path) }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        #expect(descriptor >= 0)
        #expect(FileDescriptorWriter.writeLine("kept", to: descriptor))
        Darwin.close(descriptor)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "kept\n")
    }

    @Test("A descriptor that is not open reports failure")
    func badDescriptor() {
        #expect(!FileDescriptorWriter.writeLine("x", to: -1))
    }
}
