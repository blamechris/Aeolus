import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// The mechanism `AeolusHelperMain`'s `DaemonWriteChannel` rests on, on a stand-in written the same
/// way (ADR 0014's B1 seam amendment).
///
/// No test can construct the daemon's forwarder: it is `private` to `main`'s file, which is the
/// point. So its mechanism is tested here, on `SharingChannel` — the forwarder's text, member for
/// member, over `InnerConnection` instead of `SMCConnection`. It adopts the inner actor's executor
/// and forwards each requirement through `assumeIsolated`. Many write turns run interleaved with
/// direct calls on the inner actor, and every operation records itself into one ledger that would
/// see two of them at once if the executor were not shared.
///
/// It runs in debug and, under CI's release step, at `-O`.
///
/// **The mutation is a recorded manual one, not a test.** Deleting `unownedExecutor` from the
/// forwarder makes the first `assumeIsolated` trap ("Incorrect actor executor assumption"), which
/// ends the test process; a suite cannot assert it. It was run by hand on this stand-in.
@Suite("A forwarder that adopts its connection's executor", .timeLimit(.minutes(1)))
struct ExecutorSharingTests {

    static let turns = 100

    @available(macOS 14, *)
    @Test("Write turns through a sharing forwarder never overlap the connection's own calls")
    func writeTurnsShareTheInnerExecutor() async throws {
        let ledger = SharingLedger()
        let inner = InnerConnection(ledger: ledger)
        let channel = SharingChannel(over: inner)
        let scheduler = SMCReadScheduler(provider: FirmwareSMC.mac16x5().provider)
        let key = SMCKey.forceTest

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.turns {
                group.addTask {
                    try await scheduler.withWriteTurn(on: channel) { channel in
                        _ = try channel.freshKeyInfo(for: key)
                        try channel.write([0x01], to: key)
                        try channel.write([0x00], to: key)
                    }
                }
                group.addTask { _ = try await inner.read(key) }
            }
            try await group.waitForAll()
        }

        let seen = ledger.reading
        #expect(seen.writes == 2 * Self.turns, "not every write turn's job ran: \(seen)")
        #expect(seen.reads == Self.turns, "not every direct read ran: \(seen)")
        #expect(seen.keyInfos == Self.turns)
        #expect(
            seen.mostAtOnce == 1,
            "two operations ran on the connection at once: the executor is not shared — \(seen)")
    }
}

/// What every operation on `InnerConnection` records: how many of each kind ran, and the most that
/// were ever in flight together.
final class SharingLedger: Sendable {
    struct Reading: Sendable, CustomStringConvertible {
        var writes = 0
        var reads = 0
        var keyInfos = 0
        var inFlight = 0
        var mostAtOnce = 0
        var description: String {
            "writes \(writes), reads \(reads), key infos \(keyInfos), most at once \(mostAtOnce)"
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: Reading())

    var reading: Reading { state.withLock { $0 } }

    enum Kind: Sendable { case write, read, keyInfo }

    /// Runs one operation, counted, with a short spin inside so two that overlapped would be seen.
    func operation(_ kind: Kind) {
        state.withLock {
            switch kind {
            case .write: $0.writes += 1
            case .read: $0.reads += 1
            case .keyInfo: $0.keyInfos += 1
            }
            $0.inFlight += 1
            $0.mostAtOnce = max($0.mostAtOnce, $0.inFlight)
        }
        var spin = 0
        for step in 0..<500 { spin &+= step }
        _ = spin
        state.withLock { $0.inFlight -= 1 }
    }
}

/// `SMCConnection`'s four channel members, recording into a ledger and touching nothing.
actor InnerConnection {
    private let ledger: SharingLedger

    init(ledger: SharingLedger) { self.ledger = ledger }

    var interfaceGeneration: SMCInterfaceGeneration? { .modern }

    func freshKeyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        ledger.operation(.keyInfo)
        return SMCKeyInfo(key: key, type: .ui8, dataSize: 1, attributes: 0xD0)
    }

    func read(_ key: SMCKey) throws -> SMCValue {
        ledger.operation(.read)
        return SMCValue(key: key, type: .ui8, bytes: [0x00])
    }

    func write(_ bytes: [UInt8], to key: SMCKey) throws {
        ledger.operation(.write)
    }
}

/// `DaemonWriteChannel`, written the same way, over `InnerConnection`.
@available(macOS 14, *)
private actor SharingChannel: SMCWriteChannel {
    private let connection: InnerConnection
    init(over connection: InnerConnection) { self.connection = connection }
    nonisolated var unownedExecutor: UnownedSerialExecutor { connection.unownedExecutor }
    var interfaceGeneration: SMCInterfaceGeneration? {
        connection.assumeIsolated { $0.interfaceGeneration }
    }
    func freshKeyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        try connection.assumeIsolated { try $0.freshKeyInfo(for: key) }
    }
    func read(_ key: SMCKey) throws -> SMCValue {
        try connection.assumeIsolated { try $0.read(key) }
    }
    func write(_ bytes: [UInt8], to key: SMCKey) throws {
        try connection.assumeIsolated { try $0.write(bytes, to: key) }
    }
}
