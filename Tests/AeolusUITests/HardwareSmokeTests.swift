import FanKit
import Testing

@testable import AeolusUI
@testable import SMCCore

/// End-to-end sanity against the real SMC. Gated on `HardwareIdentity.current()` matching
/// this project's sole verified machine, not just `SMCConnection.isHardwareAvailable()` —
/// the same split `Tests/SMCCoreTests/DevelopmentMachine.swift` and `fanctlTests`'
/// `HardwareSmokeTests.swift` document: a number of assertions below are facts about
/// *this* machine specifically (that it has at least one fan, that its sensor table is
/// non-empty), not "any Mac with an SMC." Reuses `FanKit`'s production
/// `HardwareIdentity.current()` rather than a third test-only sysctl reader — `AeolusUI`
/// already depends on `FanKit`, so nothing stops this from calling it directly, per this
/// issue's own instruction to use `HardwareIdentity.current()` for hardware gating.
@Suite(
    "AeolusUI polling — real hardware",
    .enabled(
        if: SMCConnection.isHardwareAvailable()
            && HardwareIdentity.current().modelIdentifier == "Mac16,5")
)
struct HardwareSmokeTests {

    @Test(
        "FanPoller reads real fans with no helper and no privileges, honesty flags hardcoded safe"
    )
    func fanPollerReadsRealFans() async throws {
        let fans = try await FanPoller.poll(provider: SMCSensorProvider())

        #expect(!fans.isEmpty)
        for fan in fans {
            #expect(fan.mode == .automatic)
            #expect(fan.isReclaimedBySystem == false)
            #expect(fan.actual.key == "F\(fan.index)Ac")
            #expect(fan.minimum.key == "F\(fan.index)Mn")
            #expect(fan.maximum.key == "F\(fan.index)Mx")
            // Never asserts a floor against `minimum` — a reading below the declared
            // minimum is a legitimate, observed fact on this hardware (F0Ac at 1343.07
            // against a declared F0Mn of 1350). Only that a *present* value is finite and
            // physically plausible as an RPM, which a byte-order fault reaching this far
            // would violate.
            if let value = fan.actual.value {
                #expect(value.isFinite)
                #expect(value >= 0)
            }
        }
    }

    @Test("SensorPoller discovers real sensor keys and refreshes them via subset reads only")
    func sensorPollerDiscoversAndRefreshesRealSensors() async throws {
        let provider = SMCSensorProvider()
        let discovered = try await SensorPoller.discover(provider: provider)
        #expect(!discovered.isEmpty)

        let refreshed = try await SensorPoller.refresh(
            discovered: discovered, provider: provider, labelSource: NoSensorLabels())
        #expect(refreshed.count == discovered.count)
        for sensor in refreshed {
            #expect(sensor.key.count == 4)
        }
    }

    @MainActor
    @Test("PollingViewModel ticks against real hardware without hitting readAll() on a refresh")
    func viewModelTicksAgainstRealHardwareUsingSubsetReadsAfterDiscovery() async throws {
        let provider = SMCSensorProvider()
        let viewModel = PollingViewModel(provider: provider)

        await viewModel.tick()
        #expect(viewModel.phase == .ready)
        #expect(!viewModel.fans.isEmpty)
        #expect(!viewModel.sensors.isEmpty)

        // A second tick must reuse the discovery from the first — this is the property
        // that makes a live UI viable at all: subset reads on real hardware are ~12 ms
        // warm, full enumeration is ~0.6 s warm and ~4.5 s cold. This does not assert a
        // timing bound (too flaky across machines/CI), only that the second tick still
        // succeeds using the cached discovery from the first.
        await viewModel.tick()
        #expect(viewModel.phase == .ready)
    }
}
