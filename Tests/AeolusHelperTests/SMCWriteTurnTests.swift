import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// `SMCReadScheduler.withWriteTurn(at:on:_:)`: one turn at the given admission, excluded against every other
/// turn, and taking neither of D22's waits (ADR 0014's B1 amendment; #103's D22 is why a recycle
/// waits for a walk and a write need not).
///
/// Every hold here **suspends** — a continuation, or a job parked on an executor that has not run
/// it yet — and never blocks a thread. Each exclusion claim is shown from both sides of the hold: a
/// double with no suspension inside cannot park anything, and an "only one at a time" assertion
/// against it passes whatever the scheduler does.
@Suite("The scheduler's write turn", .timeLimit(.minutes(1)))
struct SMCWriteTurnTests {

    private static let forceKey = SMCKey.forceTest

    /// Whether `work` finishes within a bounded number of yields, **without** recording anything:
    /// the caller's `#expect` on the answer is the claim, so a mutant that never finishes is red
    /// at that line rather than at a wait.
    private static func completes<Value: Sendable>(_ work: ObservableWork<Value>) async -> Bool {
        for _ in 0..<10_000 {
            if await work.isFinished.isSet { return true }
            await Task.yield()
        }
        return await work.isFinished.isSet
    }

    private static func isWrite(_ entry: FirmwareLog.Entry) -> Bool {
        if case .write = entry { return true }
        return false
    }

    /// Whether both happened, the first before the second.
    private static func precedes(_ first: Int?, _ second: Int?) -> Bool {
        guard let first, let second else { return false }
        return first < second
    }

    // MARK: - The shape

    /// The shape the plane's write turns take: a synchronous job on an `isolated` channel, passed
    /// straight in as a function, inside one write turn.
    @Test("One synchronous job on an isolated channel runs inside one supervisor turn")
    func aJobOnAnIsolatedChannelRunsInsideOneTurn() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)

        let info = try await scheduler.withWriteTurn(
            at: .supervisor, on: firmware, runsOneWriteJob(on:))

        #expect(info.type == .ui8 && info.dataSize == 1)
        #expect(
            firmware.log.entries == [
                .turnGranted(.supervisor),
                .keyInfo(Self.forceKey, .answered),
                .read(Self.forceKey, .answered),
                .write(Self.forceKey, [0x01], .answered),
                .turnEnded(.supervisor),
            ])
    }

    /// The turn is given back on every exit, a throwing job's included — asserted by taking one
    /// after it, which is what a caller gets, rather than by inspecting a flag.
    ///
    /// **Mutation:** move `endTurn(at:)` out of the `defer`, after the job. Run: red — the read
    /// after the throwing job is never served.
    @Test("A write turn whose job throws still gives the connection back")
    func aThrowingJobReleasesItsTurn() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider)

        await #expect(throws: SMCError.notPermitted) {
            try await scheduler.withWriteTurn(at: .supervisor, on: firmware) { channel in
                try channel.write([], to: Self.forceKey)
            }
        }

        let follow = observing { try await scheduler.read(keys: ["F0Md"], at: .supervisor) }
        let served = await Self.completes(follow)
        #expect(served, "a read after a throwing write turn was never served: the turn leaked")
        _ = try await finished("the read after the throwing job", follow)
    }

    // MARK: - Walks

    /// The walk is parked inside the fake, so it is in flight for the scheduler — counted, as a
    /// real one is — for as long as this test says.
    ///
    /// **Mutation:** build `withWriteTurn` on `withExclusiveAccess(_:)`. Run: red — the turn
    /// parks behind the walk.
    @Test("A write turn completes while a discovery walk is in flight")
    func aWriteTurnDoesNotWaitForAWalk() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)
        await firmware.holdWalks()

        let walk = observing { try await scheduler.readAll() }
        await yieldUntil("the walk to park inside the firmware") { await firmware.walksParked == 1 }

        let turn = observing {
            try await scheduler.withWriteTurn(at: .supervisor, on: firmware, runsOneWriteJob(on:))
        }
        let completed = await Self.completes(turn)
        #expect(
            completed,
            """
            the write turn waited for a discovery walk. A write closes no handle, so D22's reason \
            to wait does not apply, and a keystone behind a walk waits for as long as the walk \
            takes — ADR 0014's B1 amendment.
            """)
        #expect(await firmware.walksParked == 1, "the walk was not in flight throughout")

        await firmware.releaseWalks()
        _ = try await finished("the walk", walk)
        _ = try await finished("the write turn", turn)

        let entries = firmware.log.entries
        let write = entries.firstIndex(where: Self.isWrite)
        let walkEnded = entries.firstIndex(of: .walkEnded)
        #expect(Self.precedes(write, walkEnded), "\(entries)")
    }

    /// The other direction: a write turn claims no exclusion, so a walk that starts while one is
    /// held starts.
    ///
    /// **Mutation:** raise `exclusiveClaims` in `withWriteTurn`. Run: red — the walk parks.
    @available(macOS 14, *)
    @Test("A discovery walk started during a write turn does not wait for it")
    func aWalkDoesNotWaitForAWriteTurn() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)
        let held = HeldChannel()

        let turn = observing {
            try await scheduler.withWriteTurn(at: .supervisor, on: held, runsOneWriteJob(on:))
        }
        await yieldUntil("the write turn's job to park") { held.executor.parked == 1 }

        let walk = observing { try await scheduler.readAll() }
        let walked = await Self.completes(walk)
        #expect(walked, "a discovery walk waited for a write turn, which closes no handle")
        #expect(await scheduler.walksWaitingForARecycle == 0)

        held.executor.release()
        _ = try await finished("the write turn", turn)
        _ = try await finished("the walk", walk)
    }

    // MARK: - Turns

    /// The positive control on the exclusion: the write turn is a turn.
    ///
    /// **Mutation:** take no turn in `withWriteTurn` — run the job bare. Run: red — the job writes
    /// while the read holds the turn.
    @Test("A held supervisor read parks the write turn until it is released")
    func aHeldReadParksTheWriteTurn() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)
        await firmware.holdReads()

        let read = observing { try await scheduler.read(keys: ["F0Md"], at: .supervisor) }
        await yieldUntil("the read to hold its turn") { await firmware.readsParked == 1 }

        let turn = observing {
            try await scheduler.withWriteTurn(at: .supervisor, on: firmware, runsOneWriteJob(on:))
        }
        // A disjunction, so the mutant's barging write ends this wait rather than timing it out.
        await yieldUntil("the write turn to queue behind the read, or to barge in") {
            let queued = await scheduler.queuedTurns(at: .supervisor) == 1
            return queued || firmware.log.operations.contains(where: Self.isWrite)
        }
        #expect(
            !firmware.log.operations.contains(where: Self.isWrite),
            "the write job ran while a supervisor read held the turn")

        await firmware.releaseReads()
        _ = try await finished("the read", read)
        _ = try await finished("the write turn", turn)

        let entries = firmware.log.entries
        let readEnded = entries.firstIndex(of: .providerReadEnded)
        let write = entries.firstIndex(where: Self.isWrite)
        #expect(Self.precedes(readEnded, write), "\(entries)")
    }

    /// The turn is held by a job parked on its channel's executor, which is a suspension rather
    /// than a blocked thread.
    ///
    /// **Mutation:** take no turn in `withWriteTurn`. Run: red — the read runs inside the held
    /// write turn.
    @available(macOS 14, *)
    @Test("A held write turn parks a supervisor read until it ends")
    func aHeldWriteTurnParksARead() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)
        let held = HeldChannel()

        let turn = observing {
            try await scheduler.withWriteTurn(at: .supervisor, on: held, runsOneWriteJob(on:))
        }
        await yieldUntil("the write turn's job to park") { held.executor.parked == 1 }

        let began = FirmwareLog.Entry.providerReadBegan(["F0Md"])
        let read = observing { try await scheduler.read(keys: ["F0Md"], at: .supervisor) }
        await yieldUntil("the read to queue behind the write turn, or to barge in") {
            let queued = await scheduler.queuedTurns(at: .supervisor) == 1
            return queued || firmware.log.entries.contains(began)
        }
        #expect(
            !firmware.log.entries.contains(began),
            "a supervisor read ran inside a held write turn")

        held.executor.release()
        _ = try await finished("the write turn", turn)
        _ = try await finished("the read", read)
    }

    /// A recycle takes a turn, so it waits for a held write turn and never closes the handle under
    /// a job.
    @available(macOS 14, *)
    @Test("A held write turn parks a recycle until it ends")
    func aHeldWriteTurnParksARecycle() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)
        let plane = SMCFanControlPlane(scheduler: scheduler, connection: firmware.recycler)
        let held = HeldChannel()

        let turn = observing {
            try await scheduler.withWriteTurn(at: .supervisor, on: held, runsOneWriteJob(on:))
        }
        await yieldUntil("the write turn's job to park") { held.executor.parked == 1 }

        let recycle = observing { try await plane.reconnect() }
        await yieldUntil("the recycle to queue behind the write turn, or to barge in") {
            let queued = await scheduler.queuedTurns(at: .supervisor) == 1
            return queued || firmware.log.entries.contains(.closed)
        }
        #expect(
            !firmware.log.entries.contains(.closed),
            "a recycle closed the handle inside a write turn")

        held.executor.release()
        _ = try await finished("the write turn", turn)
        _ = try await finished("the recycle", recycle)
    }
}

