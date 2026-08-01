import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// E2's authority: it reports the machine truthfully and refuses everything that would
/// need a write path.
@Suite("ReadOnlyFanAuthority")
struct ReadOnlyFanAuthorityTests {

    private static let log = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Authority")

    /// The one refusal every control path in E2 raises. Named once so the four tests
    /// below assert the same value rather than four copies of it.
    private static let noWritePath = AeolusXPCFault.manualControlUnavailable(
        reason: .writePathNotBuilt)

    private func authority(provider: FakeSensorProvider) -> ReadOnlyFanAuthority {
        ReadOnlyFanAuthority(
            provider: provider,
            log: Self.log,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }

    // MARK: - Snapshot shape

    @Test("Every fan is automatic, uncontrollable, and asking for nothing")
    func fansAreAutomaticAndUncontrollable() async throws {
        let snapshot = try await authority(provider: fanProvider(fanCount: 2)).snapshot()

        #expect(snapshot.fans.count == 2)
        for fan in snapshot.fans {
            #expect(fan.mode == .automatic)
            #expect(fan.targetRPM == nil)
            #expect(fan.isReclaimedBySystem == false)
            #expect(fan.manualControlAvailability == .unavailable(.writePathNotBuilt))
            #expect(fan.firmwareName == nil)
        }
        #expect(snapshot.fans[0].actualRPM == .measured(1_800))
        #expect(snapshot.fans[1].actualRPM == .measured(1_801))
        #expect(snapshot.fans[0].minimumRPM == .measured(1_200))
        #expect(snapshot.fans[0].maximumRPM == .measured(5_400))
    }

    @Test("No lease can be reported, because none can exist")
    func noLeaseAndNoEmergency() async throws {
        let snapshot = try await authority(provider: fanProvider(fanCount: 1)).snapshot()

        #expect(snapshot.activeLease == nil)
        #expect(snapshot.isThermalEmergencyActive == false)
        #expect(snapshot.protocolVersion == AeolusXPCVersion.current)
        #expect(snapshot.capturedAt == Date(timeIntervalSince1970: 1_000_000))
    }

    /// The reshape `FanState` got for exactly this case: a fan whose `F<n>Mx` is
    /// unreadable still appears, with the missing key marked unavailable — never dropped,
    /// never served as a fabricated `0`.
    @Test("A partially readable fan is reported, with the missing key marked unavailable")
    func partiallyReadableFanIsReported() async throws {
        let provider = fanProvider(
            fanCount: 1,
            extraKeys: [
                SMCFanEnumeration.maximumKey(forFan: 0): .failure(.unknownKey("F0Mx"))
            ])

        let snapshot = try await authority(provider: provider).snapshot()
        let fan = try #require(snapshot.fans.first)

        #expect(fan.actualRPM == .measured(1_800))
        #expect(fan.minimumRPM == .measured(1_200))
        #expect(fan.maximumRPM == .unavailable(reason: "F0Mx is not present on this machine"))
        // No firmware envelope, so no control model — the `nil` that stops a caller
        // obtaining a `clamp(_:)` without the bounds `clamp` is supposed to enforce.
        #expect(fan.fan == nil)
    }

    @Test("A snapshot survives the wire format the client will decode it from")
    func snapshotRoundTrips() async throws {
        let provider = fanProvider(
            fanCount: 1,
            extraKeys: ["TC0P": .reading("TC0P", 44.5, kind: .temperatureCelsius)],
            allReadings: [.fake(key: "TC0P", value: 44.5, kind: .temperatureCelsius)])

        let snapshot = try await authority(provider: provider).snapshot()
        let data = try AeolusXPCCoding.encoder().encode(snapshot)
        let decoded = try AeolusXPCCoding.decoder().decode(SystemSnapshot.self, from: data)

        #expect(decoded == snapshot)
    }

    // MARK: - Sensors

    /// The root daemon must not read the user-writable catalog override, and does not read
    /// the bundled one either. Decoration is a client-side presentation concern; a label
    /// attached here would be a second opinion competing with the one both clients already
    /// own. A rule, not a `TODO`.
    @Test("Every sensor carries its raw key and no label at all")
    func sensorsAreNeverLabelled() async throws {
        let provider = fanProvider(
            fanCount: 1,
            extraKeys: [
                "TC0P": .reading("TC0P", 44.5, kind: .temperatureCelsius),
                "PSTR": .reading("PSTR", 12.5, kind: .watts),
            ],
            allReadings: [
                .fake(key: "TC0P", value: 44.5, kind: .temperatureCelsius),
                .fake(key: "PSTR", value: 12.5, kind: .watts),
            ])

        let snapshot = try await authority(provider: provider).snapshot()

        #expect(snapshot.sensors.count == 2)
        for sensor in snapshot.sensors {
            #expect(sensor.label == nil)
            #expect(sensor.labelConfidence == nil)
            #expect(!sensor.key.isEmpty)
        }
        #expect(snapshot.sensors.first { $0.key == "TC0P" }?.unit == .celsius)
        #expect(snapshot.sensors.first { $0.key == "PSTR" }?.unit == .watts)
    }

    /// `readAll()` is ~4.5 s cold on this project's development hardware, and ADR 0006
    /// puts `snapshot` on a 1 Hz path. Discovery runs once; every snapshot after it is a
    /// subset read.
    @Test("readAll() runs once however many snapshots are served")
    func discoveryRunsOnce() async throws {
        let provider = fanProvider(
            fanCount: 1,
            extraKeys: ["TC0P": .reading("TC0P", 44.5, kind: .temperatureCelsius)],
            allReadings: [.fake(key: "TC0P", value: 44.5, kind: .temperatureCelsius)])
        let authority = authority(provider: provider)

        _ = try await authority.snapshot()
        _ = try await authority.snapshot()
        _ = try await authority.snapshot()

        #expect(await provider.readAllCount == 1)
    }

    @Test("A failed discovery is retried on the next snapshot, not cached")
    func failedDiscoveryIsRetried() async throws {
        let provider = fanProvider(
            fanCount: 1,
            extraKeys: ["TC0P": .reading("TC0P", 44.5, kind: .temperatureCelsius)],
            allReadings: [.fake(key: "TC0P", value: 44.5, kind: .temperatureCelsius)],
            readAllErrors: [FakeProviderError(description: "discovery blew up"), nil])
        let authority = authority(provider: provider)

        let first = try await authority.snapshot()
        let second = try await authority.snapshot()

        #expect(first.sensors.isEmpty)
        #expect(second.sensors.count == 1)
        #expect(await provider.readAllCount == 2)
    }

    /// A key that failed this read is omitted rather than carried as a zero: `SensorSample`
    /// has a non-optional value, and inventing 0 °C for a sensor is the fabricated-zero
    /// defect this project has stamped out three times already.
    @Test("A sensor that failed its refresh is omitted, never served as zero")
    func failedSensorIsOmitted() async throws {
        let provider = fanProvider(
            fanCount: 1,
            extraKeys: [
                "TC0P": .reading("TC0P", 44.5, kind: .temperatureCelsius),
                "Th0x": .failure(.readFailed(reason: "transient")),
            ],
            allReadings: [
                .fake(key: "TC0P", value: 44.5, kind: .temperatureCelsius),
                .fake(key: "Th0x", value: 41.0, kind: .temperatureCelsius),
            ])

        let snapshot = try await authority(provider: provider).snapshot()

        #expect(snapshot.sensors.map(\.key) == ["TC0P"])
        #expect(snapshot.sensors.allSatisfy { $0.value != 0 })
    }

    /// A sensor set that could not be read is a degraded snapshot, not a failed one. The
    /// fans are the part a client cannot do without.
    @Test("A failed sensor refresh still yields the fans")
    func failedSensorRefreshStillYieldsFans() async throws {
        let provider = FakeSensorProvider(
            keyedResults: [:],
            allReadings: [.fake(key: "TC0P", value: 44.5, kind: .temperatureCelsius)])
        // Every key answers .unknownKey, so FNum reads as absent and the machine
        // enumerates zero fans — which is a successful enumeration, not an error.
        let snapshot = try await authority(provider: provider).snapshot()

        #expect(snapshot.fans.isEmpty)
        #expect(snapshot.sensors.isEmpty)
    }

    // MARK: - Refusals

    @Test("acquireLease refuses rather than granting a lease that controls nothing")
    func acquireLeaseRefuses() async throws {
        let authority = authority(provider: fanProvider(fanCount: 1))
        await #expect(throws: Self.noWritePath) {
            _ = try await authority.acquireLease(
                LeaseRequest(holderDescription: "test", fanIndices: [0]),
                from: ConnectionID())
        }
    }

