import Testing

@testable import power_observer

/// Pins every name this tool knows against the raw `IOMessage`/`IOPMLib` value it names.
/// Mirrors `Tests/AeolusHelperTests/SystemPowerTests.theMessageNumbersAreTheOnesIOKitSends`,
/// widened to the five names `PowerMessageName` carries rather than the helper's two.
@Suite("PowerMessageName")
struct PowerMessageNameTests {

    @Test("the base is sys_iokit | sub_iokit_common")
    func theBaseIsTheIOKitCommonSubsystem() {
        #expect(PowerMessage.base == 0xE000_0000)
    }

    @Test("kIOMessageCanSystemSleep is named and pinned")
    func canSystemSleepIsNamedAndPinned() {
        #expect(PowerMessage.canSystemSleep == 0xE000_0270)
        #expect(
            PowerMessageName.name(for: PowerMessage.canSystemSleep) == "kIOMessageCanSystemSleep")
    }

    @Test("kIOMessageSystemWillSleep is named and pinned, and named separately from CanSystemSleep")
    func systemWillSleepIsNamedAndPinned() {
        #expect(PowerMessage.systemWillSleep == 0xE000_0280)
        #expect(
            PowerMessageName.name(for: PowerMessage.systemWillSleep) == "kIOMessageSystemWillSleep")
        #expect(
            PowerMessageName.name(for: PowerMessage.systemWillSleep)
                != PowerMessageName.name(for: PowerMessage.canSystemSleep))
    }

    @Test("kIOMessageSystemWillNotSleep is named and pinned")
    func systemWillNotSleepIsNamedAndPinned() {
        #expect(PowerMessage.systemWillNotSleep == 0xE000_0290)
        #expect(
            PowerMessageName.name(for: PowerMessage.systemWillNotSleep)
                == "kIOMessageSystemWillNotSleep")
    }

    @Test("kIOMessageSystemWillPowerOn is named and pinned")
    func systemWillPowerOnIsNamedAndPinned() {
        #expect(PowerMessage.systemWillPowerOn == 0xE000_0320)
        #expect(
            PowerMessageName.name(for: PowerMessage.systemWillPowerOn)
                == "kIOMessageSystemWillPowerOn")
    }

    @Test("kIOMessageSystemHasPoweredOn is named and pinned")
    func systemHasPoweredOnIsNamedAndPinned() {
        #expect(PowerMessage.systemHasPoweredOn == 0xE000_0300)
        #expect(
            PowerMessageName.name(for: PowerMessage.systemHasPoweredOn)
                == "kIOMessageSystemHasPoweredOn")
    }

    @Test("an undocumented message type names unknown rather than guessing")
    func anUndocumentedMessageTypeIsUnknown() {
        #expect(PowerMessageName.name(for: 0xDEAD_BEEF) == "unknown")
    }
}
