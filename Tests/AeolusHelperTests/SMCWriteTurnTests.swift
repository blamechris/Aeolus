import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// `SMCReadScheduler.withWriteTurn(_:)`: one `.supervisor` turn, excluded against every other
/// turn, and against **no** discovery walk (ADR 0014's B1 amendment; #103's D22 is why a recycle
/// waits for a walk and a write need not).
///
/// Every hold here **suspends** — a continuation, never a semaphore — and each exclusion claim is
/// shown from both sides of the hold. A double with no `await` inside cannot park anything, and an
/// "only one at a time" assertion against it passes whatever the scheduler does.
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

    /// The shape the plane's write turns will take, compiling now: a synchronous job on the
    /// channel's actor, reached through an `isolated` existential, inside one write turn. B1's
    /// amendment allows a generic in its place if this form would not build; it builds.
    @Test("One synchronous job on an isolated channel runs inside one supervisor turn")
    func aJobOnAnIsolatedChannelRunsInsideOneTurn() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)

        let info = try await scheduler.withWriteTurn { try await runsOneWriteJob(on: firmware) }

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
            try await scheduler.withWriteTurn { try await runsOneWriteJob(on: firmware) }
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
    @Test("A discovery walk started during a write turn does not wait for it")
    func aWalkDoesNotWaitForAWriteTurn() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)
        let hold = TurnHold()

        let turn = observing { await scheduler.withWriteTurn { await hold.park() } }
        await yieldUntil("the write turn to hold its turn") { await hold.isParked }

        let walk = observing { try await scheduler.readAll() }
        let walked = await Self.completes(walk)
        #expect(walked, "a discovery walk waited for a write turn, which closes no handle")
        #expect(await scheduler.walksWaitingForARecycle == 0)

        await hold.release()
        _ = try await finished("the write turn", turn)
        _ = try await finished("the walk", walk)
    }

    // MARK: - Turns

    /// The positive control on the exclusion: the write turn is a turn.
    ///
    /// **Mutation:** take no turn in `withWriteTurn` — run the body bare. Run: red — the job writes
    /// while the read holds the turn.
    @Test("A held supervisor read parks the write turn until it is released")
    func aHeldReadParksTheWriteTurn() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)
        await firmware.holdReads()

        let read = observing { try await scheduler.read(keys: ["F0Md"], at: .supervisor) }
        await yieldUntil("the read to hold its turn") { await firmware.readsParked == 1 }

        let turn = observing {
            try await scheduler.withWriteTurn { try await runsOneWriteJob(on: firmware) }
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

    /// **Mutation:** take no turn in `withWriteTurn`. Run: red — the read runs inside the held
    /// write turn.
    @Test("A held write turn parks a supervisor read until it ends")
    func aHeldWriteTurnParksARead() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)
        let hold = TurnHold()

        let turn = observing { await scheduler.withWriteTurn { await hold.park() } }
        await yieldUntil("the write turn to hold its turn") { await hold.isParked }

        let began = FirmwareLog.Entry.providerReadBegan(["F0Md"])
        let read = observing { try await scheduler.read(keys: ["F0Md"], at: .supervisor) }
        await yieldUntil("the read to queue behind the write turn, or to barge in") {
            let queued = await scheduler.queuedTurns(at: .supervisor) == 1
            return queued || firmware.log.entries.contains(began)
        }
        #expect(
            !firmware.log.entries.contains(began),
            "a supervisor read ran inside a held write turn")

        await hold.release()
        _ = try await finished("the write turn", turn)
        _ = try await finished("the read", read)
    }
}

/// A write turn's job as the plane's will be, on the channel's own actor with no suspension inside:
/// fresh key info, the raw read, and the write. `private`, so no other file — and no file that can
/// open a real connection — can hand it one.
private func runsOneWriteJob(on channel: isolated any SMCWriteChannel) throws -> SMCKeyInfo {
    let info = try channel.freshKeyInfo(for: SMCKey.forceTest)
    _ = try channel.read(SMCKey.forceTest)
    try channel.write([0x01], to: SMCKey.forceTest)
    return info
}

/// A body that holds its turn until released: a continuation, so the hold suspends.
private actor TurnHold {
    private var parked: CheckedContinuation<Void, Never>?
    private var released = false

    var isParked: Bool { parked != nil }

    func park() async {
        guard !released else { return }
        await withCheckedContinuation { parked = $0 }
    }

    func release() {
        released = true
        parked?.resume()
        parked = nil
    }
}
