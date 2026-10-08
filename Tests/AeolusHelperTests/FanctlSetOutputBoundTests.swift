import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set` writing to a pipe whose reader has stopped.
///
/// The review of #324 found that a `set --json` line (560 to 1,127 bytes) written to a pipe with
/// between 512 bytes and a line's length free parked the process in `write(2)`: `poll` calls a
/// pipe writable at 512 free, and the write was of the whole line. A process stuck there stops
/// renewing its lease and cannot be stopped by SIGINT, SIGTERM or SIGHUP. Here the hold's stdout
/// is a **real pipe** with exactly that much room and a reader that never reads; the shipping
/// `run()`, the real writer and a real `poll(2)` for room are all in play. Only the *wait* is
/// virtual: each 100 ms slice advances the hold's virtual clock instead of sleeping, so "within
/// the bound" is a statement about virtual time, and no test asserts a wall-clock bound.
///
/// What each must show: the hold ends, the lease is released, and it happens before the next
/// renewal would have been due.
@Suite("fanctl set against a reader that stopped reading", .timeLimit(.minutes(1)))
struct FanctlSetOutputBoundTests {

    typealias Harness = SetHarness

    // MARK: - The rig

    /// A `set --json` run whose standard output is a pipe with `free` bytes of room and no
    /// reader, and whose waits for room are virtual.
    struct Stalled {
        let code: Int32?
        let out: RealPipe
        let errors: RealPipe
        let time: VirtualHoldTime
        let waits: Int
    }

    /// The lengths, in bytes, of the `started` and `holding` lines a run of this shape writes.
    /// Measured from a real run rather than assumed, so a change to the JSON moves the test's
    /// numbers with it and cannot quietly move the stall out of the state under test.
    static func lineLengths() async throws -> (started: Int, holding: Int) {
        let harness = ClientListenerHarness(authority: SimulatedFanAuthority())
        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)
        let lines = run.output.lines.filter { $0.stream == .standardOutput }.map(\.text)
        _ = harness.sessions
        return (lines[0].utf8.count + 1, lines[1].utf8.count + 1)
    }

    static func run(
        freeBytes free: Int, arguments: [String] = Harness.thirtySeconds + ["--json"],
        onWait: @escaping @Sendable (Int, VirtualHoldTime, SignalDesk) -> Void = { _, _, _ in },
        authority: SimulatedFanAuthority = SimulatedFanAuthority()
    ) async throws -> (stalled: Stalled, authority: SimulatedFanAuthority) {
        let out = try RealPipe()
        let errors = try RealPipe()
        out.fill(leavingFree: free)
        try #require(
            out.pollsWritable, "precondition: \(free) bytes free is 'writable' to poll")

        let time = VirtualHoldTime()
        let desk = SignalDesk()
        let waits = OSAllocatedUnfairLock(initialState: 0)
        let terminal = Terminal.writing(
            to: out.writer, errors: errors.writer,
            waiting: { _, slice in
                time.advance(by: slice)
                let number = waits.withLock { value -> Int in
                    value += 1
                    return value
                }
                onWait(number, time, desk)
                return .timedOut
            },
            ignoringSIGPIPE: false)

        let harness = ClientListenerHarness(authority: authority)
        var command = try Harness.command(
            arguments, endpoint: harness.endpoint, output: RecordingTerminal(), time: time,
            desk: desk)
        command.terminal = terminal

        let running = Task { [command] in await exitCode { try await command.run() } }
        let code = await Self.finishing(running, unblocking: out)
        _ = harness.sessions
        return (
            Stalled(
                code: code, out: out, errors: errors, time: time, waits: waits.withLock { $0 }),
            authority
        )
    }

    /// The command's exit code, or `nil` if it did not come back within twenty seconds, in which
    /// case the pipe is drained so that a write parked in it finishes. The twenty seconds are
    /// only ever spent when the guard under test is broken.
    static func finishing(
        _ running: Task<Int32?, Never>, unblocking out: RealPipe
    ) async -> Int32? {
        await withTaskGroup(of: Int32??.self) { group in
            group.addTask { .some(await running.value) }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return .none
            }
            let first = await group.next() ?? .none
            group.cancelAll()
            guard let finished = first else {
                _ = out.drain()
                return nil
            }
            return finished
        }
    }

    // MARK: - The review's probe, end to end

    /// **The probe.** Room for a chunk and not for the line, and a reader that never reads: the
    /// first `started` line parks the whole-line writer. Here it is written a chunk at a time,
    /// the pipe says it is full, a SIGINT arrives while the line waits, and the hold releases and
    /// ends. The wait costs 300 virtual milliseconds, three slices, and no renewal is skipped
    /// because none had yet fallen due.
    ///
    /// **Mutation:** write the whole remaining line in the bounded branch of
    /// `FileDescriptorWriter.write` (`size = bytes.count - written`). Run: red — the run parks
    /// and never comes back.
    @Test("A SIGINT while a line waits on a reader that stopped releases the lease and ends")
    func aSignalWhileTheStartLineWaits() async throws {
        let lengths = try await Self.lineLengths()
        let free = FileDescriptorWriter.chunk + 18
        try #require(free < lengths.started, "precondition: room for a chunk, not for the line")

        let (stalled, authority) = try await Self.run(freeBytes: free) { number, _, desk in
            if number == 3 { desk.send(.interrupt) }
        }
        defer {
            stalled.out.close()
            stalled.errors.close()
        }

        #expect(stalled.code == nil, "ended by the signal, the helper reports the safe state")
        #expect(await Harness.count("apply", in: authority) == 1)
        #expect(
            await Harness.count("releaseLease", in: authority) == 1, "the lease was released")
        #expect(await Harness.count("renewLease", in: authority) == 0)
        #expect(await authority.currentLease == nil)
        #expect(stalled.waits == 3, "ended by the signal on the third wait, not by the bound")
        #expect(stalled.time.elapsed == .milliseconds(300))
        let said = String(decoding: stalled.errors.drain(), as: UTF8.self)
        #expect(!said.contains("did not make room"), "the signal, not the reader: \(said)")
        let queued = String(decoding: stalled.out.drain(), as: UTF8.self)
        #expect(
            queued.contains("\"event\":\"started\""), "the first chunk of the line went out")
        #expect(!queued.contains("\"event\":\"ended\""), "the rest of the line was abandoned")
    }

    /// The same stall, and the parent exits instead.
    @Test("A parent that exits while a line waits ends the hold at once")
    func theParentExitsWhileTheStartLineWaits() async throws {
        let lengths = try await Self.lineLengths()
        let free = FileDescriptorWriter.chunk + 18
        try #require(free < lengths.started)

        let (stalled, authority) = try await Self.run(freeBytes: free) { number, _, desk in
            if number == 3 { desk.parentExits() }
        }
        defer {
            stalled.out.close()
            stalled.errors.close()
        }

        #expect(stalled.code == nil)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(stalled.waits == 3)
    }

    // MARK: - No signal: the bound

    /// A reader that does not drain within the bound is treated as gone: the hold releases and
    /// ends as `outputClosed`, and does it well before the first renewal is due (10 s).
    ///
    /// **Mutation:** raise `Terminal.writeBound` to a minute. Run: red — it spends a virtual
    /// minute, and the renewal that fell due in it is the second assertion.
    @Test(
        "A reader that never drains the start line is gone: released well before a renewal is due"
    )
    func aStalledReaderAtTheStart() async throws {
        let lengths = try await Self.lineLengths()
        let free = FileDescriptorWriter.chunk + 18
        try #require(free < lengths.started)

        let (stalled, authority) = try await Self.run(freeBytes: free)
        defer {
            stalled.out.close()
            stalled.errors.close()
        }

        #expect(stalled.code == nil)
        #expect(
            await Harness.count("renewLease", in: authority) == 0, "before the first is due")
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(stalled.time.elapsed < .seconds(10), "within the heartbeat, in virtual time")
        // The start line waited its bound, and so did the closing event: forty slices.
        #expect(stalled.waits == 40)
        let said = String(decoding: stalled.errors.drain(), as: UTF8.self)
        #expect(said.contains("standard output was closed or did not make room"))
    }

    /// The stall begins at a `holding` line, with one renewal already made. The bound is spent
    /// inside the next heartbeat: the hold ends before the second renewal falls due at 20 s.
    @Test("A reader that stops mid-hold is gone before the next renewal is due")
    func aStalledReaderMidHold() async throws {
        let lengths = try await Self.lineLengths()
        let free = lengths.started + FileDescriptorWriter.chunk + 8
        try #require(
            free - lengths.started < lengths.holding, "precondition: no room for a line")

        let (stalled, authority) = try await Self.run(freeBytes: free)
        defer {
            stalled.out.close()
            stalled.errors.close()
        }

        #expect(stalled.code == nil)
        #expect(await Harness.count("renewLease", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(stalled.time.elapsed > .seconds(10), "the first heartbeat was made")
        #expect(stalled.time.elapsed < .seconds(20), "and the second was never due")
        let queued = String(decoding: stalled.out.drain(), as: UTF8.self)
        #expect(queued.contains("\"event\":\"started\""))
        #expect(
            queued.contains("\"event\":\"holding\""), "a chunk of the holding line went out")
    }

    /// Room for the whole of a line is room: nothing waits, and nothing is dropped.
    @Test("A pipe with room for every line is written to without waiting")
    func aReaderWithRoom() async throws {
        let (stalled, authority) = try await Self.run(freeBytes: 12_000)
        defer {
            stalled.out.close()
            stalled.errors.close()
        }

        #expect(stalled.code == nil)
        #expect(stalled.waits == 0)
        #expect(await Harness.count("renewLease", in: authority) == 2)
        let queued = String(decoding: stalled.out.drain(), as: UTF8.self)
        #expect(queued.contains("\"event\":\"ended\""))
    }
}
