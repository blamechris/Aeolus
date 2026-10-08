import Foundation
import Testing
import os

@testable import fanctl

/// The one way `fanctl` writes to a pipe: `write(2)`, and an answer to how it went.
///
/// `FileHandle.write` raises an Objective-C exception on EPIPE, which Swift cannot catch
/// ([#317](https://github.com/blamechris/Aeolus/issues/317)). The review of #324 then found that
/// the replacement still blocked: macOS calls a pipe writable once `PIPE_BUF` (512) bytes are
/// free, and a `set --json` line is 560 to 1,127 bytes, so a whole-line write parked on a pipe
/// with 512 to 1,126 bytes of room. The tests below are built around that gap: **free space
/// strictly between `PIPE_BUF` and the length of the line.**
///
/// Real pipes throughout; nothing here touches the process's own standard output. A bounded wait
/// is a scripted one that costs no real time, except in the tests that exist to prove `poll(2)`
/// itself. Sockets, files and devices are `FileDescriptorKindsTests`.
@Suite("Writing a line to a pipe", .serialized)
struct FileDescriptorWriterTests {

    typealias Rig = WriterRig

    // MARK: - Writing to the end (every command but set)

    @Test("A line is written whole, with its newline")
    func writesTheLine() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        #expect(Rig.write("{\"event\":\"holding\"}", to: pipe.writer) == .delivered)
        #expect(pipe.text(100) == "{\"event\":\"holding\"}\n")
    }

    @Test("Several lines arrive in order")
    func writesLinesInOrder() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        #expect(Rig.write("one", to: pipe.writer) == .delivered)
        #expect(Rig.write("two", to: pipe.writer) == .delivered)
        #expect(pipe.text(100) == "one\ntwo\n")
    }

    /// The consumer that went away. An answer, not a crash and not a signal.
    ///
    /// **Mutation:** return `.delivered` for EPIPE in `FileDescriptorWriter.write`. Run: red.
    @Test("A pipe whose reader has gone reports it, to the end or within a bound")
    func closedReader() throws {
        let pipe = try TestPipe()
        Darwin.close(pipe.reader)
        defer { Darwin.close(pipe.writer) }
        #expect(Rig.write("anyone there?", to: pipe.writer) == .readerGone)
        let wait = ScriptedWait()
        #expect(
            Rig.write("anyone there?", to: pipe.writer, patience: Rig.patience(wait))
                == .readerGone)
        #expect(wait.slices == 0, "a reader that has gone is not waited for")
    }

    /// `status --json` must arrive whole even when the pipe has room for less than one chunk.
    /// Dropping the line, as the first version of the writer did, is worse than blocking: the
    /// reader is still there and gets half a document, or none.
    ///
    /// **Mutation:** give the unbounded write the bounded path's give-up (a `patience` of zero
    /// limit). Run: red — the reader gets nothing.
    @Test("To the end: a line larger than the room is delivered whole once the reader reads")
    func toTheEndWaitsForTheReader() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        pipe.fill(leavingFree: 300)
        let text = Rig.line(1_200)
        let received = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
        let finished = DispatchSemaphore(value: 0)
        let reader = pipe.reader
        let expected = pipe.queued + 1_200
        BackgroundThread.run {
            Thread.sleep(forTimeInterval: 0.05)
            var chunk = [UInt8](repeating: 0, count: 4_096)
            var total = 0
            while total < expected {
                let count = Darwin.read(reader, &chunk, chunk.count)
                if count <= 0 { break }
                total += count
                let bytes = Array(chunk.prefix(count))
                received.withLock { $0 += bytes }
            }
            finished.signal()
        }

        let outcome = Rig.write(text, to: pipe.writer)

        #expect(outcome == .delivered)
        #expect(Self.signalled(finished))
        let tail = received.withLock { Array($0.suffix(1_200)) }
        #expect(String(decoding: tail, as: UTF8.self) == text + "\n")
    }

    /// Synchronous, because a semaphore may not be waited on from an `async` function directly.
    private static func signalled(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }

    // MARK: - Within a bound (set): the review's probe

    /// **The probe from the review of #324.** Free space strictly between `PIPE_BUF` and the
    /// line: 600 bytes free, a 2,000-byte line, a reader that has stopped reading. `poll` says
    /// writable, and a whole-line `write(2)` parked until the reader drained the pipe. Now one
    /// chunk is written, the pipe says it has no more room, and the write gives up when its
    /// bound is spent.
    ///
    /// **Mutation:** write the whole remaining line instead of at most `chunk`
    /// (`size = bytes.count - written` in the bounded branch). Run: red — the write parks.
    @Test("A pipe with 600 bytes free and a 2,000-byte line gives up instead of parking")
    func theReviewsProbe() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        pipe.fill(leavingFree: 600)
        try #require(pipe.pollsWritable, "precondition: poll calls 600 bytes of room writable")
        let before = pipe.queued
        let wait = ScriptedWait()
        let patience = Rig.patience(wait)
        let writer = pipe.writer
        let text = Rig.line(2_000)

        let outcome = Rig.promptly(
            unblocking: { _ = pipe.read(65_536) },
            running: {
                Rig.write(text, to: writer, patience: patience)
            })

        #expect(outcome == .gaveUp, "\(String(describing: outcome))")
        #expect(pipe.queued - before == FileDescriptorWriter.chunk, "one chunk, and no more")
        #expect(wait.slices == 20, "the bound is twenty 100 ms waits")
    }

    @Test("The wait ends at once when the caller is asked to stop")
    func aStopRequestEndsTheWait() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        pipe.fill(leavingFree: 600)
        let stopRequested = OSAllocatedUnfairLock(initialState: false)
        let wait = ScriptedWait { number in
            if number == 3 { stopRequested.withLock { $0 = true } }
        }
        let patience = Rig.patience(wait, stop: { stopRequested.withLock { $0 } })
        let writer = pipe.writer
        let text = Rig.line(2_000)

        let outcome = Rig.promptly(
            unblocking: { _ = pipe.read(65_536) },
            running: {
                Rig.write(text, to: writer, patience: patience)
            })

        #expect(outcome == .gaveUp)
        #expect(wait.slices == 3, "ended by the stop request, not by the bound")
    }

    /// A reader that resumes inside the bound gets the whole line.
    @Test("A reader that makes room inside the bound is delivered to whole")
    func theReaderResumes() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        pipe.fill(leavingFree: 600)
        let reader = pipe.reader
        let drained = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
        let wait = ScriptedWait { number in
            guard number == 2 else { return }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(reader, &chunk, chunk.count)
            let bytes = Array(chunk.prefix(max(count, 0)))
            drained.withLock { $0 += bytes }
        }
        let patience = Rig.patience(wait)
        let writer = pipe.writer
        let text = Rig.line(2_000)

        let outcome = Rig.promptly(
            unblocking: { _ = pipe.read(65_536) },
            running: {
                Rig.write(text, to: writer, patience: patience)
            })

        #expect(outcome == .delivered)
        let rest = pipe.drain()
        let whole = drained.withLock { $0 } + rest
        #expect(String(decoding: whole.suffix(2_000), as: UTF8.self) == text + "\n")
    }

    @Test("A line that fits is written without waiting at all")
    func aLineThatFits() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        let wait = ScriptedWait()
        #expect(
            Rig.write(Rig.line(2_000), to: pipe.writer, patience: Rig.patience(wait))
                == .delivered)
        #expect(wait.slices == 0)
        #expect(pipe.queued == 2_000)
    }

    /// The one state the first version's test covered: no room at all.
    @Test("A pipe with no room gives up")
    func fullPipe() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        pipe.fill(leavingFree: 0)
        let wait = ScriptedWait()
        let patience = Rig.patience(wait)
        let writer = pipe.writer

        let outcome = Rig.promptly(
            unblocking: { _ = pipe.read(65_536) },
            running: {
                Rig.write("no room", to: writer, patience: patience)
            })

        #expect(outcome == .gaveUp)
    }

    // MARK: - poll(2) itself

    /// `poll` is the production wait, so it is proved with a real reader and real time: a reader
    /// that resumes after a short delay, inside a bound of two seconds. Nothing asserts how long
    /// it took; a pass returns as soon as the room is there.
    ///
    /// **Mutation:** make `pollForRoom` return `.timedOut` without polling. Run: red — the bound
    /// is spent in microseconds, before the reader has moved.
    @Test("The real wait delivers to a reader that resumes a moment later")
    func theRealWaitSeesTheReaderResume() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        pipe.fill(leavingFree: 600)
        let reader = pipe.reader
        BackgroundThread.run {
            Thread.sleep(forTimeInterval: 0.05)
            var chunk = [UInt8](repeating: 0, count: 65_536)
            _ = Darwin.read(reader, &chunk, chunk.count)
        }
        let patience = FileDescriptorWriter.Patience(
            limit: .seconds(2), slice: .milliseconds(100), stop: { false })
        let writer = pipe.writer
        let text = Rig.line(2_000)

        let outcome = Rig.promptly(
            unblocking: { _ = pipe.read(65_536) },
            running: {
                Rig.write(text, to: writer, patience: patience)
            })

        #expect(outcome == .delivered)
    }

    /// And a reader that never resumes is given up on by the slices adding up, in real time.
    ///
    /// **Mutation:** make `pollForRoom` return `.changed` always. Run: red — the wait never
    /// counts toward the bound and the write never gives up.
    @Test("The real wait gives up on a reader that never resumes")
    func theRealWaitGivesUp() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        pipe.fill(leavingFree: 600)
        let patience = FileDescriptorWriter.Patience(
            limit: .milliseconds(300), slice: .milliseconds(100), stop: { false })
        let writer = pipe.writer
        let text = Rig.line(2_000)

        let outcome = Rig.promptly(
            unblocking: { _ = pipe.read(65_536) },
            running: {
                Rig.write(text, to: writer, patience: patience)
            })

        #expect(outcome == .gaveUp)
    }

    @Test("pollForRoom reports a change at once when there is room, a timeout when there is none")
    func pollForRoom() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }
        #expect(FileDescriptorWriter.pollForRoom(pipe.writer, .milliseconds(10)) == .changed)
        pipe.fill(leavingFree: 0)
        #expect(FileDescriptorWriter.pollForRoom(pipe.writer, .milliseconds(10)) == .timedOut)
    }
}
