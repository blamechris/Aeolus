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
        let connection = SMCConnection()
        let monitor = connection.roundTrips

        let beforeOpen = monitor.issuedCount
        try await connection.open()
        #expect(monitor.issuedCount == beforeOpen + 1, "open() is one stamped round trip")
        #expect(monitor.inFlight() == nil)

        // Cold: nothing about these keys is cached, so each costs READ_KEYINFO + READ_BYTES.
        var mark = monitor.issuedCount
        let cold = await connection.read(keys: keys)
        try Self.requireEveryKeyRead(cold)
        #expect(monitor.issuedCount - mark == UInt64(2 * keys.count), "cold: 2 per key")
        #expect(monitor.inFlight() == nil, "nothing is left in flight after a read")

        // Warm: metadata is cached, so each costs the READ_BYTES alone. Values are never
        // cached, so this is a real round trip per key and not zero.
        mark = monitor.issuedCount
        let warm = await connection.read(keys: keys)
        try Self.requireEveryKeyRead(warm)
        #expect(monitor.issuedCount - mark == UInt64(keys.count), "warm: 1 per key")
        #expect(monitor.inFlight() == nil)

        // Cold again after the explicit escape hatch, so the 2N above was the cache and not
        // the order the test happened to run in.
        await connection.invalidate()
        mark = monitor.issuedCount
        let rediscovered = await connection.read(keys: keys)
        try Self.requireEveryKeyRead(rediscovered)
        #expect(
            monitor.issuedCount - mark == UInt64(2 * keys.count), "after invalidate(): 2 per key")

        mark = monitor.issuedCount
        await connection.close()
        #expect(monitor.issuedCount == mark + 1, "close() is one stamped round trip")
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
