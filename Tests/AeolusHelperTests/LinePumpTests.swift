import Foundation
import Testing
import os

@testable import fanctl

/// The pump `fanctl set` writes through: a thread of its own, so that handing a line over never
/// waits, and a status the hold can read without waiting either. The writers here park on
/// demand (`BlockedWriter`), which is the whole point: a writer that parks is the case the pump
/// exists for. Every wait in this file is bounded, and a park is always released.
@Suite("The line pump", .timeLimit(.minutes(1)))
struct LinePumpTests {

    private static let origin = ContinuousClock.now

    private static func instant(_ seconds: Int) -> ContinuousClock.Instant {
        origin + .seconds(seconds)
    }

    /// Waits, in real time and for at most two seconds, until `condition` holds. A pass reaches
    /// it in a few milliseconds.
    private static func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    // MARK: - Lines

    @Test("Lines are written in the order they were handed over, and the pump goes idle")
    func inOrder() async {
        let writer = BlockedWriter(parkingFromLine: nil)
        let pump = LinePump(threaded: "test", write: writer.write)
        defer { pump.close() }

        for (number, text) in ["one", "two", "three"].enumerated() {
            pump.enqueue(text, at: Self.instant(number))
        }

        #expect(await Self.eventually { pump.status.isIdle })
        #expect(writer.completeLines == ["one", "two", "three"])
        #expect(pump.status.isBroken == false)
    }

    /// **The point of the pump.** The writer is parked, and handing over a line neither waits nor
    /// is refused. Everything handed over is written, in order, once it is released.
    ///
    /// **Mutation:** write the line on the caller's thread (`drain()` in `enqueue`, whatever the
    /// pump's mode). Run: red — the test thread parks in the first `enqueue`, and the time limit
    /// ends the suite.
    @Test("Handing a line to a parked writer returns at once, and the lines wait their turn")
    func parkedWriter() async {
        let writer = BlockedWriter(parkingFromLine: 1)
        let pump = LinePump(threaded: "test", write: writer.write)
        defer {
            writer.release()
            pump.close()
        }

        pump.enqueue("first", at: Self.instant(0))
        #expect(await Self.eventually { writer.isParked })
        pump.enqueue("second", at: Self.instant(1))
        pump.enqueue("third", at: Self.instant(2))

        #expect(pump.status.isIdle == false)
        #expect(pump.status.oldestUnfinished == Self.instant(0))
        #expect(writer.started == ["first"], "the others have not been begun")

        writer.release()
        #expect(await Self.eventually { pump.status.isIdle })
        #expect(writer.completeLines == ["first", "second", "third"])
    }

    /// What the hold judges a consumer by: how long ago the oldest unfinished line was handed
    /// over. It moves on when that line finishes, and is the next line's when there is one.
    ///
    /// **Mutation:** report the newest line's instant instead of the oldest
    /// (`state.waiting.last`). Run: red.
    @Test("The oldest unfinished line is the one the status reports")
    func oldestUnfinished() async {
        let writer = BlockedWriter(parkingFromLine: 1)
        let pump = LinePump(threaded: "test", write: writer.write)
        defer {
            writer.release()
            pump.close()
        }
        pump.enqueue("a", at: Self.instant(10))
        #expect(await Self.eventually { writer.isParked })
        pump.enqueue("b", at: Self.instant(20))
        #expect(pump.status.oldestUnfinished == Self.instant(10))

        writer.release()

        #expect(await Self.eventually { pump.status.isIdle })
        #expect(pump.status.oldestUnfinished == nil)
    }

    // MARK: - A writer that fails

    /// A reader that left while a line was waiting: the pump is broken, drops what was queued
    /// behind it, and refuses what is handed over after.
    ///
    /// **Mutation:** keep the queue after a failure (drop `state.waiting.removeAll()` in `end`).
    /// Run: red — the queued lines are written to a stream that has failed.
    @Test("A failed write breaks the pump: what was queued is dropped and nothing more is taken")
    func broken() async {
        let writer = BlockedWriter(parkingFromLine: 1, outcomeWhenReleased: .readerGone)
        let pump = LinePump(threaded: "test", write: writer.write)
        defer {
            writer.release()
            pump.close()
        }
        pump.enqueue("lost", at: Self.instant(0))
        #expect(await Self.eventually { writer.isParked })
        pump.enqueue("queued", at: Self.instant(1))

        writer.release()

        #expect(await Self.eventually { pump.status.isBroken })
        #expect(pump.status.isIdle, "a broken pump has dropped everything")
        pump.enqueue("after", at: Self.instant(2))
        #expect(pump.status.isIdle)
        #expect(writer.started == ["lost"], "nothing was written after the failure")
    }

