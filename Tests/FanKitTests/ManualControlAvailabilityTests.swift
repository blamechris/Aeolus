import Foundation
import Testing

@testable import FanKit

/// `ManualControlAvailability` answers "could this fan be taken under a lease at all",
/// which is the question a UI has to get right before it offers a slider. Its decoding
/// rules are asymmetric on purpose — a value nobody recognises must never read as
/// permission — so the tests here are mostly about which way each ambiguity falls.
@Suite("Manual control availability")
struct ManualControlAvailabilityTests {

    private typealias Availability = ManualControlAvailability

    private func roundTrip(_ value: Availability) throws -> Availability {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Availability.self, from: data)
    }

    private func decode(_ json: String) throws -> Availability {
        try JSONDecoder().decode(Availability.self, from: Data(json.utf8))
    }

    @Test(
        "Every case survives a round trip",
        arguments: [
            ManualControlAvailability.available,
            .unavailable(.writePathNotBuilt),
            .unavailable(.boundsImplausible),
            .unavailable(.reclaimedBySystem),
            .unavailable(.leaseHeldByAnotherClient),
            .unavailable(.selfRenewalNotBuilt),
            .unavailable(.releaseInProgress),
            .unavailable(.noThermalTelemetry),
            .unavailable(.supervisorBlind),
            .unavailable(.unknown("somethingFromAFutureHelper")),
        ]
    )
    func everyCaseRoundTrips(_ value: ManualControlAvailability) throws {
        #expect(try roundTrip(value) == value)
    }

    /// The forward-tolerance contract: a reason a newer helper invented must arrive as
    /// itself, not as a decode failure and not as one of the reasons this build knows.
    @Test("An unrecognised reason decodes to .unknown carrying the raw value")
    func unrecognisedReasonDecodesToUnknown() throws {
        let decoded = try decode(#"{"state":"unavailable","reason":"firmwareLocked"}"#)
        #expect(decoded == .unavailable(.unknown("firmwareLocked")))
    }

    /// The direction of the guess is the whole point. If a future version grows a third
    /// state, an old client must read it as "cannot control", never as "can".
    @Test("An unrecognised state fails closed to unavailable, never to available")
    func unrecognisedStateFailsClosed() throws {
        let decoded = try decode(#"{"state":"partiallyAvailable"}"#)
        #expect(decoded == .unavailable(.unknown("partiallyAvailable")))
        #expect(decoded != .available)
    }

    /// Structural corruption is not forward tolerance. Within a version the required
    /// fields of a known state cannot move, so their absence means the payload is broken.
    @Test("A known state missing its required reason throws rather than guessing")
    func unavailableWithoutReasonThrows() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"state":"unavailable"}"#)
        }
    }

    @Test("A payload with no state at all throws")
    func missingStateThrows() {
        #expect(throws: DecodingError.self) {
            try decode(#"{}"#)
        }
    }

    /// Round-tripping a known reason must land back on the known case. If
    /// `Reason(wireValue:)` stopped recognising a value, this build would start treating
    /// its own vocabulary as foreign.
    @Test(
        "A known wire value never decodes into the unknown case",
        arguments: [
            ManualControlAvailability.Reason.writePathNotBuilt,
            .boundsImplausible,
            .reclaimedBySystem,
            .leaseHeldByAnotherClient,
            .selfRenewalNotBuilt,
            .releaseInProgress,
            .noThermalTelemetry,
            .supervisorBlind,
        ]
    )
    func knownWireValuesResolveToKnownCases(_ reason: ManualControlAvailability.Reason) {
        let resolved = ManualControlAvailability.Reason(wireValue: reason.wireValue)
        #expect(resolved == reason)
        if case .unknown = resolved {
            Issue.record("\(reason.wireValue) resolved to the unknown case")
        }
    }

    /// The wire values are the contract. Renaming a Swift case is free; renaming what it
    /// serialises as is a protocol change, and this test is what makes that visible.
    @Test("Reason wire values are the ones the contract publishes")
    func wireValuesAreStable() {
        #expect(ManualControlAvailability.Reason.writePathNotBuilt.wireValue == "writePathNotBuilt")
        #expect(ManualControlAvailability.Reason.boundsImplausible.wireValue == "boundsImplausible")
        #expect(ManualControlAvailability.Reason.reclaimedBySystem.wireValue == "reclaimedBySystem")
        #expect(
            ManualControlAvailability.Reason.leaseHeldByAnotherClient.wireValue
                == "leaseHeldByAnotherClient")
        #expect(
            ManualControlAvailability.Reason.selfRenewalNotBuilt.wireValue
                == "selfRenewalNotBuilt")
        #expect(
            ManualControlAvailability.Reason.releaseInProgress.wireValue
                == "releaseInProgress")
        #expect(
            ManualControlAvailability.Reason.noThermalTelemetry.wireValue
                == "noThermalTelemetry")
        #expect(
            ManualControlAvailability.Reason.supervisorBlind.wireValue
                == "supervisorBlind")
        #expect(ManualControlAvailability.Reason.unknown("xyz").wireValue == "xyz")
    }

    /// The field is part of `FanState`'s wire shape, not a Swift-side convenience, so it
    /// has to survive the same round trip the rest of the snapshot does.
    @Test("FanState carries manual control availability across the wire")
    func fanStateCarriesAvailability() throws {
        let state = FanState(
            index: 0,
            actualRPM: .measured(1800),
            minimumRPM: .measured(1200),
            maximumRPM: .measured(5400),
            targetRPM: nil,
            mode: .automatic,
            isReclaimedBySystem: false,
            manualControlAvailability: .unavailable(.writePathNotBuilt)
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(FanState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.manualControlAvailability == .unavailable(.writePathNotBuilt))
    }

    /// Blindness travels on the availability vocabulary and nowhere else — #140.
    ///
    /// The wire claim this change rests on: a new `Reason` is additive within protocol
    /// version 1, because an older peer decodes an unrecognised reason to `.unknown(_)` and
    /// renders it generically. That is what `AeolusXPCVersion`'s bump policy permits without
    /// a bump, and it is why no `FanState` field was grown to carry this: a new required
    /// field would be a bump, and an optional one would put a third state on a question that
    /// has two answers.
    ///
    /// `isReclaimedBySystem` stays `false` on the same payload. A fan given up because the
    /// helper went blind on it is not a fan the system took.
    @Test("Supervisor blindness crosses the wire as a reason, not as a reclamation")
    func supervisorBlindnessCrossesTheWire() throws {
        let state = FanState(
            index: 0,
            actualRPM: .unavailable(reason: "F0Ac: the read did not answer"),
            minimumRPM: .measured(1200),
            maximumRPM: .measured(5400),
            targetRPM: nil,
            mode: .automatic,
            isReclaimedBySystem: false,
            manualControlAvailability: .unavailable(.supervisorBlind)
        )

        let decoded = try JSONDecoder().decode(
            FanState.self, from: try JSONEncoder().encode(state))

        #expect(decoded == state)
        #expect(decoded.manualControlAvailability == .unavailable(.supervisorBlind))
        #expect(decoded.isReclaimedBySystem == false)
        // The wire string is the contract, so it is asserted against the literal a peer
        // would actually send rather than against this build's own encoder.
        #expect(
            try decode(#"{"state":"unavailable","reason":"supervisorBlind"}"#)
                == .unavailable(.supervisorBlind))
    }

    /// A required field, and required on the wire too: a snapshot that omits it must not
    /// decode into a `FanState` that quietly claims one answer or the other.
    @Test("A FanState payload omitting manual control availability does not decode")
    func fanStateWithoutAvailabilityThrows() {
        let json = """
            {"index":0,"actualRPM":{"value":1800},"minimumRPM":{"value":1200},\
            "maximumRPM":{"value":5400},"mode":"automatic","isReclaimedBySystem":false}
            """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FanState.self, from: Data(json.utf8))
        }
    }

    /// The reshape that made this type able to describe a partially-readable fan is only
    /// worth anything if the honest state actually survives the wire. A machine that
    /// reports `F0Mn` but not `F0Mx` is the case `FanPoller` was written to tolerate and
    /// the case the old wire shape could not express at all.
    @Test("A fan whose maximum did not read still crosses the wire, and says so")
    func partiallyReadableFanRoundTrips() throws {
        let state = FanState(
            index: 0,
            actualRPM: .measured(1343.07),
            minimumRPM: .measured(1350),
            maximumRPM: .unavailable(reason: "F0Mx: key not present on this machine"),
            targetRPM: nil,
            mode: .automatic,
            isReclaimedBySystem: false,
            manualControlAvailability: .unavailable(.boundsImplausible)
        )

        let decoded = try JSONDecoder().decode(
            FanState.self, from: try JSONEncoder().encode(state))

        #expect(decoded == state)
        // The measured value is below the declared minimum and is carried unchanged:
        // 1343.07 against F0Mn 1350 is the reading this project actually observed, and
        // clamping it would be inventing data about hardware.
        #expect(decoded.actualRPM.value == 1343.07)
        #expect(decoded.maximumRPM.value == nil)
        // And the control model is unobtainable, so nothing can clamp into an envelope
        // that was never read.
        #expect(decoded.fan == nil)
    }

    /// A fan with both bounds measured yields the control model; that is the only way to
    /// get one, which is what keeps the clamp from ever seeing an invented envelope.
    @Test("The control model exists only when both bounds were really measured")
    func controlModelRequiresBothBounds() throws {
        func state(minimum: FanReading, maximum: FanReading) -> FanState {
            FanState(
                index: 2,
                firmwareName: "Exhaust",
                actualRPM: .measured(2000),
                minimumRPM: minimum,
                maximumRPM: maximum,
                targetRPM: nil,
                mode: .automatic,
                isReclaimedBySystem: false,
                manualControlAvailability: .unavailable(.writePathNotBuilt)
            )
        }
        let missing = FanReading.unavailable(reason: "not present")

        #expect(state(minimum: .measured(1200), maximum: .measured(5400)).fan != nil)
        #expect(state(minimum: missing, maximum: .measured(5400)).fan == nil)
        #expect(state(minimum: .measured(1200), maximum: missing).fan == nil)
        #expect(state(minimum: missing, maximum: missing).fan == nil)

        let fan = state(minimum: .measured(1200), maximum: .measured(5400)).fan
        #expect(fan?.index == 2)
        #expect(fan?.firmwareName == "Exhaust")
        #expect(try fan?.controlEnvelope.get().target(for: 0).rpm == 1200)
    }
}

