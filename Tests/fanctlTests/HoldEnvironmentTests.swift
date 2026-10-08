import Foundation
import Testing

@testable import fanctl

/// How many SIGPIPEs the handlers these tests install has seen. A plain integer a
/// signal handler writes, as `sig_atomic_t` is: the handler cannot capture, so it is global.
nonisolated(unsafe) private var sigpipesSeen: Int32 = 0

/// The production signal handlers and parent reader, which every other test substitutes.
///
/// Serialised, because a signal disposition belongs to the whole process. SIGUSR2 is the one sent
/// here, standing in for SIGHUP through the installer production uses: while handlers are
/// installed it is ignored by the process and delivered to the handler. It is **not a real
/// SIGHUP, SIGINT or SIGTERM**, which a test runner may exit on: a CI run ended without a word
/// when one was sent. A missing handler is still loud, since the disposition is asserted before
/// anything is sent.
@Suite("The production hold environment", .serialized, .timeLimit(.minutes(1)))
struct HoldEnvironmentTests {

    /// How many SIGPIPEs the handler has seen once it has had `seconds` to see one, or as soon as
    /// it has seen one when `untilSeen`. macOS raises this SIGPIPE at the *process*, and the
    /// handler runs on whichever thread has the signal unblocked — usually not the writer's — a
    /// moment after `write` returns. So "none arrived" can only be known after a wait, and "one
    /// arrived" as soon as it does.
    private static func sigpipes(waiting seconds: Double, untilSeen: Bool) -> Int32 {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if untilSeen, sigpipesSeen > 0 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return sigpipesSeen
    }

    /// A command that writes to a reader that has gone must leave with its own exit code. The
    /// default action of SIGPIPE is to end the process with 141, and a thread mask does not
    /// prevent it: the kernel delivers the signal to another thread that has it unblocked. So the
    /// writer ignores SIGPIPE for the length of the write. A handler is installed in place of the
    /// default so that a signal which gets through is a counted failure and not a dead test run;
    /// a bare `write` to the same kind of pipe first proves the handler is live.
    ///
    /// **Mutation:** call the body directly in `FileDescriptorWriter.writeLine`, without
    /// `ignoringSIGPIPE`. Run: red — the handler sees the signal.
    @Test("A write to a closed pipe raises no SIGPIPE: the command keeps its own exit code")
    func writeIgnoresSIGPIPE() throws {
        let previous = signal(SIGPIPE) { _ in sigpipesSeen += 1 }
        defer { _ = signal(SIGPIPE, previous) }

        func closedPipe() throws -> Int32 {
            var descriptors: [Int32] = [0, 0]
            try #require(pipe(&descriptors) == 0)
            close(descriptors[0])
            return descriptors[1]
        }

        let control = try closedPipe()
        sigpipesSeen = 0
        _ = write(control, "x", 1)
        close(control)
        try #require(
            Self.sigpipes(waiting: 2, untilSeen: true) == 1,
            "control: a bare write to a closed pipe must raise it")

        let written = try closedPipe()
        defer { close(written) }
        sigpipesSeen = 0

        let outcome = FileDescriptorWriter.writeLine("anyone there?", to: written)

