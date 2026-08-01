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
        #expect(ManualControlAvailability.Reason.unknown("xyz").wireValue == "xyz")
    }

    /// The field is part of `FanState`'s wire shape, not a Swift-side convenience, so it
    /// has to survive the same round trip the rest of the snapshot does.
    @Test("FanState carries manual control availability across the wire")
    func fanStateCarriesAvailability() throws {
        let state = FanState(
            fan: Fan(index: 0, minimumRPM: 1200, maximumRPM: 5400, firmwareName: nil),
            actualRPM: 1800,
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

    /// A required field, and required on the wire too: a snapshot that omits it must not
    /// decode into a `FanState` that quietly claims one answer or the other.
    @Test("A FanState payload omitting manual control availability does not decode")
    func fanStateWithoutAvailabilityThrows() {
        let json = """
            {"fan":{"index":0,"minimumRPM":1200,"maximumRPM":5400},"actualRPM":1800,\
            "mode":"automatic","isReclaimedBySystem":false}
            """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FanState.self, from: Data(json.utf8))
        }
    }
}
