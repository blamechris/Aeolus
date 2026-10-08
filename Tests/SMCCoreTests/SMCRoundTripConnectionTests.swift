import Testing

@testable import SMCCore

/// What `SMCConnection` does with its `roundTrips` monitor that needs no hardware: a call the
/// connection refuses before it reaches IOKit was never a round trip, and so was never
/// stamped. The watchdog counts a sequence number as "a call went out", so a stamp taken ahead
/// of the guard would put a call in flight that the kernel never saw.
@Suite("SMC connection, round trips counted", .timeLimit(.minutes(1)))
struct SMCConnectionRoundTripCountTests {

    @Test("A read on a connection that was never opened issues no round trip")
    func aRefusedCallIsNotARoundTrip() async throws {
        let connection = SMCConnection()
        let key = try #require(SMCKey("F0Ac"))

        await #expect(throws: SMCError.self) {
            _ = try await connection.read(key)
        }
        await #expect(throws: SMCError.self) {
            _ = try await connection.key(at: 0)
        }

        #expect(connection.roundTrips.issuedCount == 0)
        #expect(connection.roundTrips.inFlight() == nil)
    }

    @Test("close() on a connection that was never opened issues no round trip")
    func closingNothingIsNotARoundTrip() async {
        let connection = SMCConnection()
        await connection.close()
        #expect(connection.roundTrips.issuedCount == 0)
    }

    @Test("A connection built around a given monitor stamps on that monitor")
    func theInjectedMonitorIsTheOneStamped() async {
        let monitor = SMCRoundTripMonitor()
        let connection = SMCConnection(roundTrips: monitor)
        #expect(connection.roundTrips === monitor)
    }

    @Test("Each connection gets a monitor of its own")
    func connectionsDoNotShareAMonitor() {
        // One slot per monitor is only sound because one actor produces one call at a time. Two
        // connections sharing a monitor would overwrite each other's stamp and hide a wedge.
        #expect(SMCConnection().roundTrips !== SMCConnection().roundTrips)
    }

    /// The stamp is what a verdict will name, so it has to name the call that was made. This
    /// needs no SMC: the connection is given a handle that is not a send right to anything
    /// (`adoptUnusableHandleForTesting`), so each call gets past the not-open guard, is
    /// stamped, and fails at once inside IOKit — which is all this asserts about. Nothing is
    /// read and nothing can be written.
    @Test("Each call stamps its own key and selector, not merely that a call was made")
    func aCallStampsTheKeyAndSelectorItSends() async throws {
        let connection = SMCConnection()
        let monitor = connection.roundTrips
        let key = try #require(SMCKey("F0Ac"))
        await connection.adoptUnusableHandleForTesting()

        // READ_KEYINFO: the key's own wire code, selector 9.
        _ = try? await connection.keyInfo(for: key)
        #expect(monitor.lastBegunOperation == .call(key: key.fourCharCode, selector: 9))

        // READ_BYTES, once the metadata is cached: the same key, selector 5.
        await connection.seedKeyInfoCacheForTesting(
            SMCKeyInfo(key: key, type: .flt, dataSize: 4, attributes: 0x80))
        _ = try? await connection.read(key)
        #expect(monitor.lastBegunOperation == .call(key: key.fourCharCode, selector: 5))

        // READ_INDEX: no key at all (0), selector 8.
        _ = try? await connection.key(at: 3)
        #expect(monitor.lastBegunOperation == .call(key: 0, selector: 8))

        #expect(monitor.issuedCount == 3, "three calls, each stamped once")
        #expect(monitor.inFlight() == nil, "and none left in flight")

        await connection.close()
        #expect(monitor.lastBegunOperation == .close)
        #expect(monitor.issuedCount == 4)
    }
}

