import SMCCore
import Testing

/// Assertions that are facts about *this* machine rather than about "a Mac with an SMC" —
/// see `DevelopmentMachine.swift` for why they skip rather than fail elsewhere.
@Suite(
    "SMC fan enumeration, Mac16,5-specific facts",
    .enabled(if: SMCConnection.isHardwareAvailable() && isDevelopmentMachine())
)
struct SMCFanEnumerationMac165Tests {

    @Test("Enumeration finds this machine's two fans against the real SMC")
    func enumeratesRealFans() async throws {
        let enumeration = try await SMCFanEnumeration.enumerate(provider: SMCSensorProvider())

        #expect(enumeration.fanCount == 2)
        #expect(enumeration.enumeratedFanIndices == [0, 1])

        for fan in enumeration.fans {
            let actual = try #require(value(fan.actual), "F\(fan.index)Ac did not read")
            // docs/RECOVERY.md: 0 RPM is normal on many Macs when cool or idle, and F0Ac has
            // been observed below the declared F0Mn floor on this very machine. The only
            // things worth asserting about an observation are that it is finite and not
            // negative — never that it respects a bound the firmware itself does not.
            #expect(actual.isFinite)
            #expect(actual >= 0)
        }
    }
}