    // MARK: - Inline

    @Test("An inline pump writes before enqueue returns, and breaks on a failure")
    func inline() {
        let written = OSAllocatedUnfairLock<[String]>(initialState: [])
        let accepting = OSAllocatedUnfairLock(initialState: true)
        let pump = LinePump(inline: { line in
            written.withLock { $0.append(line) }
            return accepting.withLock { $0 } ? .delivered : .readerGone
        })

        pump.enqueue("one", at: Self.instant(0))
        #expect(written.withLock { $0 } == ["one"])
        #expect(pump.status.isIdle)

        accepting.withLock { $0 = false }
        pump.enqueue("two", at: Self.instant(1))
        pump.enqueue("three", at: Self.instant(2))

        #expect(
            written.withLock { $0 } == ["one", "two"], "a failed stream is not written to again")
        #expect(pump.status.isBroken)
    }

    // MARK: - The terminal fanctl ships

    /// `Terminal.writing` is what `fanctl` runs with. Its pumps must be threaded: over a pipe that
    /// is full, handing a line over returns, and the line is written when the reader reads.
    ///
    /// **Mutation:** build either pump `inline` in `Terminal.writing`. Run: red — the hand-over
    /// parks its thread, and the bounded wait for it to return fails.
    @Test("The shipped terminal hands lines to threads of their own")
    func shippedTerminalIsThreaded() async throws {
        let out = try RealPipe()
        let errors = try RealPipe()
        out.fill(leavingFree: 0)
        let sinks = Terminal.writing(
            to: out.writer, errors: errors.writer, ignoringSIGPIPE: false
        ).lineSinks()
        defer {
            sinks.standardOutput.close()
            sinks.standardError.close()
        }
        let returned = OSAllocatedUnfairLock(initialState: false)
        BackgroundThread.run {
            sinks.standardOutput.enqueue("hello", at: ContinuousClock.now)
            returned.withLock { $0 = true }
        }

        #expect(await Self.eventually { returned.withLock { $0 } }, "the hand-over returned")
        #expect(sinks.standardOutput.status.isIdle == false, "the line waits for the reader")

        #expect(
            await Self.eventually {
                _ = out.drain()
                return sinks.standardOutput.status.isIdle
            })
        Self.release(out, errors)
    }

    /// Closes the descriptors once nothing is writing to them.
    private static func release(_ out: RealPipe, _ errors: RealPipe) {
        out.close()
        errors.close()
    }

    // MARK: - Closing

    /// `close` lets the thread end once what it was handed is written, and the pump refuses
    /// lines after. A thread that outlived every run would be a thread per test for the life of
    /// the process; the writer is released with the thread, which is how this is seen.
    ///
    /// **Mutation:** never end the loop (drop the `isClosed` return in `run`). Run: red.
    @Test("A closed pump finishes what it was given, then its thread ends")
    func closing() async {
        /// Says when it is let go, which a pump's thread does when it ends.
        final class Sentinel: Sendable {
            let letGo: OSAllocatedUnfairLock<Bool>
            init(_ letGo: OSAllocatedUnfairLock<Bool>) { self.letGo = letGo }
            deinit { letGo.withLock { $0 = true } }
        }
        let letGo = OSAllocatedUnfairLock(initialState: false)
        let writer = BlockedWriter(parkingFromLine: nil)
        var pump: LinePump? = {
            let owned = Sentinel(letGo)
            return LinePump(
                threaded: "test",
                write: { line in
                    _ = owned
                    return writer.write(line)
                })
        }()
        pump?.enqueue("last", at: Self.instant(0))

        pump?.close()
        pump?.enqueue("too late", at: Self.instant(1))
        #expect(await Self.eventually { writer.completeLines == ["last"] })
        #expect(pump?.status.isIdle == true, "a line handed over after the close was refused")
        pump = nil

        #expect(await Self.eventually { letGo.withLock { $0 } }, "the thread has ended and let go")
        #expect(writer.completeLines == ["last"])
    }
}
