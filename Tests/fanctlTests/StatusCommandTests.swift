import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import fanctl

/// What `fanctl status` prints for a snapshot, as text and as `--json`. The round trip is
/// `FanctlStatusTests`, in `AeolusHelperTests`.
@Suite("fanctl status rendering")
struct StatusCommandTests {

    private static let captured = Date(timeIntervalSince1970: 1_790_000_000)

    private static func fan(
        _ index: Int,
        mode: FanControlMode = .automatic,
        target: Double? = nil,
        reclaimed: Bool = false,
        availability: ManualControlAvailability = .available,
        actual: FanReading = .measured(1351)
    ) -> FanState {
        FanState(
            index: index, actualRPM: actual, minimumRPM: .measured(1350),
            maximumRPM: .measured(5777), targetRPM: target, mode: mode,
            isReclaimedBySystem: reclaimed, manualControlAvailability: availability)
    }

    private static func observation(
        fans: [FanState], lease: Lease? = nil, emergency: Bool = false,
        helper: HelloReply? = HelloReply(
            helperProtocolRange: AeolusXPCVersion.supportedRange, helperBuild: "0.0.0-dev",
            capabilities: [])
    ) -> StatusCommand.Observation {
        StatusCommand.Observation(
            snapshot: SystemSnapshot(
                fans: fans, sensors: [], activeLease: lease,
                isThermalEmergencyActive: emergency, capturedAt: captured),
            helper: helper)
    }

    // MARK: - Text

    @Test("No lease, no emergency: both said plainly")
    func quietMachine() {
        let text = StatusCommand.text(for: Self.observation(fans: [Self.fan(0)]))
        #expect(text.contains("Manual-control lease: none."))
        #expect(text.contains("Thermal emergency: not active."))
        #expect(text.contains("actual 1351 RPM · range 1350 RPM to 5777 RPM"))
        #expect(text.contains("mode automatic · target none"))
        #expect(text.contains("negotiated XPC protocol 1"))
    }

    /// The lease is its own block, and a fan's target is never printed as a speed.
    @Test("A lease is reported apart from the fans, with holder and expiry")
    func leaseIsSeparate() {
        let lease = Lease(
            holderDescription: "fanctl 0.0.0-dev pid 42 (set)",
            expiresAt: Self.captured.addingTimeInterval(25))
        let text = StatusCommand.text(
            for: Self.observation(
                fans: [Self.fan(0, mode: .manualFixed, target: 3000)], lease: lease))
        #expect(text.contains("held by \"fanctl 0.0.0-dev pid 42 (set)\""))
        #expect(text.contains("(25 s after capture)"))
        #expect(text.contains("self-renewing: no"))
        #expect(text.contains("mode manualFixed · target 3000 RPM"))
        #expect(!text.contains("running at 3000"))
    }

    @Test("A reclaimed fan says Aeolus is not driving it")
    func reclaimedIsLoud() {
        let text = StatusCommand.text(
            for: Self.observation(fans: [
                Self.fan(
                    0, mode: .manualFixed, target: 3000, reclaimed: true,
                    availability: .unavailable(.reclaimedBySystem))
            ]))
        #expect(text.contains("RECLAIMED BY THE SYSTEM"))
        #expect(text.contains("reason: reclaimedBySystem"))
    }

    @Test("Every refusal reason renders its summary, advice and wire value")
    func everyReasonRenders() {
        let reasons: [ManualControlAvailability.Reason] = [
            .writePathNotBuilt, .boundsImplausible, .reclaimedBySystem, .leaseHeldByAnotherClient,
            .selfRenewalNotBuilt, .releaseInProgress, .handbackUnconfirmed,
            .restoreToAutomaticUnconfirmed, .restoreToAutomaticFailed, .systemSleeping,
            .noThermalTelemetry, .supervisorBlind, .foreignManualControl, .unknown("fromTheFuture"),
        ]
        for reason in reasons {
            let line = StatusCommand.availability(.unavailable(reason))
            #expect(line.contains(reason.userFacingSummary), "\(reason)")
            #expect(line.contains(reason.recoveryAdvice), "\(reason)")
            #expect(line.contains("(reason: \(reason.wireValue))"), "\(reason)")
        }
    }

    @Test("An unreadable reading is never printed as a number")
    func unavailableReadingIsNamed() {
        let text = StatusCommand.text(
            for: Self.observation(fans: [
                Self.fan(0, actual: .unavailable(reason: "F0Ac did not answer"))
            ]))
        #expect(text.contains("actual unavailable (F0Ac did not answer)"))
    }

    @Test("A thermal emergency is announced")
    func emergencyIsAnnounced() {
        let text = StatusCommand.text(for: Self.observation(fans: [Self.fan(0)], emergency: true))
        #expect(text.contains("Thermal emergency: ACTIVE"))
    }

    // MARK: - JSON

    private static func json(_ observation: StatusCommand.Observation) throws -> [String: Any] {
        let encoded = try FanctlJSON.encode(StatusDocumentJSON(observation))
        let object = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        return try #require(object as? [String: Any])
    }

    @Test("The document carries every top-level key, schema 1")
    func topLevelKeys() throws {
        let document = try Self.json(Self.observation(fans: [Self.fan(0)]))
        #expect(
            Set(document.keys) == [
                "schema", "capturedAt", "protocolVersion", "clientProtocolVersion", "helper",
                "thermalEmergencyActive", "lease", "fans",
            ])
        #expect(document["schema"] as? Int == 1)
        #expect(document["lease"] is NSNull)
        #expect(document["capturedAt"] as? String == "2026-09-21T14:13:20Z")
    }

    @Test("A fan carries every key, with explicit nulls")
    func fanKeys() throws {
        let document = try Self.json(
            Self.observation(fans: [
                Self.fan(0, availability: .unavailable(.writePathNotBuilt))
            ]))
        let fans = try #require(document["fans"] as? [[String: Any]])
        let fan = try #require(fans.first)
        #expect(
            Set(fan.keys) == [
                "index", "firmwareName", "actualRPM", "minimumRPM", "maximumRPM", "targetRPM",
                "mode", "isReclaimedBySystem", "manualControl",
            ])
        #expect(fan["targetRPM"] is NSNull)
        #expect(fan["firmwareName"] is NSNull)
        let actual = try #require(fan["actualRPM"] as? [String: Any])
        #expect(actual["value"] as? Double == 1351)
        #expect(actual["unavailableReason"] is NSNull)
        let manual = try #require(fan["manualControl"] as? [String: Any])
        #expect(manual["state"] as? String == "unavailable")
        #expect(manual["reason"] as? String == "writePathNotBuilt")
        #expect(manual["advice"] is String)
    }

    @Test("A lease carries its holder, expiry and self-renewal flag")
    func leaseKeys() throws {
        let lease = Lease(
            holderDescription: "Aeolus.app", expiresAt: Self.captured.addingTimeInterval(30))
        let document = try Self.json(Self.observation(fans: [], lease: lease))
        let body = try #require(document["lease"] as? [String: Any])
        #expect(
            Set(body.keys) == [
                "id", "holderDescription", "expiresAt", "timeToLive", "isSelfRenewing",
            ]
        )
        #expect(body["holderDescription"] as? String == "Aeolus.app")
        #expect(body["isSelfRenewing"] as? Bool == false)
    }

    @Test("A snapshot taken with no handshake in hand reports helper as null")
    func missingHandshakeIsNull() throws {
        let document = try Self.json(Self.observation(fans: [], helper: nil))
        #expect(document["helper"] is NSNull)
    }
}
