import FanKit
import Foundation
import Testing

@testable import AeolusXPC

/// Contract tests for the privilege boundary.
///
/// The substantive integration suite — lease expiry, thermal override, and reclamation
/// against a mock SMC — is E5's deliverable and gates the write path. What is here now
/// covers the wire format, which everything else is built on.
@Suite("XPC contract")
struct XPCContractTests {

    @Test("A snapshot survives a round trip through the wire format")
    func snapshotRoundTrips() throws {
        let snapshot = SystemSnapshot(
            fans: [
                FanState(
                    fan: Fan(index: 0, minimumRPM: 1200, maximumRPM: 5400, firmwareName: nil),
                    actualRPM: 1800,
                    targetRPM: 2000,
                    mode: .manualFixed,
                    isReclaimedBySystem: false
                )
            ],
            sensors: [
                SensorSample(
                    key: "Tp09",
                    label: "CPU Efficiency Core Cluster",
                    labelConfidence: .community,
                    value: 48.5,
                    unit: .celsius
                )
            ],
            activeLease: Lease(
                holderDescription: "fanctl",
                expiresAt: Date(timeIntervalSince1970: 1_000_030)
            ),
            isThermalEmergencyActive: false,
            capturedAt: Date(timeIntervalSince1970: 1_000_000)
        )

        let data = try AeolusXPCCoding.encoder().encode(snapshot)
        let decoded = try AeolusXPCCoding.decoder().decode(SystemSnapshot.self, from: data)

        #expect(decoded == snapshot)
    }

    /// A stale client against a newer helper must fail loudly, not degrade silently.
    @Test("Version negotiation rejects versions outside the supported range")
    func rejectsIncompatibleVersions() {
        #expect(AeolusXPCVersion.isCompatible(clientVersion: AeolusXPCVersion.current))
        #expect(AeolusXPCVersion.isCompatible(clientVersion: AeolusXPCVersion.current + 1) == false)
        #expect(AeolusXPCVersion.isCompatible(clientVersion: 0) == false)
    }

    /// The raw key is the one field the UI can always fall back on, so it must never be
    /// optional on the wire even when the catalog has nothing to say about it.
    @Test("An unlabelled sensor still carries its raw key")
    func unlabelledSensorKeepsKey() throws {
        let sample = SensorSample(
            key: "Th0x",
            label: nil,
            labelConfidence: nil,
            value: 41.0,
            unit: .celsius
        )

        let data = try AeolusXPCCoding.encoder().encode(sample)
        let decoded = try AeolusXPCCoding.decoder().decode(SensorSample.self, from: data)

        #expect(decoded.key == "Th0x")
        #expect(decoded.label == nil)
    }
}
