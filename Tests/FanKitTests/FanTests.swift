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
}
