import Foundation
import Testing

@testable import FanKit

/// The gate from #37: `CLAUDE.md` rule 4 says firmware bounds win, and that assumes the
/// decoded bounds are real. `F<n>Mn`/`F<n>Mx` are `flt` keys and a byte-swapped `flt` is
/// typically a denormal or ~1e14, so **no single codec error may silently become a clamp
/// ceiling**.
///
/// Every rejection here uses synthetic bounds and needs no hardware.
@Suite("Fan bounds plausibility")
struct FanBoundsPlausibilityTests {

    private func verdict(
        _ minimum: Double,
        _ maximum: Double
    ) -> Result<FanControlEnvelope, FanBoundsImplausibility> {
        FanControlEnvelope.validating(
            declaredMinimumRPM: minimum,
            declaredMaximumRPM: maximum
        )
    }

    private func refusal(_ minimum: Double, _ maximum: Double) -> FanBoundsImplausibility? {
        guard case .failure(let reason) = verdict(minimum, maximum) else { return nil }
        return reason
    }

    @Test("Real hardware bounds are accepted")
    func realBoundsAreAccepted() throws {
        // Mac16,5 declares 1350 and 5777.
        let envelope = try verdict(1350, 5777).get()
        #expect(envelope.declaredMinimumRPM == 1350)
        #expect(envelope.declaredMaximumRPM == 5777)
        #expect(envelope.lowestCommandableRPM == 1350)
        #expect(envelope.highestCommandableRPM == 5777)
    }

    /// A machine whose fans stop when idle is a machine Aeolus must work on, not one it
    /// refuses. The zero is handled by the floor, not by rejecting the fan.
    @Test("A declared minimum of zero is accepted, not refused")
    func zeroMinimumIsAccepted() throws {
        let envelope = try verdict(0, 5777).get()
        #expect(envelope.lowestCommandableRPM == FanSafetyLimits.minimumManualRPM)
    }

    @Test("A non-finite bound is refused")
    func nonFiniteBoundsAreRefused() {
        #expect(refusal(.nan, 5777) == .notFinite)
        #expect(refusal(1350, .nan) == .notFinite)
        #expect(refusal(1350, .infinity) == .notFinite)
        #expect(refusal(-.infinity, 5777) == .notFinite)
    }

    @Test("A negative declared minimum is refused")
    func negativeMinimumIsRefused() {
        #expect(refusal(-1, 5777) == .negativeMinimum)
        #expect(refusal(-5777, -1350) == .negativeMinimum)
    }

    @Test("Inverted or degenerate bounds are refused")
    func invertedBoundsAreRefused() {
        #expect(refusal(5777, 1350) == .notAscending)
        #expect(refusal(1350, 1350) == .notAscending)
        #expect(refusal(0, 0) == .notAscending)
    }

    /// The interaction that keeps rule 3 and rule 4 from contradicting each other. If the
    /// whole declared range sits below the commandable floor there is no speed that
    /// honours both, so the fan is refused rather than driven past its declared maximum.
    /// Delete this check and the floor starts pushing targets above `F<n>Mx`.
    @Test("A maximum below the commandable floor is refused")
    func maximumBelowTheFloorIsRefused() {
        #expect(refusal(0, 50) == .maximumBelowFloor)
        #expect(refusal(10, 99) == .maximumBelowFloor)
        #expect(refusal(0, FanSafetyLimits.minimumManualRPM) == nil)
    }

    /// The ~1e14 half of a byte-order fault, and the reason `maximumPlausibleRPM` exists.
    @Test("An implausibly high maximum is refused")
    func implausiblyHighMaximumIsRefused() {
        #expect(refusal(1350, 1e14) == .maximumAboveCeiling)
        #expect(refusal(1350, FanSafetyLimits.maximumPlausibleRPM + 1) == .maximumAboveCeiling)
        #expect(refusal(1350, FanSafetyLimits.maximumPlausibleRPM) == nil)
    }

