import Foundation
import Testing

@testable import FanKit

/// #96: a non-finite `Double` reaching `AeolusXPCCoding`'s bare `JSONEncoder` refuses the
/// **whole** snapshot, every tick, because `nonConformingFloatEncodingStrategy` is
/// `.throw`. `FanReading.init(from:)` already guards the decode path; nothing guarded
/// direct construction, and direct construction is exactly what a future producer (E5's
/// control loop, computing a target from curve arithmetic) does.
///
/// Every test here builds a `FanReading` or `FanState` the way a producer would — by
/// calling the type directly, never by decoding JSON — because decoding was already safe
/// and construction was the gap.
@Suite("FanReading refuses non-finite values at construction")
struct FanReadingConstructionTests {

    @Test(
        "A non-finite reading normalises to unavailable instead of being carried",
        arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteMeasuredBecomesUnavailable(_ nonFiniteValue: Double) {
        let reading = FanReading.measured(nonFiniteValue)

        #expect(reading.value == nil)
        guard case .unavailable(let reason) = reading else {
            Issue.record("expected .unavailable, got \(reading)")
            return
        }
        #expect(reason.isEmpty == false)
    }

    @Test("A finite reading is carried exactly, never adjusted")
    func finiteMeasuredIsCarriedExactly() {
        // 1343.07 below the declared minimum of 1350 on this project's development
        // hardware — a legitimate observation, not a value this guard may touch.
        #expect(FanReading.measured(1343.07).value == 1343.07)
        #expect(FanReading.measured(0).value == 0)
    }

    /// The defect this suite exists for: constructing `.measured` directly with a
    /// non-finite value used to succeed and hand back a case whose `.value` was NaN.
    /// Route `measured(_:)` back to a bare `case measuredFinite(nonFiniteValue)` (skip the
    /// `isFinite` guard) and this goes red.
    @Test("A snapshot with one non-finite field costs only that field, never the snapshot")
    func oneNonFiniteFieldNeverRefusesTheRestOfTheState() throws {
        let state = FanState(
            index: 0,
            firmwareName: "Left",
            actualRPM: .measured(.nan),
            minimumRPM: .measured(1350),
            maximumRPM: .measured(5777),
            targetRPM: nil,
            mode: .automatic,
            isReclaimedBySystem: false,
            manualControlAvailability: .unavailable(.writePathNotBuilt)
        )

        // Never carried as NaN, even transiently.
        #expect(state.actualRPM.value == nil)
        guard case .unavailable = state.actualRPM else {
            Issue.record("expected the poisoned field to be .unavailable")
            return
        }

        // The encoder AeolusXPCCoding actually uses is a bare JSONEncoder, whose
        // nonConformingFloatEncodingStrategy is .throw: this is the exact call that used
        // to refuse the whole snapshot.
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(FanState.self, from: data)

        // Every other field survived the round trip untouched.
        #expect(decoded.index == 0)
        #expect(decoded.firmwareName == "Left")
        #expect(decoded.minimumRPM.value == 1350)
        #expect(decoded.maximumRPM.value == 5777)
        #expect(decoded.targetRPM == nil)
        #expect(decoded.mode == .automatic)
        #expect(decoded.isReclaimedBySystem == false)
        #expect(decoded.actualRPM.value == nil)
    }
}

/// #96's second gap: `FanState.targetRPM` had no finiteness check anywhere, at
/// construction or on decode, and it is the field E5's control loop is about to start
/// populating with values derived from arithmetic.
@Suite("FanState.targetRPM refuses non-finite values")
struct FanStateTargetRPMTests {

    private func state(targetRPM: Double?) -> FanState {
        FanState(
            index: 0,
            actualRPM: .measured(1800),
            minimumRPM: .measured(1200),
            maximumRPM: .measured(5400),
            targetRPM: targetRPM,
            mode: .manualFixed,
            isReclaimedBySystem: false,
            manualControlAvailability: .available
        )
    }

