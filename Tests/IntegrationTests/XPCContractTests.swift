import FanKit
import Foundation
import ObjectiveC
import Testing

@testable import AeolusXPC

/// Contract tests for the privilege boundary.
///
/// The substantive integration suite — lease expiry, thermal override, and reclamation
/// against a mock SMC — is E5's deliverable and gates the write path. What is here now
/// covers the wire format and the shape of the protocol itself, which everything else is
/// built on.
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
                    isReclaimedBySystem: false,
                    manualControlAvailability: .available
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

    /// E2's own answer for every fan: the boundary exists, the thing behind it does not,
    /// and the snapshot says so rather than offering control that would go nowhere.
    @Test("A snapshot can report that no fan is controllable at all")
    func snapshotCanReportNoWritePath() throws {
        let snapshot = SystemSnapshot(
            fans: [
                FanState(
                    fan: Fan(index: 0, minimumRPM: 1200, maximumRPM: 5400, firmwareName: nil),
                    actualRPM: 1800,
                    targetRPM: nil,
                    mode: .automatic,
                    isReclaimedBySystem: false,
                    manualControlAvailability: .unavailable(.writePathNotBuilt)
                )
            ],
            sensors: [],
            activeLease: nil,
            isThermalEmergencyActive: false,
            capturedAt: Date(timeIntervalSince1970: 1_000_000)
        )

        let data = try AeolusXPCCoding.encoder().encode(snapshot)
        let decoded = try AeolusXPCCoding.decoder().decode(SystemSnapshot.self, from: data)

        #expect(decoded.fans[0].manualControlAvailability == .unavailable(.writePathNotBuilt))
        #expect(decoded.activeLease == nil)
    }

    /// A stale client against a newer helper must fail loudly, not degrade silently.
    @Test("Version negotiation rejects versions outside the supported range")
    func rejectsIncompatibleVersions() {
        #expect(AeolusXPCVersion.isCompatible(clientVersion: AeolusXPCVersion.current))
        #expect(AeolusXPCVersion.isCompatible(clientVersion: AeolusXPCVersion.current + 1) == false)
        #expect(AeolusXPCVersion.isCompatible(clientVersion: 0) == false)
    }

    @Test("The advertised range matches the constants the helper was built with")
    func advertisedRangeMatchesConstants() {
        #expect(
            AeolusXPCVersion.supportedRange.minimumSupported == AeolusXPCVersion.minimumSupported)
        #expect(AeolusXPCVersion.supportedRange.current == AeolusXPCVersion.current)
        #expect(AeolusXPCVersion.supportedRange.isWellFormed)
    }

    @Test("A version range accepts its own endpoints and nothing beyond them")
    func rangeAcceptsEndpoints() {
        let range = ProtocolVersionRange(minimumSupported: 2, current: 4)
        #expect(range.accepts(clientVersion: 2))
        #expect(range.accepts(clientVersion: 3))
        #expect(range.accepts(clientVersion: 4))
        #expect(range.accepts(clientVersion: 1) == false)
        #expect(range.accepts(clientVersion: 5) == false)
    }

    /// A range that makes no sense means the peer or the wire is not what this code
    /// thinks it is, and "I do not understand you" reads as silence, not as agreement.
    ///
    /// This asserts the behaviour, not the guard inside `accepts`: deleting that guard
    /// leaves this test passing, because an inverted range already satisfies neither
    /// bound. Said plainly here so nobody later reads a green suite as evidence the
    /// guard is load-bearing — see the comment on `accepts` for why it stays anyway.
    @Test("An inverted version range accepts nothing at all")
    func invertedRangeAcceptsNothing() {
        let inverted = ProtocolVersionRange(minimumSupported: 4, current: 2)
        #expect(inverted.isWellFormed == false)
        for version in -1...6 {
            #expect(inverted.accepts(clientVersion: version) == false)
        }
    }

    @Test("A version range survives a round trip as named fields")
    func rangeRoundTrips() throws {
        let range = ProtocolVersionRange(minimumSupported: 1, current: 3)
        let data = try AeolusXPCCoding.encoder().encode(range)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("minimumSupported"))
        #expect(json.contains("current"))
        #expect(
            try AeolusXPCCoding.decoder().decode(ProtocolVersionRange.self, from: data) == range)
    }

    @Test("The handshake DTOs survive a round trip")
    func handshakeRoundTrips() throws {
        let request = HelloRequest(clientProtocolVersion: 1, clientDescription: "fanctl 0.1.0")
        let reply = HelloReply(
            helperProtocolRange: AeolusXPCVersion.supportedRange,
            helperBuild: "0.1.0 (debug)",
            capabilities: ["snapshot.sensors"]
        )

        let encoder = AeolusXPCCoding.encoder()
        let decoder = AeolusXPCCoding.decoder()
        #expect(try decoder.decode(HelloRequest.self, from: encoder.encode(request)) == request)
        #expect(try decoder.decode(HelloReply.self, from: encoder.encode(reply)) == reply)
    }

    @Test("Capability lookup answers only about capabilities the helper advertised")
    func capabilityLookup() {
        let reply = HelloReply(
            helperProtocolRange: AeolusXPCVersion.supportedRange,
            helperBuild: "0.1.0",
            capabilities: ["snapshot.sensors"]
        )
        #expect(reply.advertises("snapshot.sensors"))
        #expect(reply.advertises("fan.write") == false)
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

    // MARK: - The shape of the protocol itself

    private func selectorNames(required: Bool) -> Set<String> {
        let proto: Protocol = AeolusXPCProtocol.self
        var count: UInt32 = 0
        guard
            let descriptions = protocol_copyMethodDescriptionList(
                proto,
                required,
                true,
                &count
            )
        else { return [] }
        defer { free(descriptions) }
        var names: Set<String> = []
        for index in 0..<Int(count) {
            guard let selector = descriptions[index].name else { continue }
            names.insert(NSStringFromSelector(selector))
        }
        return names
    }

    /// `CLAUDE.md` rule 5 says a message that defeats a safety mechanism may never be
    /// *added*. That makes its absence a property of the design, and a property is
    /// testable: this asserts the exact set of messages the boundary carries, so adding
    /// one — a generic key write, an "advanced mode", a ceiling override — fails here
    /// before anyone has to notice it in review.
    @Test("The protocol declares exactly the messages the boundary is allowed to carry")
    func protocolDeclaresExactlyTheAllowedMessages() {
        let names = selectorNames(required: true)
        #expect(names.count == 7, "the boundary grew or lost a message: \(names.sorted())")

        let expected = [
            "hello",
            "snapshot",
            "acquireLease",
            "renewLease",
            "releaseLease",
            "apply",
            "restoreAllToAutomatic",
        ]
        for message in expected {
            #expect(
                names.contains { $0.hasPrefix(message) },
                "the boundary no longer declares \(message)"
            )
        }
    }

    /// A generic "write key K with bytes B" would make the helper a root SMC proxy and
    /// reduce every safety mechanism below it to decoration. It does not exist, and
    /// neither does anything that widens bounds or waives a limit.
    @Test("No message on the boundary is write-shaped or limit-waiving")
    func noWriteShapedMessageExists() {
        let forbidden = [
            "write", "poke", "rawkey", "smckey", "setkey", "writekey",
            "unlock", "bypass", "disable", "override", "ceiling", "advanced",
            "force", "unsafe", "unclamp",
        ]
        for name in selectorNames(required: true) {
            let lowered = name.lowercased()
            for fragment in forbidden {
                #expect(
                    !lowered.contains(fragment),
                    "\(name) looks like a \(fragment)-shaped message on the privilege boundary"
                )
            }
        }
    }

    /// An optional method would mean "a helper may or may not implement this", which on
    /// a privilege boundary means a client cannot know what it is talking to.
    @Test("The protocol has no optional methods")
    func protocolHasNoOptionalMethods() {
        #expect(selectorNames(required: false).isEmpty)
    }
}
