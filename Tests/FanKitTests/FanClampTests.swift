import Foundation
import Testing

@testable import FanKit

@Suite("Hardware clamping")
struct FanClampTests {
    let fan = Fan(index: 0, minimumRPM: 1200, maximumRPM: 5400)

    @Test("A request below the firmware minimum is raised to it")
    func clampsBelowMinimum() {
        #expect(fan.clamp(400) == 1200)
    }

    @Test("A request above the firmware maximum is lowered to it")
    func clampsAboveMaximum() {
        #expect(fan.clamp(9000) == 5400)
    }

    /// Stopping a fan outright must not be reachable, whatever the caller asks for.
    @Test("Zero and negative requests never reach the hardware")
    func neverAllowsZero() {
        #expect(fan.clamp(0) == 1200)
        #expect(fan.clamp(-500) == 1200)
    }
}

@Suite("Thermal ceilings")
struct ThermalCeilingTests {

    @Test("A configuration may lower a ceiling")
    func allowsLowering() {
        let effective = ThermalCeiling.effective(requested: 85, default: ThermalCeiling.cpuCelsius)
        #expect(effective == 85)
    }

    /// The whole point of a limit no user can defeat is that no user can defeat it.
    @Test("A configuration may not raise a ceiling")
    func rejectsRaising() {
        let effective = ThermalCeiling.effective(requested: 105, default: ThermalCeiling.cpuCelsius)
        #expect(effective == ThermalCeiling.cpuCelsius)
    }
}

@Suite("Lease expiry")
struct LeaseTests {

    @Test("A lease is live before its expiry and dead after it")
    func expiresOnSchedule() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let lease = Lease(
            holderDescription: "test",
            expiresAt: start.addingTimeInterval(30)
        )

        #expect(lease.isExpired(at: start) == false)
        #expect(lease.isExpired(at: start.addingTimeInterval(29)) == false)
        #expect(lease.isExpired(at: start.addingTimeInterval(30)) == true)
    }

    /// Two missed heartbeats must still leave room for a third attempt before control is
    /// surrendered, otherwise a single scheduling hiccup drops the fans to automatic.
    @Test("The default heartbeat allows for missed beats within the TTL")
    func heartbeatFitsWithinTTL() {
        #expect(Lease.defaultHeartbeatInterval * 3 <= Lease.defaultTimeToLive)
    }
}
