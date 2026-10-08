import Foundation
import Testing
import os

@testable import fanctl

/// The one way `fanctl` writes to a pipe: `write(2)`, to the end, and an answer to how it went.
///
/// `FileHandle.write` raises an Objective-C exception on EPIPE, which Swift cannot catch
/// ([#317](https://github.com/blamechris/Aeolus/issues/317)). The writer waits as long as the
/// kernel makes it wait: it is `status` and `auto` that call it directly, and `set`'s pump that
/// calls it on a thread of its own (`LinePumpTests`, `FanctlSetBlockedWriterTests`). Real pipes
/// throughout; nothing here touches the process's own standard output. Sockets, files and
/// devices are `FileDescriptorKindsTests`.
///
/// A write that parks is run on a thread of its own and waited for at most five seconds
/// (`WriterRig.promptly`), and every read is bounded (`TestPipe.read`, `WriterRig.readUntil`):
/// a regression fails an assertion and cannot hang the test process.
@Suite("Writing a line to a pipe", .serialized, .timeLimit(.minutes(1)))
struct FileDescriptorWriterTests {

    typealias Rig = WriterRig

    @Test("A line is written whole, with its newline")
    func writesTheLine() async throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        #expect(Rig.write("{\"event\":\"holding\"}", to: pipe.writer) == .delivered)
        #expect(pipe.text(100) == "{\"event\":\"holding\"}\n")
    }

    @Test("Several lines arrive in order")
    func writesLinesInOrder() async throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        #expect(Rig.write("one", to: pipe.writer) == .delivered)
        #expect(Rig.write("two", to: pipe.writer) == .delivered)
        #expect(pipe.text(100) == "one\ntwo\n")
    }

    /// The consumer that went away. An answer, not a crash and not a signal.
    ///
    /// **Mutation:** return `.delivered` for EPIPE in `FileDescriptorWriter.write`. Run: red.
    @Test("A pipe whose reader has gone reports it")
    func closedReader() async throws {
        let pipe = try TestPipe()
        Darwin.close(pipe.reader)
        defer { Darwin.close(pipe.writer) }
        #expect(Rig.write("anyone there?", to: pipe.writer) == .readerGone)
    }

    // MARK: - A slow reader

    /// `status --json` must arrive whole even when the pipe has room for less than one line. The
    /// reader is still there and gets the whole document, late, never half of it.
    ///
    /// **Mutation:** give up on a write that is not accepted at once (return `.failed(EAGAIN)`
    /// for a refusal, or write only what `poll` promised). Run: red — the reader gets a cut-off
    /// line.
    @Test("A line larger than the room is delivered whole once the reader reads")
    func toTheEndWaitsForTheReader() async throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        pipe.fill(leavingFree: 300)
        let text = Rig.line(1_200)
        let reader = pipe.reader
        let expected = pipe.queued + 1_200
        let received = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
        BackgroundThread.run {
            Thread.sleep(forTimeInterval: 0.05)
            received.withLock { $0 = Rig.readUntil(total: expected, from: reader) }
        }
        let writer = pipe.writer

        let outcome = await Rig.promptly(
            unblocking: { _ = pipe.read(65_536) }, running: { Rig.write(text, to: writer) })

        #expect(outcome == .delivered)
        let tail = received.withLock { Array($0.suffix(1_200)) }
        #expect(String(decoding: tail, as: UTF8.self) == text + "\n")
    }

    // MARK: - An inherited O_NONBLOCK

    /// A child of a Node process inherits a pipe that libuv made non-blocking: a slow reader is
    /// `EAGAIN` there and not a wait. The write waits for room with `poll` and goes on.
    ///
    /// **Mutation:** report `EAGAIN` as a failure (drop the `case EAGAIN` branch of
    /// `FileDescriptorWriter.write`). Run: red — `failed(35)`, with 300 bytes of the line written.
    @Test("An inherited non-blocking descriptor is written to the end, waiting for room")
    func nonBlockingToTheEnd() async throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        pipe.fill(leavingFree: 300)
        let flags = fcntl(pipe.writer, F_GETFL)
        _ = fcntl(pipe.writer, F_SETFL, flags | O_NONBLOCK)
        let text = Rig.line(1_200)
        let reader = pipe.reader
        let expected = pipe.queued + 1_200
        let received = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
        BackgroundThread.run {
            Thread.sleep(forTimeInterval: 0.05)
            received.withLock { $0 = Rig.readUntil(total: expected, from: reader) }
        }
        let writer = pipe.writer

        let outcome = await Rig.promptly(
            unblocking: { _ = pipe.read(65_536) }, running: { Rig.write(text, to: writer) })

        #expect(outcome == .delivered)
        let tail = received.withLock { Array($0.suffix(1_200)) }
        #expect(String(decoding: tail, as: UTF8.self) == text + "\n")
    }

    /// The same descriptor, and the reader leaves while the write waits for room: the retried
    /// write is the answer, and it says the reader has gone.
    @Test("A non-blocking write that waits for room learns that the reader has gone")
    func nonBlockingReaderLeaves() async throws {
        let pipe = try TestPipe()
        defer { Darwin.close(pipe.writer) }
        pipe.fill(leavingFree: 0)
        let flags = fcntl(pipe.writer, F_GETFL)
        _ = fcntl(pipe.writer, F_SETFL, flags | O_NONBLOCK)
        let writer = pipe.writer
        let reader = pipe.reader

        let outcome = await Rig.promptly(
            unblocking: {},
            running: { Rig.write("anyone?", to: writer) },
            whileRunning: {
                Thread.sleep(forTimeInterval: 0.05)
                Darwin.close(reader)
            })

        #expect(outcome == .readerGone)
    }
}