/// `FanReading` is the type that stops a failed read from being reported as `0`, so its
/// refusals are the behaviour under test rather than an implementation detail.
@Suite("Fan reading availability")
struct FanReadingTests {

    @Test("A reading carries a value or a reason, never both and never neither")
    func mutuallyExclusiveOnTheWire() {
        let both = #"{"value":1800,"unavailableReason":"read failed"}"#
        let neither = "{}"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FanReading.self, from: Data(both.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FanReading.self, from: Data(neither.utf8))
        }
    }

    /// An overflowing literal is refused — but by `JSONDecoder`, before `FanReading` sees
    /// anything.
    ///
    /// Recorded as its own test precisely so it is not mistaken for coverage of the
    /// finiteness guard below. It was written as that coverage, and it is not: deleting
    /// `FanReading`'s `isFinite` check left this green, because Foundation rejects a
    /// `Double` overflow first. A test that passes for a reason other than the one in its
    /// name is the failure mode this repository keeps finding, and it does not stop being
    /// one when the assertion happens to be true.
    @Test("An overflowing literal is refused by the JSON decoder", arguments: ["1e999", "-1e999"])
    func overflowingLiteralRefusedByFoundation(_ literal: String) {
        let json = #"{"value":\#(literal)}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FanReading.self, from: Data(json.utf8))
        }
    }

    /// The finiteness guard itself, exercised by a decoder that *will* hand `FanReading` a
    /// non-finite `Double`.
    ///
    /// `AeolusXPCCoding.decoder()` does not set `nonConformingFloatDecodingStrategy`, so
    /// the default `.throw` means a non-finite value cannot reach this type over the real
    /// wire today — the guard is defence in depth, and saying so is more useful than
    /// implying it is load-bearing. It is tested anyway, because the change that would
    /// make it reachable is a one-line convenience nobody would think of as a safety
    /// change, and an infinite RPM rendered in a UI is indistinguishable from a broken
    /// app.
    @Test(
        "A non-finite value is refused even by a decoder that admits one",
        arguments: ["inf", "-inf", "nan"]
    )
    func nonFiniteValueRefusedByFanReading(_ marker: String) {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf",
            negativeInfinity: "-inf",
            nan: "nan"
        )
        let json = #"{"value":"\#(marker)"}"#

        // Proves the premise rather than assuming it: this decoder really does produce a
        // non-finite Double, so reaching FanReading's guard is not hypothetical.
        let bare = try? decoder.decode(Double.self, from: Data(#""\#(marker)""#.utf8))
        #expect(bare?.isFinite == false)

        #expect(throws: DecodingError.self) {
            try decoder.decode(FanReading.self, from: Data(json.utf8))
        }
    }

    @Test("Both shapes survive a round trip")
    func bothShapesRoundTrip() throws {
        for reading: FanReading in [.measured(1343.07), .unavailable(reason: "no such key")] {
            let decoded = try JSONDecoder().decode(
                FanReading.self, from: try JSONEncoder().encode(reading))
            #expect(decoded == reading)
        }
    }
}
