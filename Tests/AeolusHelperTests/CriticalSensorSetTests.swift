import FanKit
import SMCCore
import Testing

@testable import AeolusHelper

/// The curated critical-temperature set, the plausibility gate, and the conformer that
/// composes them.
///
/// Several assertions below hard-code figures measured on `Mac16,5` on 2026-08-20 and
/// recorded in `docs/SMC-RESEARCH.md`. That is deliberate: the point of this set is that
/// somebody measured this machine, and a test that only checked structural properties
/// would stay green while the set drifted into the very shape the measurement rules out.
@Suite("Critical sensor set")
struct CriticalSensorSetTests {

    // MARK: - Resolution

    @Test("Mac16,5 resolves to the measured die cluster")
    func mac16x5ResolvesToTheDieCluster() {
        let set = CriticalSensorSet.resolve(
            for: HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max"))

        #expect(set.keys.count == 34)
        #expect(
            set.keys.allSatisfy {
                $0.rawValue.hasPrefix("TPD") || $0.rawValue.hasPrefix("TRD")
            })
        #expect(Set(set.keys).count == 34, "the curated list contains a duplicate")
    }

    /// The whole reason this type exists. `docs/SMC-RESEARCH.md` records two ways the
    /// obvious implementations break § 3, and this test asserts neither of them is what
    /// shipped.
    @Test("The set is not every T key, and excludes the two classes that break § 3")
    func theSetExcludesTheKeysThatWouldBreakTheOverride() {
        let keys = Set(CriticalSensorSet.mac16x5.keys.map(\.rawValue))

        // 368 numeric T* keys were enumerated on this machine. A curated set is a handful.
        #expect(keys.count < 40)

        // Frozen constants: Tf06 reads 98.484375 °C idle and under a twelve-way load
        // alike, above § 3's 95 °C ceiling. Including one latches the emergency forever.
        #expect(!keys.contains("Tf06"))
        #expect(!keys.contains("Tf46"))

        // Per-core sensors: the Tp0* cluster runs 95.69–111.14 °C during an ordinary
        // `swift build` while the system's own thermal management sits relaxed at
        // 2372 RPM. Including one fires the emergency every time somebody compiles.
        #expect(keys.allSatisfy { !$0.hasPrefix("Tp0") })
    }

    @Test("A machine nobody has measured resolves to the empty set")
    func unmeasuredHardwareResolvesToEmpty() {
        let intel = CriticalSensorSet.resolve(
            for: HardwareIdentity(modelIdentifier: "MacBookPro16,1", chipFamily: nil))
        #expect(intel.isEmpty)

        let futureSilicon = CriticalSensorSet.resolve(
            for: HardwareIdentity(modelIdentifier: "Mac99,9", chipFamily: "M9 Ultra"))
        #expect(futureSilicon.isEmpty)
    }

    /// An unreadable `hw.model` must not fall through to another machine's key list.
    @Test("An unidentifiable machine resolves to the empty set, never to a guess")
    func unidentifiableHardwareResolvesToEmpty() {
        let set = CriticalSensorSet.resolve(
            for: HardwareIdentity(modelIdentifier: nil, chipFamily: "M4 Max"))
        #expect(set.isEmpty)
    }

    // MARK: - The plausibility gate

    @Test("A reading at or below zero is not believed")
    func nonPositiveReadingsAreRejected() throws {
        // Tpx0 reads exactly 0.00 while its cluster is powered down — a clean constant,
        // not a read failure, and indistinguishable from a temperature to the read path.
        let report = try CriticalTemperatureReport(
            readings: [
                CriticalTemperature(key: key("TPD0"), celsius: 0),
                CriticalTemperature(key: key("TPD1"), celsius: -5),
                CriticalTemperature(key: key("TPD2"), celsius: 44),
            ],
            unreadableKeys: []
        )

        let gated = try CriticalTemperaturePlausibility.gate(report)

        #expect(gated.readings.map(\.key.rawValue) == ["TPD2"])
        #expect(Set(gated.unreadableKeys.map(\.rawValue)) == ["TPD0", "TPD1"])
    }

    /// `docs/SAFETY.md` § 3 spells out the inverse of this trap — a NaN *ceiling* disables
    /// the override, because every comparison against NaN is false. This is the same
    /// hazard on the other operand, and the gate's `>` resolves it in the safe direction.
    @Test("A NaN reading is rejected rather than believed")
    func nanReadingsAreRejected() throws {
        let report = try CriticalTemperatureReport(
            readings: [
                CriticalTemperature(key: key("TPD0"), celsius: .nan),
                CriticalTemperature(key: key("TPD1"), celsius: 44),
            ],
            unreadableKeys: []
        )

        let gated = try CriticalTemperaturePlausibility.gate(report)

        #expect(gated.readings.map(\.key.rawValue) == ["TPD1"])
        #expect(gated.unreadableKeys.map(\.rawValue) == ["TPD0"])
    }

