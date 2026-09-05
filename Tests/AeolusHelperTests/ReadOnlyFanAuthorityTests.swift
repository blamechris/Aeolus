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

    private func authority(
        provider: some SensorProvider,
        thermalEmergency: ThermalEmergencyLatch = ThermalEmergencyLatch(),
        reclamation: ReclamationLedger = ReclamationLedger()
    ) -> ReadOnlyFanAuthority {
        ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider),
            log: Self.log,
            thermalEmergency: thermalEmergency,
            reclamation: reclamation,
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
        // obtaining a `FanControlEnvelope` without the bounds a clamp is supposed to enforce.
        #expect(fan.fan == nil)
    }

    /// Clamping governs targets, never observations — asserted at the **producer**, because
    /// asserting it on a `FanState` literal cannot fail.
    ///
    /// `F0Ac` was measured at **1343.07 against a declared `F0Mn` of 1350** on this
    /// project's own machine, so a reading below the declared minimum is a legitimate
    /// observation and not a fault. The version of this claim that lived in
    /// `FanClampTests` built a `FanState` by hand and round-tripped it through JSON: every
    /// type between the construction and the assertion is a pure carrier with no clamping
    /// code in it, so the assertion could not fail for the reason in its title. Adding a
    /// "correct the reading up to the declared minimum" floor to `readFans` left the whole
    /// suite green.
    ///
    /// This drives the real producer with a reading below the real minimum, so that floor
    /// now turns it red.
    @Test("A reading below the declared minimum reaches the client uncorrected")
    func readingBelowDeclaredMinimumIsNotFloored() async throws {
        let provider = fanProvider(
            fanCount: 1,
            extraKeys: [
                SMCFanEnumeration.actualKey(forFan: 0): .reading(
                    SMCFanEnumeration.actualKey(forFan: 0), 1_343.07),
                SMCFanEnumeration.minimumKey(forFan: 0): .reading(
                    SMCFanEnumeration.minimumKey(forFan: 0), 1_350),
            ])

        let snapshot = try await authority(provider: provider).snapshot()
        let fan = try #require(snapshot.fans.first)

        #expect(fan.actualRPM == .measured(1_343.07))
        #expect(fan.minimumRPM == .measured(1_350))
        // Stated as the relationship rather than the number, so the test still means what
        // it says if the fixture changes: the observation is below the floor and stays there.
        let actual = try #require(fan.actualRPM.value)
        let minimum = try #require(fan.minimumRPM.value)
        #expect(actual < minimum)
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

    /// Two assertions, and **the encode is the point** — the omission is only how it is
    /// achieved.
    ///
    /// That a non-finite sample is absent from `sensors` is the mild half. The half worth a
    /// test is that the snapshot still *encodes*: `AeolusXPCCoding.encoder()` is a bare
    /// `JSONEncoder`, so `nonConformingFloatEncodingStrategy` is `.throw`, and one
    /// `±.infinity` or `.nan` reaching `SensorSample.value` makes `PayloadReply.encoding`
    /// throw. The key set is discovered once and cached, so that is not one bad snapshot —
    /// it is every snapshot until the process exits, and it takes 2928 healthy sensors and
    /// both fans with it.
    ///
    /// Reachable on real hardware, not contrived: `SMCValue.scalar()` applies no finiteness
    /// guard, and `SMCFanEnumeration.checked` exists because a byte-swapped `flt` decodes to
    /// exactly this on an otherwise-successful read. The families where the resolver is
    /// least proven are Intel and M1/M2 — the two shipped `untested`.
    @Test("A non-finite sensor is omitted, and the snapshot it would have poisoned encodes")
    func nonFiniteSensorIsOmittedAndTheSnapshotStillEncodes() async throws {
        let provider = fanProvider(
            fanCount: 1,
            extraKeys: [
                "TC0P": .reading("TC0P", 44.5, kind: .temperatureCelsius),
                "Th0x": .reading("Th0x", .infinity, kind: .temperatureCelsius),
                "Th0y": .reading("Th0y", -.infinity, kind: .temperatureCelsius),
                "Th0z": .reading("Th0z", .nan, kind: .temperatureCelsius),
            ],
            allReadings: [
                .fake(key: "TC0P", value: 44.5, kind: .temperatureCelsius),
                .fake(key: "Th0x", value: .infinity, kind: .temperatureCelsius),
                .fake(key: "Th0y", value: -.infinity, kind: .temperatureCelsius),
                .fake(key: "Th0z", value: .nan, kind: .temperatureCelsius),
            ])

        let snapshot = try await authority(provider: provider).snapshot()

        #expect(snapshot.sensors.map(\.key) == ["TC0P"])
        #expect(snapshot.sensors.allSatisfy { $0.value.isFinite })

        // The assertion this test exists for.
        let data = try AeolusXPCCoding.encoder().encode(snapshot)
        let decoded = try AeolusXPCCoding.decoder().decode(SystemSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(!snapshot.fans.isEmpty, "the fans one bad sensor key would have taken with it")
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