    /// A minimum above the sanity ceiling cannot slip through: it drags the maximum above
    /// the ceiling with it, because the range must ascend.
    @Test("A minimum above the sanity ceiling cannot produce an envelope")
    func absurdMinimumCannotProduceAnEnvelope() {
        #expect(refusal(1e14, 1e15) == .maximumAboveCeiling)
        #expect(refusal(1e14, 5777) == .notAscending)
    }

    /// Whatever failed, the answer a client gets is the one E2 already shipped. This is
    /// the vocabulary check: nothing here invents a parallel reason.
    @Test(
        "Every refusal means manual control is unavailable for bounds",
        arguments: [
            FanBoundsImplausibility.notMeasured,
            .notFinite,
            .negativeMinimum,
            .notAscending,
            .maximumBelowFloor,
            .maximumAboveCeiling,
        ])
    func everyRefusalIsBoundsImplausible(reason: FanBoundsImplausibility) {
        #expect(reason.manualControlAvailability == .unavailable(.boundsImplausible))
        #expect(reason.description.isEmpty == false)
    }

    /// A refused fan must be unable to produce a target at all — not merely discouraged
    /// from doing so. The only producer of a `FanTargetRPM` is an envelope, and a refusal
    /// carries no envelope, so there is nothing to ask.
    @Test("A refused fan yields no envelope, and so no target")
    func aRefusedFanYieldsNoEnvelope() {
        let refused = verdict(1350, 1e14)
        #expect(refused.isSuccessResult == false)

        switch refused {
        case .success:
            Issue.record("implausible bounds produced a commandable envelope")
        case .failure(let reason):
            #expect(reason == .maximumAboveCeiling)
        }
    }
}

/// The gate as a fan model reaches it: `Fan` from firmware, `FanState` from the wire.
@Suite("Bounds plausibility on the fan models")
struct FanBoundsModelTests {

    @Test("A fan whose declared bounds are implausible has no envelope")
    func fanWithBadBoundsHasNoEnvelope() {
        let fan = Fan(index: 0, minimumRPM: 5777, maximumRPM: 1350)
        guard case .failure(let reason) = fan.controlEnvelope else {
            Issue.record("inverted bounds produced an envelope")
            return
        }
        #expect(reason == .notAscending)
    }

    @Test("A fan with real bounds has an envelope")
    func fanWithGoodBoundsHasAnEnvelope() throws {
        let fan = Fan(index: 0, minimumRPM: 1350, maximumRPM: 5777)
        #expect(try fan.controlEnvelope.get().lowestCommandableRPM == 1350)
    }

    /// "A bound did not read" and "a bound cannot be trusted" are different conditions
    /// with the same consequence, and `FanState.controlEnvelope` answers both at once so a
    /// caller cannot handle only the half it thought of.
    @Test("A fan whose bound never read has no envelope either")
    func unreadBoundIsNotMeasured() {
        func state(minimum: FanReading, maximum: FanReading) -> FanState {
            FanState(
                index: 0,
                actualRPM: .measured(1343.07),
                minimumRPM: minimum,
                maximumRPM: maximum,
                targetRPM: nil,
                mode: .automatic,
                isReclaimedBySystem: false,
                manualControlAvailability: .unavailable(.boundsImplausible)
            )
        }
        let missing = FanReading.unavailable(reason: "F0Mx is not present on this machine")

        #expect(
            state(minimum: .measured(1350), maximum: missing).controlEnvelope.failureReason
                == .notMeasured)
        #expect(
            state(minimum: missing, maximum: .measured(5777)).controlEnvelope.failureReason
                == .notMeasured)
        #expect(
            state(minimum: missing, maximum: missing).controlEnvelope.failureReason
                == .notMeasured)
        // Both read, and trustworthy: an envelope, and the observation still untouched.
        let readable = state(minimum: .measured(1350), maximum: .measured(5777))
        #expect(readable.controlEnvelope.failureReason == nil)
        #expect(readable.actualRPM.value == 1343.07)
    }
}

extension Result where Success == FanControlEnvelope, Failure == FanBoundsImplausibility {

    fileprivate var failureReason: FanBoundsImplausibility? {
        guard case .failure(let reason) = self else { return nil }
        return reason
    }

    fileprivate var isSuccessResult: Bool {
        guard case .success = self else { return false }
        return true
    }
}
