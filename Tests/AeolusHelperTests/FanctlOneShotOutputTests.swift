import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// How a SIGPIPE handler these tests install has been reached. A plain integer a signal handler
/// writes, as `sig_atomic_t` is: the handler cannot capture, so it is global.
nonisolated(unsafe) private var sigpipesSeenByOneShotTests: Int32 = 0

/// `status` and `auto` write their output **to the end**, and leave with their own exit code
/// whether or not anyone is left to read it.
///
/// A writer that gave up on a reader that was slow was once applied to every command, and dropped
/// a line whenever a pipe had fewer than 512 bytes free while its reader was still there:
/// `{ cat big.log; fanctl status --json; } | slow-reader` lost the document, where it used to
/// wait. These tests hold the one-shot commands to waiting. `set` does not write directly at all
/// (`FanctlSetBlockedWriterTests`); `reset --all` does not use `Terminal` either.
///
/// Serialised, because the second half installs a SIGPIPE handler, a process-wide thing.
@Suite("fanctl's one-shot commands write to the end", .serialized, .timeLimit(.minutes(1)))
struct FanctlOneShotOutputTests {

    /// Whether `condition` holds within ten seconds, which a pass reaches at once. Polled with
    /// `Task.sleep`, so no worker thread is parked while it waits.
    private static func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    // MARK: - A reader that is slow

    /// `status --json` into a pipe that has room for less than the document, with a reader that
    /// starts reading a moment later. The whole document must arrive.
    ///
    /// **The reader owns its end of the pipe, and closes it when it stops for any reason**,
    /// including the cutoff (`SlowReader`). **The writer is closed in a `defer` as well as when
    /// the command returns**, so a failed `#require` in between cannot leave the reader waiting
    /// for an end that never comes.
    ///
    /// **Mutation:** write only what a refusal-free write takes and report the rest as a failure
    /// (`FileDescriptorWriterTests.toTheEndWaitsForTheReader` is the same guard at the writer).
    /// Run: red — the document is cut off and the prefill is all the reader gets.
    @Test("status --json delivers the whole document to a reader that is slow to start")
    func statusToASlowReader() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let out = try RealPipe()
        let errors = try RealPipe()
        let writerIsOpen = OSAllocatedUnfairLock(initialState: true)
        func closeTheWriter() {
            let wasOpen = writerIsOpen.withLock { isOpen -> Bool in
                defer { isOpen = false }
                return isOpen
            }
            if wasOpen { Darwin.close(out.writer) }
        }
        defer {
            closeTheWriter()
            errors.close()
        }
        out.fill(leavingFree: 300)
        let prefill = out.queued
        let reader = SlowReader(reading: out.reader)
        reader.start()

        var command = try #require(Fanctl.parseAsRoot(["status", "--json"]) as? Fanctl.Status)
        command.helper = HelperConnection(
            transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
            deadlines: FanctlResetTests.unhurried)
        command.terminal = Terminal.writing(
            to: out.writer, errors: errors.writer, ignoringSIGPIPE: false)
        let code = await exitCode { try await command.run() }
        // The reader's end of the story: nothing more is coming.
        closeTheWriter()
        reader.writerClosed()
        #expect(
            await Self.eventually { reader.isFinished },
            "the reader never saw the end of the document")

        #expect(code == nil)
        let document = Array(reader.received.dropFirst(prefill))
        let object = try? JSONSerialization.jsonObject(with: Data(document))
        let json = try #require(object as? [String: Any], "the document arrived whole")
        #expect(json["schema"] as? Int == 1)
        #expect((json["fans"] as? [[String: Any]])?.count == 2)
        _ = harness.sessions
    }

    // MARK: - A reader that is gone

    /// How many SIGPIPEs the handler has seen once it has had a moment to see one. macOS raises
    /// this signal at the process, and the handler runs on whichever thread has it unblocked a
    /// moment after `write` returns: that nothing arrived can only be known after a wait.
    private static func sigpipesAfterAMoment() -> Int32 {
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline, sigpipesSeenByOneShotTests == 0 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return sigpipesSeenByOneShotTests
    }

    private static func installCountingHandler() -> (@convention(c) (Int32) -> Void)? {
        sigpipesSeenByOneShotTests = 0
        return signal(SIGPIPE) { _ in sigpipesSeenByOneShotTests += 1 }
    }

    /// EPIPE neither crashes the command nor changes its exit code: nobody is left to mislead.
    /// The counting handler turns a SIGPIPE that gets through into a failed assertion rather
    /// than a dead test run.
    ///
    /// **Mutation:** call the body directly in `FileDescriptorWriter.writeLine`, without
    /// `ignoringSIGPIPE`. Run: red on `sigpipes == 0`.
    @Test(
        "status into a pipe whose reader has gone keeps its own exit code and raises no SIGPIPE"
    )
    func statusToAGoneReader() async throws {
        let previous = Self.installCountingHandler()
        defer { _ = signal(SIGPIPE, previous) }
        let harness = ClientListenerHarness(authority: SimulatedFanAuthority())
        let errors = try RealPipe()
        defer { errors.close() }
        // The pipe the command inherits has no F_SETNOSIGPIPE: a plain pipe, as a shell makes.
        var plain: [Int32] = [0, 0]
        try #require(pipe(&plain) == 0)
        Darwin.close(plain[0])
        defer { Darwin.close(plain[1]) }

        var command = try #require(Fanctl.parseAsRoot(["status"]) as? Fanctl.Status)
        command.helper = HelperConnection(
            transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
            deadlines: FanctlResetTests.unhurried)
        command.terminal = Terminal.writing(to: plain[1], errors: errors.writer)

        let code = await exitCode { try await command.run() }

        #expect(code == nil, "status succeeded; nobody reading changes nothing about that")
        #expect(Self.sigpipesAfterAMoment() == 0, "the write raised SIGPIPE")
        _ = harness.sessions
    }

    @Test("auto into a pipe whose reader has gone still leaves with 8")
    func autoToAGoneReader() async throws {
        let previous = Self.installCountingHandler()
        defer { _ = signal(SIGPIPE, previous) }
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.ignoringRestore()
        let harness = ClientListenerHarness(authority: authority)
        let errors = try RealPipe()
        defer { errors.close() }
        var plain: [Int32] = [0, 0]
        try #require(pipe(&plain) == 0)
        Darwin.close(plain[0])
        defer { Darwin.close(plain[1]) }

        var command = try #require(Fanctl.parseAsRoot(["auto"]) as? Fanctl.Auto)
        command.helper = HelperConnection(
            transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
            deadlines: FanctlResetTests.unhurried)
        command.terminal = Terminal.writing(to: plain[1], errors: plain[1])
        command.clock = VirtualSettleTime().clock

        let code = await exitCode { try await command.run() }

        #expect(code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        #expect(Self.sigpipesAfterAMoment() == 0, "the write raised SIGPIPE")
        _ = harness.sessions
    }
}