        #expect(outcome == .readerGone)
        #expect(Self.sigpipes(waiting: 0.3, untilSeen: true) == 0, "the write raised SIGPIPE")
        #expect(Self.disposition(of: SIGPIPE) > 1, "the handler was put back after the write")
    }

    /// Two writes that overlap restore SIGPIPE once, when the last is done. The first parks on a
    /// pipe whose reader is not reading, and is inside `ignoringSIGPIPE` for as long as it does;
    /// a second write that comes and goes meanwhile must leave SIGPIPE ignored.
    ///
    /// **Mutation:** restore on every exit, not the last (drop the `depth == 0` test in the
    /// `defer` of `ignoringSIGPIPE`). Run: red — the handler is back while the first write is
    /// still in progress.
    @Test("An overlapping write leaves SIGPIPE ignored until the last write is done")
    func overlappingWrites() throws {
        let previous = signal(SIGPIPE) { _ in sigpipesSeen += 1 }
        defer { _ = signal(SIGPIPE, previous) }

        var full: [Int32] = [0, 0]
        try #require(pipe(&full) == 0)
        defer {
            close(full[0])
            close(full[1])
        }
        let flags = fcntl(full[1], F_GETFL)
        _ = fcntl(full[1], F_SETFL, flags | O_NONBLOCK)
        var filler: UInt8 = 0x61
        while write(full[1], &filler, 1) == 1 {}
        _ = fcntl(full[1], F_SETFL, flags)
        var roomy: [Int32] = [0, 0]
        try #require(pipe(&roomy) == 0)
        defer {
            close(roomy[0])
            close(roomy[1])
        }

        let parkedWriter = full[1]
        let finished = DispatchSemaphore(value: 0)
        BackgroundThread.run {
            _ = FileDescriptorWriter.writeLine(
                "parked until the reader reads", to: parkedWriter)
            finished.signal()
        }
        var waited = 0
        while Self.disposition(of: SIGPIPE) != 1, waited < 200 {
            Thread.sleep(forTimeInterval: 0.01)
            waited += 1
        }
        try #require(Self.disposition(of: SIGPIPE) == 1, "the first write is inside the region")

        #expect(FileDescriptorWriter.writeLine("quick", to: roomy[1]) == .delivered)
        #expect(Self.disposition(of: SIGPIPE) == 1, "the first write is still in progress")

        var drained = [UInt8](repeating: 0, count: 70_000)
        _ = read(full[0], &drained, drained.count)
        #expect(Self.finished(finished), "the parked write should finish once the reader reads")
        #expect(Self.disposition(of: SIGPIPE) > 1, "restored once the last write is done")
    }

    /// Synchronous, because a semaphore may not be waited on from an `async` function directly.
    private static func finished(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }

    /// 0 for `SIG_DFL`, 1 for `SIG_IGN`, anything else is a handler.
    private static func disposition(of signal: Int32) -> Int {
        var action = sigaction()
        sigaction(signal, nil, &action)
        return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
    }

    @Test("The parent is this process's parent")
    func parent() {
        #expect(HoldEnvironment.production.parentProcessID() == getppid())
        #expect(HoldEnvironment.production.parentProcessID() > 0)
    }

    /// The first signal the stream delivers, or `nil` if none comes within `limit`. The limit
    /// matters only when the handler is broken: delivery is immediate otherwise.
    private static func first(
        of stream: AsyncStream<HoldSignal>, within limit: Duration
    ) async -> HoldSignal? {
        await withTaskGroup(of: HoldSignal?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
    }

    /// **Mutation:** make the dispatch source's event handler do nothing
    /// (`source.setEventHandler { }` in `HoldEnvironment.production`). Run: red — nothing is
    /// delivered. Not stopping at `source.resume()`: a source that is never activated traps in
    /// libdispatch when it is released, after the assertion has already failed.
    @Test(
        "A signal sent to the process reaches the handler, and cancelling restores the process",
        .timeLimit(.minutes(1)))
    func signalIsDelivered() async throws {
        // SIGUSR2 stands in for SIGHUP, through the same installer production uses: the three
        // real signals are not sent to a test runner, which may well exit on one of them.
        let before = Self.disposition(of: SIGUSR2)
        let (stream, continuation) = AsyncStream.makeStream(of: HoldSignal.self)
        let subscription = HoldEnvironment.install([(.hangup, SIGUSR2)]) { continuation.yield($0) }
        defer { subscription.cancel() }
        try #require(
            Self.disposition(of: SIGUSR2) == 1, "ignored while the handler is installed")

        kill(getpid(), SIGUSR2)

        #expect(await Self.first(of: stream, within: .seconds(10)) == .hangup)
        subscription.cancel()
        #expect(Self.disposition(of: SIGUSR2) == before, "the previous disposition is back")
    }

    /// The three real signals are claimed while a hold is installed and put back after, but never
    /// sent here.
    ///
    /// **Mutation:** drop `signal(held.number, SIG_IGN)` from `HoldEnvironment.install`. Run: red.
    @Test("The real signals are ignored while installed, and restored after")
    func realSignalsAreClaimed() {
        let before = HoldSignal.all.map { Self.disposition(of: $0.number) }
        let subscription = HoldEnvironment.production.installSignals { _ in }
        #expect(HoldSignal.all.map { Self.disposition(of: $0.number) } == [1, 1, 1])
        subscription.cancel()
        #expect(HoldSignal.all.map { Self.disposition(of: $0.number) } == before)
    }

    /// A write to a closed pipe must come back as an error, not kill a process holding a lease.
    ///
    /// **Mutation:** delete the `SIGPIPE` line in `HoldEnvironment.production`. Run: red.
    @Test("SIGPIPE is ignored while installed, and restored after")
    func sigpipeIsIgnored() {
        let before = Self.disposition(of: SIGPIPE)
        let subscription = HoldEnvironment.production.installSignals { _ in }
        #expect(Self.disposition(of: SIGPIPE) == 1)
        subscription.cancel()
        #expect(Self.disposition(of: SIGPIPE) == before)
    }

    @Test("Cancelling twice puts back what was found, once")
    func cancelTwice() {
        let before = Self.disposition(of: SIGTERM)
        let subscription = HoldEnvironment.production.installSignals { _ in }
        #expect(Self.disposition(of: SIGTERM) == 1)
        subscription.cancel()
        subscription.cancel()
        #expect(Self.disposition(of: SIGTERM) == before)
    }
}
