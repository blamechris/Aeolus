import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// What a parked line leaves in a real pipe, through the real writer and a real pump: a whole
/// `started` line and then the first bytes of a `holding` line that the pipe had room for. The
/// closing event must not be appended to those bytes: it is on standard error, and standard
/// output holds no complete line that does not parse.
///
/// The pipe is ordinary: filled with newlines, with room for the `started` line and part of the
/// next. Nothing here takes the machine to the pipe-memory ceiling; the writer that parks on that
/// is `BlockedWriter`, in `FanctlSetBlockedWriterTests`.
@Suite("fanctl set against a pipe that fills mid-line", .timeLimit(.minutes(1)))
struct FanctlSetFragmentTests {

    typealias Harness = SetHarness

    /// The pipes, the pumps over them, and how much each will take.
    private struct Rig {
        let out: RealPipe
        let errors: RealPipe
        let outPump: LinePump
        let errorPump: LinePump
        /// Everything the output pipe holds when it is full.
        let capacity: Int
        /// Room left for the `holding` line after the `started` line: a fragment of it.
        let fragmentRoom: Int

        var terminal: Terminal {
            Terminal(sinks: { OutputSinks(standardOutput: outPump, standardError: errorPump) })
        }

        init(startedBytes: Int) throws {
            let output = try RealPipe()
            let diagnostics = try RealPipe()
            let room = 520
            output.fill(leavingFree: startedBytes + room, with: 0x0A)
            out = output
            errors = diagnostics
            fragmentRoom = room
            capacity = output.queued + startedBytes + room
            let outputWriter = output.writer
            let diagnosticsWriter = diagnostics.writer
            outPump = LinePump(threaded: "test.out") { line in
                FileDescriptorWriter.writeLine(line, to: outputWriter, ignoringSIGPIPE: false)
            }
            errorPump = LinePump(threaded: "test.err") { line in
                FileDescriptorWriter.writeLine(line, to: diagnosticsWriter, ignoringSIGPIPE: false)
            }
        }

        /// Frees a parked writer, lets it finish, and only then closes the descriptors it writes
        /// to: a descriptor number closed under a thread that is still writing to it can be
        /// reused by another test. Synchronous, for `Thread.sleep`.
        func finish() {
            var waited = 0
            while !outPump.status.isIdle, waited < 2_000 {
                _ = out.drain()
                Thread.sleep(forTimeInterval: 0.001)
                waited += 1
            }
            outPump.close()
            errorPump.close()
            out.close()
            errors.close()
        }
    }

    /// The lengths, in bytes with the newline, of the `started` line a run of this shape writes:
    /// measured from a real run, so a change to the JSON moves the test with it.
    private static func startedLength() async throws -> Int {
        let harness = ClientListenerHarness(authority: SimulatedFanAuthority())
        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)
        let first = try #require(run.output.lines.first { $0.stream == .standardOutput })
        _ = harness.sessions
        return first.text.utf8.count + 1
    }

    /// Waits, in real time, for the pump to have written what the pipe will take, then at the
    /// first heartbeat's line sends the signal. Real time passes here and never virtual.
    private static func script(
        _ rig: Rig, desk: SignalDesk, box: OSAllocatedUnfairLock<VirtualHoldTime?>
    ) -> VirtualHoldTime.Script {
        let signalled = OSAllocatedUnfairLock(initialState: false)
        return { _, _ in
            let holdingHandedOver = (box.withLock { $0 }?.elapsed ?? .zero) >= .seconds(10)
            let target =
                holdingHandedOver ? rig.capacity - 16 : rig.capacity - rig.fragmentRoom - 16
            for _ in 0..<2_000 where rig.out.queued < target {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard holdingHandedOver else { return }
            let first = signalled.withLock { already -> Bool in
                defer { already = true }
                return !already
            }
            if first { desk.send(.interrupt) }
        }
    }

    @Test("A line left half-way in a real pipe is not glued to the closing event")
    func fragmentInARealPipe() async throws {
        let rig = try Rig(startedBytes: try await Self.startedLength())
        defer { rig.finish() }
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let box = OSAllocatedUnfairLock<VirtualHoldTime?>(initialState: nil)
        let time = VirtualHoldTime(script: Self.script(rig, desk: desk, box: box))
        box.withLock { $0 = time }

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, desk: desk,
            terminal: rig.terminal)

        #expect(run.code == nil)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        Self.expectStandardOutput(String(decoding: rig.out.drain(), as: UTF8.self))
        Self.expectStandardError(String(decoding: rig.errors.drain(), as: UTF8.self))
        _ = harness.sessions
    }

    /// Standard output: every complete line parses, the only event is `started`, and what
    /// follows the last newline is the front of the parked line, with no closing event in it.
    private static func expectStandardOutput(_ stdout: String) {
        let parts = stdout.components(separatedBy: "\n")
        let complete = parts.dropLast().filter { !$0.isEmpty }
        let events = complete.map { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        #expect(events.allSatisfy { $0 != nil }, "every complete line on standard output parses")
        #expect(events.compactMap { $0?["event"] as? String } == ["started"])
        let fragment = parts.last ?? ""
        #expect(!fragment.isEmpty, "the pipe holds the first bytes of the parked line")
        #expect(!fragment.contains("\"ended\""))
    }

    /// Standard error: the closing event, once, and it parses.
    private static func expectStandardError(_ stderr: String) {
        let closing = stderr.components(separatedBy: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        #expect(closing.map { $0["event"] as? String } == ["ended"])
        #expect(closing.first?["endedBecause"] as? String == "signal")
    }
}