    /// The failure asymmetry, as a test. Over-firing returns fans to automatic — safe and
    /// noisy. Under-firing is the dangerous direction, so an upper bound that discarded a
    /// 200 °C reading would fail closed in the one direction § 3 must not.
    ///
    /// This is the test that goes red if somebody adds an upper bound "for symmetry".
    @Test("An implausibly high reading is believed, because under-firing is the danger")
    func highReadingsAreNotRejected() throws {
        let report = try CriticalTemperatureReport(
            readings: [CriticalTemperature(key: key("TPD0"), celsius: 200)],
            unreadableKeys: []
        )

        let gated = try CriticalTemperaturePlausibility.gate(report)

        #expect(gated.readings.count == 1)
        #expect(gated.readings[0].celsius == 200)
        #expect(gated.unreadableKeys.isEmpty)
    }

    @Test("Rejecting every reading is blindness, not a successful report of nothing")
    func rejectingEveryReadingIsBlindness() throws {
        let report = try CriticalTemperatureReport(
            readings: [
                CriticalTemperature(key: key("TPD0"), celsius: 0),
                CriticalTemperature(key: key("TPD1"), celsius: 0),
            ],
            unreadableKeys: []
        )

        #expect(throws: FanControlPlaneError.self) {
            try CriticalTemperaturePlausibility.gate(report)
        }
    }

    // MARK: - The conformer

    @Test("The conformer asks for exactly the curated keys")
    func theConformerAsksForTheCuratedKeys() async throws {
        let plane = ScriptedControlPlane(
            fans: [:],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let telemetry = CuratedCriticalTemperatures(plane: plane, set: .mac16x5)

        _ = try await telemetry.readCriticalTemperatures()

        let attempts = await plane.attempts
        #expect(attempts == [.readCriticalTemperatures(CriticalSensorSet.mac16x5.keys)])
    }

    /// The gate has to be on the path the helper actually uses, not merely available to
    /// it. Delete the `gate(_:)` call in `CuratedCriticalTemperatures` and this goes red
    /// while every other test in this file stays green.
    @Test("A plane answering a clean zero for every curated key reads as blindness")
    func aCleanZeroForEveryKeyIsBlindness() async throws {
        let allZero = Dictionary(
            uniqueKeysWithValues: CriticalSensorSet.mac16x5.keys.map { ($0.rawValue, 0.0) })
        let telemetry = CuratedCriticalTemperatures(
            plane: ScriptedControlPlane(fans: [:], stages: [.nominal(temperatures: allZero)]),
            set: .mac16x5)

        await #expect(throws: FanControlPlaneError.self) {
            _ = try await telemetry.readCriticalTemperatures()
        }
    }

    @Test("An empty curated set is blindness")
    func anEmptySetIsBlindness() async throws {
        let telemetry = CuratedCriticalTemperatures(
            plane: ScriptedControlPlane(fans: [:], stages: [.nominal()]),
            set: .unidentifiedHardware)

        await #expect(throws: FanControlPlaneError.self) {
            _ = try await telemetry.readCriticalTemperatures()
        }
    }

    @Test("A plane that answers nothing is blindness")
    func aBlindPlaneIsBlindness() async throws {
        let telemetry = CuratedCriticalTemperatures(
            plane: ScriptedControlPlane(fans: [:], stages: [.blind()]),
            set: .mac16x5)

        await #expect(throws: FanControlPlaneError.self) {
            _ = try await telemetry.readCriticalTemperatures()
        }
    }

    /// Five of six critical sensors is a degraded cycle worth logging, and it is not
    /// blindness. A gate that treated partial loss as total would refuse leases on a
    /// machine that can see perfectly well.
    @Test("Partial loss is a degraded reading, not blindness")
    func partialLossIsNotBlindness() async throws {
        var temperatures = LeaseFixture.nominalDieTemperatures
        for dropped in CriticalSensorSet.mac16x5.keys.dropFirst(2) {
            temperatures[dropped.rawValue] = nil
        }
        let telemetry = CuratedCriticalTemperatures(
            plane: ScriptedControlPlane(fans: [:], stages: [.nominal(temperatures: temperatures)]),
            set: .mac16x5)

        let report = try await telemetry.readCriticalTemperatures()

        #expect(report.readings.count == 2)
        #expect(report.unreadableKeys.count == 32)
    }

    private func key(_ raw: String) -> SMCKey { smcKey(raw) }
}