/// The reading end of a pipe, on a thread of its own, that starts a moment late and stops when the
/// writer has closed and the pipe is drained.
///
/// **It owns its descriptor and closes it when it stops, for any reason**, including the cutoff. A
/// writer blocked on a full pipe whose reader has gone but whose descriptor is still open has
/// neither a consumer nor EPIPE and can stay blocked for good, in a syscall the suite's
/// cooperative `.timeLimit` cannot cancel. Closing the descriptor gives it EPIPE, `status` ignores
/// that, and the test fails on the truncated document instead of hanging the process.
///
/// Not "until nothing arrives for a moment": the document arrives after the command's round trips
/// to the helper, and on a runner that is starved a gap of more than two seconds there was seen on
/// CI, twice, at the same head. A reader that had left by then took the pipe's prefill and nothing
/// else, and the command, writing into an empty pipe, still exited 0.
private final class SlowReader: Sendable {

    /// The longest the reader waits for the command, counted from when it started reading.
    ///
    /// CI measured the test at **33 seconds** on a starved runner, at the head where it flaked
    /// (the document arrives after the command's round trips to the helper, and every one of
    /// them was slow); the old forty-five left twelve seconds of margin over it. Fifty-five is
    /// 1.7 times that, and still under the suite's one-minute `.timeLimit`, so a reader that
    /// gives up does so *before* the limit and the test fails on what it read, not on a timeout.
    static let wholeRun: TimeInterval = 55

    /// How long the reader may take to see the end of the document once the writer has closed:
    /// the ten seconds `eventually` gives the test to see it finish. Every byte is already in the
    /// pipe by then, so the reader has only to drain it. This is not a wait for the command.
    static let drainAfterTheWriterClosed: TimeInterval = 10

    private let descriptor: Int32
    private let bytes = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
    private let done = OSAllocatedUnfairLock(initialState: false)
    private let closedAt = OSAllocatedUnfairLock<Date?>(initialState: nil)

    init(reading descriptor: Int32) {
        self.descriptor = descriptor
    }

    var received: [UInt8] { bytes.withLock { $0 } }
    var isFinished: Bool { done.withLock { $0 } }

    /// The test has closed the writer: the drain bound counts from now.
    func writerClosed() {
        closedAt.withLock { $0 = Date() }
    }

    func start() {
        BackgroundThread.run { [self] in
            Thread.sleep(forTimeInterval: 0.05)
            read()
            Darwin.close(descriptor)
            done.withLock { $0 = true }
        }
    }

    private func isOverdue(at now: Date, cutoff: Date) -> Bool {
        if now >= cutoff { return true }
        // Counted from when the writer closed, not from when the command began: how long the
        // command took says nothing about how long a drain should.
        guard let closed = closedAt.withLock({ $0 }) else { return false }
        return now >= closed.addingTimeInterval(Self.drainAfterTheWriterClosed)
    }

    private func read() {
        let cutoff = Date().addingTimeInterval(Self.wholeRun)
        var chunk = [UInt8](repeating: 0, count: 8_192)
        while !isOverdue(at: Date(), cutoff: cutoff) {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&request, 1, 250)
            if ready == 0 { continue }
            if ready < 0 { return }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count <= 0 { return }
            let taken = Array(chunk.prefix(count))
            bytes.withLock { $0 += taken }
        }
    }
}
