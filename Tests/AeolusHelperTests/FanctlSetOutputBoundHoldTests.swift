import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// A reader that stops partway through a hold, and a stop request that arrives while the
/// heartbeat's line waits on it. The rig is `FanctlSetOutputBoundTests`'s: a real pipe with a
/// chunk of room and a line's worth of data to write, a real `poll(2)` for room, and a virtual
/// wait.
///
/// What each must show: a signal, the parent exiting, or the deadline ends the wait at once and
/// is the reason the hold ends; none of them is spent waiting out the bound and then called
/// `outputClosed`. The hold's closing line goes to standard error only for `outputClosed`, so its
/// absence there is how the reason is told.
@Suite("fanctl set heartbeats against a reader that stopped", .timeLimit(.minutes(1)))
struct FanctlSetOutputBoundHoldTests {

    typealias Bound = FanctlSetOutputBoundTests
    typealias Harness = SetHarness

    /// The room the pipe has when the stall begins at the first `holding` line: the `started`
    /// line fits, and of the `holding` line only a chunk does.
    private static func midHoldRoom() async throws -> Int {
        let lengths = try await Bound.lineLengths()
        let free = lengths.started + FileDescriptorWriter.chunk + 8
        try #require(free - lengths.started < lengths.holding, "precondition: no room for a line")
        return free
    }

    /// A wait hook that does `act` at the `target`-th wait for room, and nothing at the others.
    private static func atWait(
        _ target: Int, _ act: @escaping @Sendable (SignalDesk) -> Void
    ) -> @Sendable (Int, VirtualHoldTime, SignalDesk) -> Void {
        { number, _, desk in
            if number == target { act(desk) }
        }
    }

    private static let elevenSeconds = ["0", "75%", "--for", "11s", "--json"]

    /// **Mutation:** give the heartbeat's writes a stop that never fires (`session.output
    /// .stopping(when: { false })` in `SetCommand.heartbeats`). Run: red — the line waits out
    /// its whole bound, twenty slices, where the signal ends it at the third.
    @Test("A SIGINT while a heartbeat's line waits ends the hold at once, as a signal")
    func aSignalWhileAHeartbeatWaits() async throws {
        let (stalled, authority) = try await Bound.run(
            freeBytes: Self.midHoldRoom(), onWait: Self.atWait(3, { $0.send(.interrupt) }))
        defer {
            stalled.out.close()
            stalled.errors.close()
        }

        #expect(stalled.code == nil)
        #expect(await Harness.count("renewLease", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(stalled.waits == 3, "ended by the signal on the third wait, not by the bound")
        let said = String(decoding: stalled.errors.drain(), as: UTF8.self)
        #expect(!said.contains("did not make room"), "not the reader's doing: \(said)")
    }

    @Test("A parent that exits while a heartbeat's line waits ends the hold at once")
    func theParentExitsWhileAHeartbeatWaits() async throws {
        let (stalled, authority) = try await Bound.run(
            freeBytes: Self.midHoldRoom(), onWait: Self.atWait(3, { $0.parentExits() }))
        defer {
            stalled.out.close()
            stalled.errors.close()
        }

        #expect(stalled.code == nil)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(stalled.waits == 3)
        let said = String(decoding: stalled.errors.drain(), as: UTF8.self)
        #expect(!said.contains("did not make room"), "not the reader's doing: \(said)")
    }

    /// The deadline falls one second after the first heartbeat, inside the wait for room: the
    /// wait ends there (ten slices of 100 ms), and the closing event, which has nothing to ask
    /// but the reader, spends its bound (twenty).
    ///
    /// **Mutation:** as above, or drop the deadline from `StopWatch.reason`. Run: red.
    @Test("A deadline that falls while a heartbeat's line waits ends it there")
    func theDeadlineFallsWhileAHeartbeatWaits() async throws {
        let (stalled, authority) = try await Bound.run(
            freeBytes: Self.midHoldRoom(), arguments: Self.elevenSeconds)
        defer {
            stalled.out.close()
            stalled.errors.close()
        }

        #expect(stalled.code == nil)
        #expect(await Harness.count("renewLease", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(stalled.waits == 10 + 20)
        let said = String(decoding: stalled.errors.drain(), as: UTF8.self)
        #expect(!said.contains("did not make room"), "not the reader's doing: \(said)")
    }
}