    /// "No target could be read" and "no target is set" are meant to be the same shape
    /// here: `targetRPM` is `Double?`, and `nil` is already its "asking for nothing"
    /// landing. Delete the `isFinite` check in the normalising helper and this reports a
    /// live NaN target.
    @Test(
        "A non-finite target normalises to nil rather than being carried",
        arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteTargetBecomesNil(_ nonFiniteValue: Double) throws {
        let built = state(targetRPM: nonFiniteValue)
        #expect(built.targetRPM == nil)

        // The same guarantee must hold once it crosses the wire, not only in memory.
        let decoded = try JSONDecoder().decode(
            FanState.self, from: try JSONEncoder().encode(built))
        #expect(decoded.targetRPM == nil)
    }

    @Test("A finite target is carried exactly")
    func finiteTargetIsCarriedExactly() throws {
        let built = state(targetRPM: 2400)
        #expect(built.targetRPM == 2400)

        let decoded = try JSONDecoder().decode(
            FanState.self, from: try JSONEncoder().encode(built))
        #expect(decoded.targetRPM == 2400)
    }

    @Test("No target set stays no target set")
    func nilTargetStaysNil() throws {
        let built = state(targetRPM: nil)
        #expect(built.targetRPM == nil)

        let decoded = try JSONDecoder().decode(
            FanState.self, from: try JSONEncoder().encode(built))
        #expect(decoded.targetRPM == nil)
    }

    /// `nonFiniteTargetBecomesNil` above never exercises `FanState.init(from:)`'s own
    /// guard: it builds through the memberwise initialiser first, which already
    /// normalises the non-finite value to `nil` *before* anything is encoded, so the JSON
    /// that reaches the decoder never carries a non-finite double in the first place —
    /// deleting the custom `init(from:)` and falling back to the synthesised one leaves
    /// that test green.
    ///
    /// This test instead builds the wire payload directly, the way
    /// `FanCurveHysteresisTests.nonFiniteHysteresisIsRefusedOnDecode` does for
    /// `FanCurve`: encode a raw, `FanState`-shaped value whose `targetRPM` is genuinely
    /// NaN using `.convertToString`, then decode *that* JSON through `FanState.self` with
    /// `.convertFromString` so the non-finite double actually reaches
    /// `FanState.init(from:)`. Delete the custom initialiser (falling back to the
    /// synthesised one, which assigns `targetRPM` directly) and `decoded.targetRPM` comes
    /// back `.some(Double.nan)` instead of `nil`, and this goes red.
    @Test("A non-finite targetRPM reaching FanState.init(from:) normalises to nil")
    func nonFiniteTargetRPMIsRefusedOnDecodeThroughFanStateInit() throws {
        struct RawFanState: Encodable {
            let index: Int
            let firmwareName: String?
            let actualRPM: FanReading
            let minimumRPM: FanReading
            let maximumRPM: FanReading
            let targetRPM: Double
            let mode: FanControlMode
            let isReclaimedBySystem: Bool
            let manualControlAvailability: ManualControlAvailability
        }
        let raw = RawFanState(
            index: 0,
            firmwareName: nil,
            actualRPM: .measured(1800),
            minimumRPM: .measured(1200),
            maximumRPM: .measured(5400),
            targetRPM: .nan,
            mode: .manualFixed,
            isReclaimedBySystem: false,
            manualControlAvailability: .available
        )
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let data = try encoder.encode(raw)

        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let decoded = try decoder.decode(FanState.self, from: data)

        #expect(decoded.targetRPM == nil)
    }
}

/// #96's acceptance criterion: "a test that fails if a producer is added without it".
///
/// `measuredFinite` is a public enum case, and Swift cannot restrict a case's access
/// below the access level of the enum it belongs to — so `FanReading.measuredFinite(
/// .nan)` compiles from any module today, `FanKitTests` included. `measured(_:)`'s
/// `isFinite` guard therefore holds only by *convention*: every producer is expected to
/// go through it rather than construct the case directly. This suite is what turns that
/// convention into something that fails when broken, by asserting a property of the
/// source tree rather than trusting every future call site to remember.
@Suite("measuredFinite is constructed nowhere but its own guard")
struct MeasuredFiniteConstructionSiteTests {

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FanKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources")
    }

    /// Every line under `Sources/` that constructs `measuredFinite(`, with its file name,
    /// comment lines stripped first. The doc comment on the case itself and on
    /// `measured(_:)` both name `measuredFinite(` in prose — a tripwire that fires on the
    /// sentence explaining the rule is a tripwire nobody keeps.
    private static func measuredFiniteConstructionSites() throws -> [(file: String, line: String)] {
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the project's sources were not found at \(sourcesRoot.path)")

        var sites: [(file: String, line: String)] = []
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
            for rawLine in code.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                if trimmed.contains("measuredFinite(") {
                    sites.append((file: file.lastPathComponent, line: trimmed))
                }
            }
        }
        return sites
    }

    /// Delete this guard — or add a second construction site anywhere under `Sources/`,
    /// e.g. `let poisoned = FanReading.measuredFinite(.nan)` in an unrelated file — and
    /// this reports the offending file and line rather than passing silently.
    @Test("measuredFinite( is constructed only inside Fan.swift")
    func onlyConstructedInFanSwift() throws {
        let sites = try Self.measuredFiniteConstructionSites()
        let outsideFanSwift = sites.filter { $0.file != "Fan.swift" }
        #expect(
            outsideFanSwift.isEmpty,
            "measuredFinite( constructed outside Fan.swift: \(outsideFanSwift)")
    }
}
