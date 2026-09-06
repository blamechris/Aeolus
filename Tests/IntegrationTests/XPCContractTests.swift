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
                    index: 0,
                    actualRPM: .measured(1800),
                    minimumRPM: .measured(1200),
                    maximumRPM: .measured(5400),
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
                    index: 0,
                    actualRPM: .measured(1800),
                    minimumRPM: .measured(1200),
                    maximumRPM: .measured(5400),
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

    /// Every message the boundary carries, spelled the way the Objective-C runtime spells
    /// it.
    ///
    /// Full selectors, not Swift base names, because the base name is not the message:
    /// `apply(settings:leaseID:reply:)` and `apply(settings:leaseID:ignoringLimits:reply:)`
    /// share a base name and are different messages, and only the selector tells them
    /// apart.
    ///
    /// Not `private`: `XPCDeclarationFingerprintTests` derives selectors from its own
    /// source-level pin and asserts they are exactly this set, so the two guards cannot
    /// drift into describing different boundaries. Referring to the one pin is the point —
    /// a second copy here would be a third thing to keep in step.
    static let allowedSelectors: Set<String> = [
        "acquireLeaseWithRequest:reply:",
        "applyWithSettings:leaseID:reply:",
        "helloWithRequest:reply:",
        "releaseLeaseWithId:reply:",
        "renewLeaseWithId:reply:",
        "restoreAllToAutomaticWithReply:",
        "snapshotWithReply:",
    ]

    /// The selectors in one of the runtime's four method quadrants.
    ///
    /// `protocol_copyMethodDescriptionList` reports exactly one quadrant per call —
    /// required or optional, crossed with instance or class — so a helper that hardcodes
    /// either flag is a guard with doors left open behind it. Both are parameters here,
    /// and every quadrant is looked at.
    private func selectorNames(required: Bool, instance: Bool) -> Set<String> {
        let proto: Protocol = AeolusXPCProtocol.self
        var count: UInt32 = 0
        guard
            let descriptions = protocol_copyMethodDescriptionList(
                proto,
                required,
                instance,
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

    /// Everything this protocol declares *directly*, however it was declared: all four
    /// quadrants unioned, so nothing hides in the one a narrower query never asks about.
    ///
    /// Directly is a real limit, not a hedge. `protocol_copyMethodDescriptionList` reports
    /// only the methods declared on the protocol object it is handed, and does not walk
    /// `protocol_copyProtocolList`. A message inherited from an adopted protocol is
    /// therefore absent from all four quadrants while still crossing the wire, so
    /// inheritance is refused separately — see `protocolInheritsNothing`.
    private func allSelectorNames() -> Set<String> {
        var names: Set<String> = []
        for required in [true, false] {
            for instance in [true, false] {
                names.formUnion(selectorNames(required: required, instance: instance))
            }
        }
        return names
    }

    /// The protocols this one adopts, by name. Required to be none — `protocolInheritsNothing`
    /// says why.
    ///
    /// The runtime returns `NULL` with a zero count when a protocol adopts nothing, which is
    /// the expected case here; when it does not, the array is the caller's to `free`.
    private func inheritedProtocolNames() -> [String] {
        let proto: Protocol = AeolusXPCProtocol.self
        var count: UInt32 = 0
        guard let adopted = protocol_copyProtocolList(proto, &count) else { return [] }
        defer { free(UnsafeMutableRawPointer(adopted)) }
        return (0..<Int(count)).map { NSStringFromProtocol(adopted[$0]) }
    }

    /// `CLAUDE.md` rule 5 says a message that defeats a safety mechanism may never be
    /// *added*. That makes its absence a property of the design, and a property is
    /// testable.
    ///
    /// **This is the guard — together with `protocolInheritsNothing`, which it depends on.**
    /// It is set equality against the full selectors of every method declared *directly* on
    /// this protocol, over every quadrant, which is what makes it hold: it fails on a message
    /// added — a generic key write, an "advanced mode", a ceiling override — and equally on
    /// one removed, renamed, moved to a class method, made optional, or re-parameterised.
    /// That last case is why the count-plus-prefix pair this replaced was not enough: giving
    /// `apply` an `ignoringLimits:` argument leaves the count at seven and the base name
    /// intact while changing what the boundary can be asked to do.
    ///
    /// What it cannot see by itself is a message the protocol *inherits*, because nothing it
    /// calls walks the adopted-protocol list. That half of the property is held below, by
    /// asserting there is no adopted-protocol list to walk.
    @Test("The protocol declares exactly the messages the boundary is allowed to carry")
    func protocolDeclaresExactlyTheAllowedMessages() {
        let declared = allSelectorNames()
        #expect(
            declared == Self.allowedSelectors,
            """
            the boundary's message set changed: \
            added \(declared.subtracting(Self.allowedSelectors).sorted()), \
            removed \(Self.allowedSelectors.subtracting(declared).sorted())
            """
        )
    }

    /// The guard above enumerates only what `AeolusXPCProtocol` declares itself, and an
    /// inherited message is both absent from that enumeration and on the wire regardless:
    /// `NSXPCInterface(with:)` vends an adopted protocol's selectors exactly like the
    /// protocol's own, and a helper serving that interface answers them. Writing
    /// `AeolusXPCProtocol: SomeOtherProtocol` would add messages to the privilege boundary
    /// while leaving every selector assertion in this file green — which is why the quadrant
    /// pair is the wrong axis on its own. A message does not have to hide in a quadrant a
    /// query forgets to ask about; it can sit in a different protocol object entirely.
    ///
    /// Refusing inheritance outright closes that, and is the stricter of the two available
    /// fixes. Unioning the adopted protocols' selectors into `allSelectorNames` would also
    /// make the guard honest, but it would leave the boundary free to acquire a supertype
    /// silently. This way it cannot acquire one without someone editing this test on
    /// purpose, which is the review that rule 5 actually wants.
    @Test("The boundary protocol inherits no other protocol")
    func protocolInheritsNothing() {
        let adopted = inheritedProtocolNames().sorted()
        #expect(
            adopted.isEmpty,
            """
            the boundary now adopts \(adopted): an inherited message crosses the wire like a \
            declared one, but `protocol_copyMethodDescriptionList` never reports it, so the \
            exact-set guard above cannot see it. Drop the inheritance, or union the adopted \
            protocols' selectors into `allSelectorNames` before relaxing this.
            """
        )
    }

    /// Required instance methods are the only quadrant this contract uses, and the other
    /// three are asserted empty rather than assumed so.
    ///
    /// An optional method would mean "a helper may or may not implement this", which on a
    /// privilege boundary means a client cannot know what it is talking to. A class method
    /// would be a message that never appears in an instance-method query at all — which is
    /// how a message hides from a guard that reads one quadrant and calls it the protocol.
    @Test("The protocol declares nothing outside the required-instance quadrant")
    func protocolUsesOnlyTheRequiredInstanceQuadrant() {
        #expect(selectorNames(required: true, instance: true) == Self.allowedSelectors)
        #expect(selectorNames(required: true, instance: false).isEmpty, "a class method appeared")
        #expect(
            selectorNames(required: false, instance: true).isEmpty,
            "an optional method appeared"
        )
        #expect(selectorNames(required: false, instance: false).isEmpty)
    }

    /// A generic "write key K with bytes B" would make the helper a root SMC proxy and
    /// reduce every safety mechanism below it to decoration. It does not exist, and
    /// neither does anything that widens bounds or waives a limit.
    ///
    /// **A readability tripwire, not the guard.** The exact-set test above is what holds
    /// the line, and it does so whatever a new message is called. This one only catches an
    /// offender that names itself — a `writeKey`, an `enableAdvancedMode` — and nothing
    /// obliges a careless addition to do that: `apply(settings:leaseID:ignoringLimits:)`
    /// matches no fragment here. It stays because the list names the shapes this boundary
    /// has decided it will never have, so a reviewer whose diff trips it learns why in one
    /// word. It must never be read as sufficient on its own.
    @Test("No message on the boundary is write-shaped or limit-waiving")
    func noWriteShapedMessageExists() {
        let forbidden = [
            "write", "poke", "rawkey", "smckey", "setkey", "writekey",
            "unlock", "bypass", "disable", "override", "ceiling", "advanced",
            "force", "unsafe", "unclamp",
        ]
        for name in allSelectorNames() {
            let lowered = name.lowercased()
            for fragment in forbidden {
                #expect(
                    !lowered.contains(fragment),
                    "\(name) looks like a \(fragment)-shaped message on the privilege boundary"
                )
            }
        }
    }
}