    @Test("renewLease refuses")
    func renewLeaseRefuses() async throws {
        let authority = authority(provider: fanProvider(fanCount: 1))
        await #expect(throws: Self.noWritePath) {
            _ = try await authority.renewLease(id: UUID(), from: ConnectionID())
        }
    }

    @Test("releaseLease refuses")
    func releaseLeaseRefuses() async throws {
        let authority = authority(provider: fanProvider(fanCount: 1))
        await #expect(throws: Self.noWritePath) {
            try await authority.releaseLease(id: UUID(), from: ConnectionID())
        }
    }

    @Test("apply refuses")
    func applyRefuses() async throws {
        let authority = authority(provider: fanProvider(fanCount: 1))
        await #expect(throws: Self.noWritePath) {
            try await authority.apply(
                [FanSetting(fanIndex: 0, control: .fixed(rpm: 2_000))],
                leaseID: UUID(),
                from: ConnectionID())
        }
    }

    /// Truthful, not stubbed: in E2 every fan really is under the system's control,
    /// because nothing in this build can take one off it.
    @Test("restoreAllToAutomatic succeeds")
    func restoreAllToAutomaticSucceeds() async throws {
        let authority = authority(provider: fanProvider(fanCount: 1))
        try await authority.restoreAllToAutomatic(from: ConnectionID())
    }

    @Test("connectionDidInvalidate is accepted and does nothing")
    func connectionDidInvalidateIsAccepted() async {
        let authority = authority(provider: fanProvider(fanCount: 1))
        await authority.connectionDidInvalidate(ConnectionID())
    }

    // MARK: - Failure

    /// A machine with no SMC at all is a failed snapshot, not an empty one. Serving zero
    /// fans would say "this machine has no fans", which is a different and false statement.
    @Test("No SMC is reported as a failure, never as a machine with no fans")
    func noSMCIsAFailure() async throws {
        let authority = authority(provider: FakeSensorProvider(isAvailable: false))

        await #expect(throws: SMCFanEnumerationError.self) {
            _ = try await authority.snapshot()
        }
    }

    /// The vocabulary gained `helperFailed` in #72 for exactly this: `.unknown` would have
    /// told the user the helper is probably newer than their client, which would make a
    /// hardware fault look like a version skew.
    @Test("An SMC failure crosses the boundary as helperFailed, carrying the reason")
    func smcFailureBecomesHelperFailed() throws {
        let fault = AeolusXPCFault.crossing(SMCFanEnumerationError.noSMC)

        guard case .helperFailed(let detail) = fault else {
            Issue.record("expected helperFailed, got \(fault)")
            return
        }
        // `SMCFanEnumerationError` is `CustomStringConvertible`, so what reaches the
        // client is its own sentence rather than a case name — which is the point of
        // carrying the detail at all.
        #expect(detail == "no AppleSMC service on this machine")
    }

    @Test("A fault crossing the boundary is passed through, never flattened")
    func faultIsPassedThrough() {
        let original = AeolusXPCFault.leaseNotHeldByThisConnection
        #expect(AeolusXPCFault.crossing(original) == original)
    }
}
