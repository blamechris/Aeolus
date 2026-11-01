import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// #670's (a) at the grant: a lease is granted only over every fan the machine enumerated, until
/// run 1d records ADR 0014's U7 as observed holding. A request that leaves a fan out is refused
/// `.leaseMustCoverEveryFan`, a reason of its own, because the request can never be granted
/// whatever the machine says, and no other reason says that.
///
/// The machine has two fans here, as `Mac16,5` does, so a request for one of them is the narrow
/// request a per-fan client would send.
@Suite("A lease covers every fan or none (#670)", .timeLimit(.minutes(1)))
struct EveryFanLeaseTests {

    static let narrow = AeolusXPCFault.manualControlUnavailable(reason: .leaseMustCoverEveryFan)

    /// A lease core over two fans, its lines recorded.
    static func authority(
        recordingInto lines: RecordedLeaseLines = RecordedLeaseLines(),
        restorer: any FanRestoring = RecordingFanRestorer(),
        telemetry: any SightednessProving = LeaseFixture.sightedTelemetry(),
        envelopes: any FanEnvelopeReading = LeaseFixture.plausibleEnvelopes(),
        thermalEmergency: ThermalEmergencyLatch = ThermalEmergencyLatch(),
        clock: TestClock = TestClock()
    ) -> LeaseAuthority {
        LeaseFixture.authority(
            enumeration: ScriptedFanEnumeration(indices: [0, 1]), restorer: restorer,
            telemetry: telemetry, envelopes: envelopes, thermalEmergency: thermalEmergency,
            clock: clock,
            log: LeaseLog(
                subsystem: "dev.aeolus.AeolusHelperTests", category: "Lease",
                recording: { lines.append($0, $1) }))
    }

    /// Either fan alone is refused with the new reason, nothing is granted, and the refusal is
    /// logged at `notice`, naming the fan left out.
    ///
    /// **Mutation:** delete the `guard missing.isEmpty` block from `LeaseAuthority.acquireLease`.
    /// Run: red on both arguments, a lease granted over one fan of two.
    @Test("A request that leaves a fan out is refused, and nothing is granted", arguments: [0, 1])
    func aNarrowRequestIsRefused(fan: Int) async throws {
        let lines = RecordedLeaseLines()
        let authority = Self.authority(recordingInto: lines)

        await #expect(throws: Self.narrow) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [fan]), from: ConnectionID())
        }

        #expect(await authority.leaseCount == 0, "a lease over fan \(fan) alone was granted")
        let left = 1 - fan
        #expect(
            lines.levels(containing: "without fan(s) \(left). Refused") == [.notice],
            "\(lines.lines.map(\.text))")
    }

    /// The same machine grants a request over both fans, so the refusal above is about the
    /// request's shape and not about the machine.
    @Test("A request over every fan is granted")
    func anEveryFanRequestIsGranted() async throws {
        let authority = Self.authority()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [1, 0]), from: ConnectionID())

        let view = await authority.activeLeaseView()
        #expect(view.lease?.id == lease.id)
        #expect(view.leasedFans == [0, 1])
    }

    /// The most durable refusal after the build's, and free, so it is answered before § 3's latch
    /// and the blindness proof, and before any bounds read: a narrow request on a hot, blind
    /// machine is told the one thing a retry can never change, and costs no read.
    ///
    /// **Mutation:** move the guard below `try await refuseIfBlind(connection)`. Run: red, the
    /// blind machine's request answered `.noThermalTelemetry`. **Mutation:** move it below
    /// `refuseIfThermalEmergencyActive`. Run: red, the hot machine's answered
    /// `.thermalEmergencyActive`.
    @Test("The refusal comes before § 3's latch, the blindness proof and any bounds read")
    func theRefusalComesFirst() async throws {
        let reads = ParkableEnvelopeReading()
        let blind = Self.authority(telemetry: LeaseFixture.blindTelemetry(), envelopes: reads)
        await #expect(throws: Self.narrow) {
            _ = try await blind.acquireLease(LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        #expect(await reads.requests.isEmpty, "a request that cannot be granted read bounds")

        let latch = ThermalEmergencyLatch()
        await latch.engage(
            by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99), answering: [smcKey("Tp01")])
        let hot = Self.authority(thermalEmergency: latch)
        await #expect(throws: Self.narrow) {
            _ = try await hot.acquireLease(LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    /// After the sweep, deliberately: a lapsed lease's fans go back to automatic control whatever
    /// the request that triggered the sweep asked for.
    ///
    /// **Mutation:** move the guard above `await expireLapsedLeases()`. Run: red, the lapsed
    /// lease left in the table and nothing restored.
    @Test("A refused narrow request still sweeps a lapsed lease")
    func aRefusedNarrowRequestStillSweeps() async throws {
        let clock = TestClock()
        let restorer = RecordingFanRestorer()
        let authority = Self.authority(restorer: restorer, clock: clock)
        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0, 1], timeToLive: 30), from: ConnectionID())
        clock.advance(by: .seconds(30))

        await #expect(throws: Self.narrow) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }

        #expect(await authority.leaseCount == 0)
        #expect(await restorer.restores == [.init(fans: [0, 1], cause: .leaseExpired)])
    }

    /// Every fan and one the machine does not have is a request for a fan that does not exist,
    /// and `validateFanIndices` says so: the new reason is for a fan left out, not one added.
    @Test("Every fan and one more is refused as a fan the machine lacks")
    func everyFanAndOneMoreIsAFanTheMachineLacks() async throws {
        let authority = Self.authority()

        let refusal = await #expect(throws: AeolusXPCFault.self) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [0, 1, 7]), from: ConnectionID())
        }
        guard case .invalidParameter(let name, _)? = refusal else {
            Issue.record("refused \(String(describing: refusal)), not as a fan the machine lacks")
            return
        }
        #expect(name == "fanIndices")
        #expect(await authority.leaseCount == 0)
    }
}
