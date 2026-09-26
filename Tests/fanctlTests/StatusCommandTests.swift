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
        #expect(
            text.contains(
                "expiry, as the helper's wall-clock estimate: 2026-09-21T14:13:45Z"))
        #expect(text.contains("self-renewing: no"))
        #expect(text.contains("mode manualFixed · target 3000 RPM"))
        #expect(!text.contains("running at 3000"))
    }

    /// A `nil` lease establishes only that no Aeolus client holds one. The fan beside it may
    /// be driven by another program, mid-handback, or unconfirmed — so the output must never
    /// turn "no lease" into "nothing holds the fans" (rule 6).
    ///
    /// **Mutation:** restore "No client holds the fans." to `leaseLines`. Run: red.
    @Test("No lease beside a manual fan never claims the fans are unheld or free")
    func noLeaseIsNotFreeFans() throws {
        let observation = Self.observation(fans: [
            Self.fan(
                0, mode: .manualFixed, target: 2500,
                availability: .unavailable(.foreignManualControl))
        ])
        let text = StatusCommand.text(for: observation)
        #expect(text.contains("No Aeolus client holds a manual-control lease."))
        #expect(text.contains("mode manualFixed · target 2500 RPM"))
        #expect(text.contains("reason: foreignManualControl"))
        for claim in [
            "No client holds the fans", "fans are free", "not held", "unheld", "fans are automatic",
        ] {
            #expect(!text.contains(claim), "status claimed \"\(claim)\"")
        }

        let document = try Self.json(observation)
        #expect(document["lease"] is NSNull)
        let fans = try #require(document["fans"] as? [[String: Any]])
        #expect(fans.first?["mode"] as? String == "manualFixed")
        #expect(
            Set(document.keys).isDisjoint(with: ["fansHeld", "fansFree", "held", "free"]),
            "the document derives a held/free claim from the lease")
    }

    /// `expiresAt` is a display-only wall-clock estimate; the helper enforces the lease on
    /// monotonic time. A wall-clock step can put it before capture while the lease is active,
    /// and the snapshot listing the lease is what says it is held.
    ///
    /// **Mutation:** reintroduce the `expiresAt < capturedAt` comparison that printed
    /// "expired … at or before capture". Run: red.
    @Test("A listed lease whose estimate precedes capture is still held, never expired")
    func anEarlyEstimateIsNotExpiry() throws {
        let lease = Lease(
            holderDescription: "Aeolus.app 0.3.0",
            expiresAt: Self.captured.addingTimeInterval(-90))
        let observation = Self.observation(fans: [Self.fan(0)], lease: lease)
        let text = StatusCommand.text(for: observation)
        #expect(text.contains("Manual-control lease: held by \"Aeolus.app 0.3.0\""))
        #expect(
            text.contains(
                "expiry, as the helper's wall-clock estimate: 2026-09-21T14:11:50Z"))
        #expect(!text.lowercased().contains("expired"))
        #expect(!text.contains("after capture"))

        let document = try Self.json(observation)
        let body = try #require(document["lease"] as? [String: Any])
        #expect(body["expiresAt"] as? String == "2026-09-21T14:11:50Z")
        #expect(body["expired"] == nil)
        #expect(body["isActive"] == nil)
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