/// A write turn's job as the plane's will be, on the channel's own executor with no suspension
/// inside: fresh key info, the raw read, and the write. `private`, so no other file can hand it a
/// channel.
private func runsOneWriteJob(on channel: isolated any SMCWriteChannel) throws -> SMCKeyInfo {
    let info = try channel.freshKeyInfo(for: SMCKey.forceTest)
    _ = try channel.read(SMCKey.forceTest)
    try channel.write([0x01], to: SMCKey.forceTest)
    return info
}

// MARK: - A channel whose jobs wait to be let run

/// A serial executor that queues every job until `release()`, then runs them, and everything after,
/// on one serial queue. A job queued on it is suspended — its task parked, no thread blocked —
/// which is how a write turn is held open here: the turn is taken, and its job waits.
@available(macOS 14, *)
private final class HeldExecutor: SerialExecutor {
    private struct State {
        var isHeld = true
        var pending: [UnownedJob] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "dev.aeolus.tests.held-executor")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let runsNow = state.withLock { state in
            guard state.isHeld else { return true }
            state.pending.append(job)
            return false
        }
        if runsNow { run(job) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    var parked: Int { state.withLock { $0.pending.count } }

    func release() {
        let jobs = state.withLock { state in
            state.isHeld = false
            defer { state.pending.removeAll() }
            return state.pending
        }
        for job in jobs { run(job) }
    }

    private func run(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

/// A channel on a `HeldExecutor`, answering every requirement trivially.
@available(macOS 14, *)
private actor HeldChannel: SMCWriteChannel {
    nonisolated let executor = HeldExecutor()

    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    var interfaceGeneration: SMCInterfaceGeneration? { .modern }

    func freshKeyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        SMCKeyInfo(key: key, type: .ui8, dataSize: 1, attributes: 0xD0)
    }

    func read(_ key: SMCKey) throws -> SMCValue {
        SMCValue(key: key, type: .ui8, bytes: [0x00])
    }

    func write(_ bytes: [UInt8], to key: SMCKey) throws {}
}
