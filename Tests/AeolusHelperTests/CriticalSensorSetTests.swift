import FanKit
import Foundation
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

        // Per-core sensors: under a twelve-way busy loop, 27 of the 45 Tp0* keys go above
        // 95 °C (the cluster spans 74.43–111.14 °C) while the system's own thermal
        // management sits relaxed at 2372 RPM against a 5777 RPM maximum. Including one
        // fires the emergency under any sustained multi-core work.
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

    /// The plane here answers **every** curated key with a healthy temperature, so the only
    /// thing that can produce blindness is the set being empty.
    ///
    /// An earlier version built its plane with `.nominal()`, whose `temperatures` dictionary
    /// defaults to empty — so the double answered nothing for any key and the test passed
    /// for the same reason `aBlindPlaneIsBlindness` does, whether or not the empty-set rule
    /// held. The review demonstrated it: giving an empty set a fallback to
    /// `CriticalSensorSet.mac16x5.keys` left all 809 tests green, which in production would
    /// silently read Mac16,5's keys on an Intel Mac nobody has measured.
    @Test("An empty curated set is blindness, even when the machine would answer")
    func anEmptySetIsBlindness() async throws {
        let plane = ScriptedControlPlane(
            fans: [:],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let telemetry = CuratedCriticalTemperatures(plane: plane, set: .unidentifiedHardware)

        await #expect(throws: FanControlPlaneError.self) {
            _ = try await telemetry.readCriticalTemperatures()
        }
        // And it asked for nothing, rather than asking for somebody else's keys.
        #expect(await plane.attempts == [.readCriticalTemperatures([])])
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

    /// Count, prefix and uniqueness do not pin a key list.
    ///
    /// Every other test here derives both its fixture temperatures and its expectations from
    /// `CriticalSensorSet.mac16x5.keys`, so they stay self-consistent under any change to it.
    /// Change the suffix literal `"f"` to `"g"` and the set silently loses `TPDf`/`TRDf` and
    /// gains two keys this firmware does not expose — `known(_:)` accepts them, the count
    /// stays 34, the prefixes still match, and the suite stays green while the critical set
    /// drifts off the hardware it was measured on. This is the only test that says which
    /// keys, and it is a transcript of the 2026-08-20 enumeration.
    @Test("The 34 curated keys are exactly the ones enumerated on this machine")
    func theCuratedKeysArePinnedByName() {
        let expected: Set<String> = [
            "TPD0", "TPD1", "TPD2", "TPD3", "TPD4", "TPD5", "TPD6", "TPD7", "TPD8", "TPD9",
            "TPDa", "TPDb", "TPDc", "TPDd", "TPDe", "TPDf", "TPDX",
            "TRD0", "TRD1", "TRD2", "TRD3", "TRD4", "TRD5", "TRD6", "TRD7", "TRD8", "TRD9",
            "TRDa", "TRDb", "TRDc", "TRDd", "TRDe", "TRDf", "TRDX",
        ]
        #expect(Set(CriticalSensorSet.mac16x5.keys.map(\.rawValue)) == expected)
    }

    /// `CriticalSensorSet`'s justification for compiling in a fixed key list is that a key
    /// this firmware does not expose lands in `unreadableKeys` and produces "a degraded
    /// **logged** cycle rather than blindness". A review found that sentence true of nothing:
    /// `unreadableKeys` had no reader anywhere in `Sources/`, so 33 of 34 keys could fall
    /// silent with a lease still granted and no line in the log.
    ///
    /// Delete the `log.degradedCycle(...)` call in `CuratedCriticalTemperatures` and this
    /// goes red.
    @Test("A degraded cycle is logged, naming how many keys answered")
    func aDegradedCycleIsLogged() async throws {
        let recorder = RecordedLog()
        var temperatures = LeaseFixture.nominalDieTemperatures
        for dropped in CriticalSensorSet.mac16x5.keys.dropFirst(2) {
            temperatures[dropped.rawValue] = nil
        }
        let telemetry = CuratedCriticalTemperatures(
            plane: ScriptedControlPlane(fans: [:], stages: [.nominal(temperatures: temperatures)]),
            set: .mac16x5,
            log: SafetyLog(recording: { recorder.append($0) }))

        _ = try await telemetry.readCriticalTemperatures()

        let lines = recorder.lines
        #expect(lines.count == 1)
        #expect(lines.first?.contains("2 of 34") == true)
    }

    /// A healthy cycle says nothing. A log that fires every time is a log nobody reads, and
    /// it would make the degraded line above worthless as a signal.
    @Test("A cycle where every key answers logs nothing")
    func aHealthyCycleIsSilent() async throws {
        let recorder = RecordedLog()
        let telemetry = CuratedCriticalTemperatures(
            plane: ScriptedControlPlane(
                fans: [:], stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)]),
            set: .mac16x5,
            log: SafetyLog(recording: { recorder.append($0) }))

        _ = try await telemetry.readCriticalTemperatures()

        #expect(recorder.lines.isEmpty)
    }

    private func key(_ raw: String) -> SMCKey { smcKey(raw) }
}

/// A `SafetyLog` sink a test can read back. `NSLock` rather than an actor so an assertion
/// can read it without an `await`, matching `TestClock` in `LeaseTestDoubles.swift`.
final class RecordedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ line: String) { lock.withLock { recorded.append(line) } }
    var lines: [String] { lock.withLock { recorded } }
}
