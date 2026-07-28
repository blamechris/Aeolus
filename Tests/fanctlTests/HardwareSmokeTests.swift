import Testing

@testable import SMCCore
@testable import fanctl

/// End-to-end sanity against the real SMC. Gated on `isDevelopmentMachine()`, not just
/// `SMCConnection.isHardwareAvailable()`: `list`'s fan-count assertion below is a fact
/// about *this* machine (`Mac16,5` has at least one fan), not "any Mac with an SMC" — a
/// fanless MacBook Air would fail it honestly, not because anything is broken. Same split
/// `Tests/SMCCoreTests/DevelopmentMachine.swift` documents.
@Suite(
    "fanctl — real hardware",
    .enabled(if: SMCConnection.isHardwareAvailable() && isDevelopmentMachine())
)
struct HardwareSmokeTests {

    @Test("list reads real fans with no helper and no privileges")
    func listReadsRealFans() async throws {
        let result = try await ListCommand.fetch(provider: SMCSensorProvider())

        #expect(result.fanCount > 0)
        #expect(result.fans.count == result.fanCount)
        for fan in result.fans {
            // Never asserts a floor on the value itself — see
            // SMCSensorProviderTests.swift's note on why 0 RPM is a normal observation,
            // not something to reject. Only that the outcome is representable at all.
            #expect(fan.actual.value != nil || fan.actual.error != nil)
        }

        // Renders without throwing in both formats — the actual shape is exercised by
        // ListCommandRenderTests against fixed fixtures; this only proves real firmware
        // data round-trips through both renderers without crashing.
        _ = try ListCommand.renderJSON(result)
        _ = ListCommand.renderTable(result)
    }

    @Test("sensors enumerates real keys with no helper and no privileges")
    func sensorsEnumeratesRealKeys() async throws {
        let result = try await SensorsCommand.fetch(
            provider: SMCSensorProvider(), catalog: NoSensorCatalog(), rawKeys: false)

        #expect(!result.entries.isEmpty)
        for entry in result.entries {
            #expect(entry.key.count == 4)
            // No catalog wired in: every entry must render unlabelled, not degraded.
            #expect(entry.label == nil)
            #expect(entry.confidence == nil)
        }

        _ = try SensorsCommand.renderJSON(result)
        _ = SensorsCommand.renderTable(result)
    }
}
