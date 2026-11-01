import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// What § 2's grant-time bounds gate costs and when it is not asked
/// ([#270](https://github.com/blamechris/Aeolus/issues/270)).
///
/// Against the lease core alone, through `LeaseFixture.authority`, with the gate's reads counted
/// by `ParkableEnvelopeReading` over the real scripted firmware. `GrantBoundsAgreementTests`
/// holds the gate's place in the ladder's order; this suite holds its price: no read on a build
/// that cannot write or on a machine that cannot see, none for a fan Aeolus is accountable for,
/// and one, in order, for every other requested fan. And it holds the one error that is not a
/// statement about the bounds.
@Suite("The grant's bounds gate reads only what it must", .timeLimit(.minutes(1)))
struct GrantBoundsGateTests {

    /// The reason a grant over `fans` is refused, or `nil` when it is granted.
    private static func refusal(
        over fans: [Int], from leases: LeaseAuthority
    ) async -> ManualControlAvailability.Reason? {
        do {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: fans), from: ConnectionID())
            return nil
        } catch AeolusXPCFault.manualControlUnavailable(let reason) {
            return reason
        } catch {
            Issue.record("the grant failed with \(error), not a manual-control refusal")
            return .unknown(String(describing: error))
        }
    }

    // MARK: - No read where a cheaper refusal applies

    /// A build that cannot write, and a machine that cannot see, are refused without a single
    /// bounds read: both refusals are asked first, and both answer for every fan at once.
    ///
    /// **Mutation:** in `LeaseAuthority.acquireLease`, move the bounds gate above the blindness
    /// check, as `let wanting = …` and `try await refuseIfBoundsImplausible(connection, wanting:
    /// wanting.subtracting(fansAeolusIsAccountableFor))` before `try await
    /// refuseIfBlind(connection)`. Run: red on the blind case — one read, of fan 0.
    @Test("No bounds read on a build that cannot write or a machine that cannot see")
    func noReadBeforeACheaperRefusal() async throws {
        let unbuilt = ParkableEnvelopeReading()
        #expect(
            await Self.refusal(
                over: [0],
                from: LeaseFixture.authority(
                    writeCapability: LeaseFixture.writePathNotBuilt(), envelopes: unbuilt))
                == .writePathNotBuilt)
        #expect(await unbuilt.requests.isEmpty, "a build that cannot write read fan 0's bounds")

        let blind = ParkableEnvelopeReading()
        #expect(
            await Self.refusal(
                over: [0],
                from: LeaseFixture.authority(
                    telemetry: LeaseFixture.blindTelemetry(), envelopes: blind))
                == .noThermalTelemetry)
        #expect(
            await blind.requests.isEmpty,
            "a machine that cannot see spent a .supervisor turn per fan on bounds first")
    }

    /// A fan Aeolus is accountable for is never read: another client's lease answers for it, as
    /// it does in the snapshot.
    ///
    /// **Mutation:** in `LeaseAuthority.acquireLease`, pass `wanting` to
    /// `refuseIfBoundsImplausible(_:wanting:)` without `.subtracting(exempted)`. Run: red — fan 0
    /// read twice.
    @Test("A fan Aeolus is accountable for costs no bounds read")
    func anAccountableFanIsNotRead() async throws {
        let reads = ParkableEnvelopeReading()
        let leases = LeaseFixture.authority(envelopes: reads)
        _ = try await leases.acquireLease(LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(await reads.requests == [0], "the first grant did not read fan 0's bounds")

        #expect(await Self.refusal(over: [0], from: leases) == .leaseHeldByAnotherClient)
        #expect(
            await reads.requests == [0],
            "a fan under another client's lease was read, which the table already answers")
    }

    /// Every requested fan Aeolus is not accountable for is read exactly once, in index order.
    ///
    /// **Mutation:** in `LeaseAuthority.acquireLease`, delete the bounds gate's call. Run: red —
    /// no read at all.
    @Test("One bounds read per requested fan Aeolus is not accountable for, in order")
    func oneReadPerRequestedFan() async throws {
        let reads = ParkableEnvelopeReading()
        let leases = LeaseFixture.authority(
            enumeration: ScriptedFanEnumeration(indices: [0, 1]), envelopes: reads)

        #expect(await Self.refusal(over: [1, 0], from: leases) == nil)
        #expect(await reads.requests == [0, 1])
    }

    // MARK: - Cancellation is not a statement about the bounds

    /// A grant cancelled while its bounds read is parked ends in `CancellationError`, not in
    /// `.boundsImplausible`: a caller that went away says nothing about the firmware.
    ///
    /// The refusal's log line is written only on the refusal's path, so a cancellation that
    /// reaches the caller as itself wrote none. `LeaseLog` has had a recording seam since #560;
    /// this test predates it, and the fault is still the assertion.
    ///
    /// **Mutation:** delete the `catch let cancellation as CancellationError` clause from
    /// `refuseIfBoundsImplausible(_:wanting:)`. Run: red — `.boundsImplausible` thrown.
    @Test("A grant cancelled during its bounds read ends in CancellationError")
    func cancellationIsNotImplausibility() async throws {
        let reads = ParkableEnvelopeReading()
        await reads.park()
        let leases = LeaseFixture.authority(envelopes: reads)

        let grant = observing {
            try await leases.acquireLease(LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        await yieldUntil("the grant to park on fan 0's bounds") { await reads.parked == 1 }
        grant.task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await grant.task.value }
        #expect(await leases.leaseCount == 0)
    }
}

/// `FanEnvelopeReading` over the real scripted firmware, recording every request and parking
/// reads on demand (#270).
///
/// A read parks on an `AsyncSignal` — a continuation, never a blocked thread — and the signal is
/// cancellation-aware, so a cancelled grant parked here resumes with `CancellationError`. That is
/// a conformer's choice, not the production plane's: `SMCReadScheduler`'s wait is deliberately not
/// cancellable and `SMCFanControlPlane.readSubset` names every failure `.readFailed`, so the gate's
/// carve-out is defensive there. Each request is recorded before it parks, so "no read was asked
/// for" is a statement about calls made.
actor ParkableEnvelopeReading: FanEnvelopeReading {

    private let firmware: ScriptedControlPlane
    private var gate: AsyncSignal?

    /// Every fan whose bounds were asked for, in order.
    private(set) var requests: [Int] = []

    /// Reads parked right now.
    private(set) var parked = 0

    /// Over eight plausible fans by default — `LeaseFixture.plausibleEnvelopes()`'s machine.
    init(
        over firmware: ScriptedControlPlane = ScriptedControlPlane(
            fans: Dictionary(
                uniqueKeysWithValues: (0..<8).map { ($0, ScriptedControlPlane.FanCondition()) }),
            stages: [.nominal()])
    ) {
        self.firmware = firmware
    }

    /// Parks every read from now until `release()`.
    func park() {
        gate = AsyncSignal()
    }

    /// Lets every parked read through, and stops parking the ones that follow.
    func release() async {
        let parkedOn = gate
        gate = nil
        await parkedOn?.signal()
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        requests.append(index)
        if let gate {
            parked += 1
            defer { parked -= 1 }
            try await gate.wait()
        }
        return try await firmware.readEnvelope(ofFan: index)
    }
}