/// The stamp against the real SMC. These are facts about this development machine, not about
/// "a Mac with an SMC", for the reason `DevelopmentMachine.swift` gives; they skip, and do not
/// fail, anywhere else — CI's virtual machines included, which have no SMC at all.
///
/// Read-only throughout: `open()` and `read(keys:)`. Nothing here can write.
@Suite(
    "SMC round-trip stamp, Mac16,5",
    .enabled(if: SMCConnection.isHardwareAvailable() && isDevelopmentMachine()),
    .timeLimit(.minutes(1))
)
struct SMCRoundTripHardwareTests {

    /// Fan 0 and fan 1's actual, minimum and maximum RPM: six plain `flt` keys that read on
    /// this machine (see `SMCFanEnumerationMac165Tests`).
    private static let fanKeys = ["F0Ac", "F0Mn", "F0Mx", "F1Ac", "F1Mn", "F1Mx"]

    @Test("A warm read issues one round trip per key, a cold one two, and none is left in flight")
    func roundTripsAreCountedOnePerIOKitCall() async throws {
        let keys = try Self.fanKeys.map { try #require(SMCKey($0)) }
        let first = try #require(keys.first)
        let last = try #require(keys.last)
        let connection = SMCConnection()
        let monitor = connection.roundTrips

        let beforeOpen = monitor.issuedCount
        try await connection.open()
        #expect(monitor.issuedCount == beforeOpen + 1, "open() is one stamped round trip")
        #expect(monitor.lastBegunOperation == .open)
        #expect(monitor.inFlight() == nil)

        // Cold: nothing about these keys is cached, so each costs READ_KEYINFO + READ_BYTES.
        var mark = monitor.issuedCount
        let cold = await connection.read(keys: keys)
        try Self.requireEveryKeyRead(cold)
        #expect(monitor.issuedCount - mark == UInt64(2 * keys.count), "cold: 2 per key")
        #expect(monitor.inFlight() == nil, "nothing is left in flight after a read")

        // Warm: metadata is cached, so each costs the READ_BYTES alone. Values are never
        // cached, so this is a real round trip per key and not zero. The stamp names the call
        // that went out: the last key read, selector 5 (READ_BYTES).
        mark = monitor.issuedCount
        let warm = await connection.read(keys: keys)
        try Self.requireEveryKeyRead(warm)
        #expect(monitor.issuedCount - mark == UInt64(keys.count), "warm: 1 per key")
        #expect(monitor.lastBegunOperation == .call(key: last.fourCharCode, selector: 5))
        #expect(monitor.inFlight() == nil)

        // Cold again after the explicit escape hatch, so the 2N above was the cache and not
        // the order the test happened to run in.
        await connection.invalidate()
        mark = monitor.issuedCount
        let rediscovered = await connection.read(keys: keys)
        try Self.requireEveryKeyRead(rediscovered)
        #expect(
            monitor.issuedCount - mark == UInt64(2 * keys.count), "after invalidate(): 2 per key")

        // Each selector stamps its own key: READ_KEYINFO (9) on the key, READ_INDEX (8) on key
        // 0, READ_BYTES (5) on the key again once its metadata is cached.
        await connection.invalidate()
        _ = try await connection.keyInfo(for: first)
        #expect(monitor.lastBegunOperation == .call(key: first.fourCharCode, selector: 9))
        _ = try await connection.key(at: 0)
        #expect(monitor.lastBegunOperation == .call(key: 0, selector: 8))
        _ = try await connection.read(first)
        #expect(monitor.lastBegunOperation == .call(key: first.fourCharCode, selector: 5))

        mark = monitor.issuedCount
        await connection.close()
        #expect(monitor.issuedCount == mark + 1, "close() is one stamped round trip")
        #expect(monitor.lastBegunOperation == .close)
        #expect(monitor.inFlight() == nil)
    }

    private static func requireEveryKeyRead(_ outcomes: [SMCKeyReadOutcome]) throws {
        for outcome in outcomes {
            guard case .success = outcome.result else {
                Issue.record("\(outcome.key) did not read: \(outcome.result)")
                throw ReadFailed()
            }
        }
    }

    private struct ReadFailed: Error {}
}
