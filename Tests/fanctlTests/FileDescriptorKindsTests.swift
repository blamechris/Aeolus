import Foundation
import Testing
import os

@testable import fanctl

/// `FileDescriptorWriter` on everything that is not a pipe: sockets, which are asked for room the
/// way pipes are, and files, devices and bad descriptors, which are not.
@Suite("Writing a line to a socket, a file or a device", .serialized)
struct FileDescriptorKindsTests {

    typealias Rig = WriterRig

    // MARK: - Sockets

    /// A socket pair, written to the way a Node `child_process` stdio would be.
    private struct Sockets {
        let reader: Int32
        let writer: Int32

        init() throws {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            reader = fds[0]
            writer = fds[1]
            _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        }

        func close() {
            Darwin.close(reader)
            Darwin.close(writer)
        }

        /// Fills the writer's side. The writer is made non-blocking for the length of the fill,
        /// on this test's own socket: `MSG_DONTWAIT` is not honoured by `send` on a blocking
        /// `AF_UNIX` socket here, and a fill that waited would park the test itself.
        func fill() {
            let flags = fcntl(writer, F_GETFL)
            _ = fcntl(writer, F_SETFL, flags | O_NONBLOCK)
            var filler = [UInt8](repeating: 0x61, count: 1_024)
            while send(writer, &filler, filler.count, 0) > 0 {}
            _ = fcntl(writer, F_SETFL, flags)
        }

        /// Reads everything queued, without waiting for more.
        func drain() {
            let flags = fcntl(reader, F_GETFL)
            _ = fcntl(reader, F_SETFL, flags | O_NONBLOCK)
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while recv(reader, &chunk, chunk.count, 0) > 0 {}
            _ = fcntl(reader, F_SETFL, flags)
        }
    }

    /// **Mutation:** ask only pipes (`canStall = kind == S_IFIFO`). Run: red — a socket whose
    /// peer has stopped reading parks the write, and the assertion that it came back fails.
    @Test("A socket whose peer has stopped reading gives up instead of parking")
    func fullSocket() throws {
        let sockets = try Sockets()
        defer { sockets.close() }
        sockets.fill()
        let wait = ScriptedWait()
        let patience = Rig.patience(wait)
        let writer = sockets.writer

        let outcome = Rig.promptly(
            unblocking: { sockets.drain() },
            running: {
                Rig.write(Rig.line(2_000), to: writer, patience: patience)
            })

        #expect(outcome == .gaveUp)
        #expect(wait.slices == 20)
    }

    @Test("A socket whose peer has gone reports it")
    func closedSocket() throws {
        let sockets = try Sockets()
        Darwin.close(sockets.reader)
        defer { Darwin.close(sockets.writer) }
        let wait = ScriptedWait()
        let writer = sockets.writer
        let patience = Rig.patience(wait)

        let outcome = Rig.promptly(
            unblocking: {},
            running: {
                Rig.write("hello?", to: writer, patience: patience)
            })

        #expect(outcome == .readerGone)
    }

    @Test("To the end: a socket receives the line whole")
    func socketToTheEnd() throws {
        let sockets = try Sockets()
        defer { sockets.close() }
        #expect(Rig.write("over a socket", to: sockets.writer) == .delivered)
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = recv(sockets.reader, &buffer, buffer.count, MSG_DONTWAIT)
        #expect(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self) == "over a socket\n")
    }

    // MARK: - Everything that is not a pipe or a socket

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
        let wait = ScriptedWait()
        #expect(
            Rig.write("into the void", to: descriptor, patience: Rig.patience(wait))
                == .delivered)
    }

    @Test("A regular file receives the line")
    func regularFile() throws {
        let path = NSTemporaryDirectory() + "fanctl-writer-\(UUID().uuidString)"
        defer { unlink(path) }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        #expect(descriptor >= 0)
        #expect(Rig.write("kept", to: descriptor) == .delivered)
        Darwin.close(descriptor)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "kept\n")
    }

    @Test("A descriptor that is not open fails with EBADF, to the end or within a bound")
    func badDescriptor() {
        #expect(Rig.write("x", to: -1) == .failed(EBADF))
        let wait = ScriptedWait()
        #expect(Rig.write("x", to: -1, patience: Rig.patience(wait)) == .failed(EBADF))
    }

    /// A failure that is not a reader leaving is said on standard error by a one-shot command's
    /// terminal, and never changes its exit code.
    ///
    /// **Mutation:** delete the note in `Terminal.writing`. Run: red.
    @Test("A terminal says a failed standard output on standard error")
    func terminalSaysAFailedWrite() throws {
        let errors = try TestPipe()
        defer { errors.close() }
        let terminal = Terminal.writing(to: -1, errors: errors.writer, ignoringSIGPIPE: false)

        terminal.say("the document")

        let note = String(decoding: errors.drain(), as: UTF8.self)
        #expect(note.contains("could not write to standard output"))
        #expect(note.contains(String(cString: strerror(EBADF))))
    }
}
