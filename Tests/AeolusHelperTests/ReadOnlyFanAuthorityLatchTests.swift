import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The questions about this type that are not "what does E2 refuse".
///
/// Its own suite because the suite above is at SwiftLint's `type_body_length` limit, and
/// because these are about a field's *provenance* rather than about the read-only contract.
/// Both fields here have the same history: a literal in the initialiser with a comment
/// explaining why it was true, and nothing that would notice it becoming false.
@Suite("ReadOnlyFanAuthority and the safety mechanisms it reports")
struct ReadOnlyFanAuthorityLatchTests {

    /// `isThermalEmergencyActive` is read from § 3's latch, not written as a literal.
    ///
    /// Until #125 the field was `false` in the initialiser with a comment explaining that
    /// E2 has no thermal supervisor — a claim that was true and that nothing would have
    /// noticed becoming false. Engage the latch and the snapshot says so; replace the read
    /// with `false` again and this goes red.
    ///
    /// The build still cannot reach this state on real hardware, because every path that
    /// would grant a lease refuses. What is asserted is the *sourcing*.
    @Test("A latched thermal emergency is reported on the snapshot")
    func theSnapshotReportsTheLatch() async throws {
        let latch = ThermalEmergencyLatch()
        await latch.engage(
            by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99),
            answering: [smcKey("Tp01")])

        let snapshot = try await authority(
            provider: fanProvider(fanCount: 1), thermalEmergency: latch
        ).snapshot()

        #expect(snapshot.isThermalEmergencyActive)
    }

    /// `isReclaimedBySystem` is read from § 5's ledger, not written as a literal.
    ///
    /// The same defect as the latch's, one epic later and one cardinality up:
    /// `fanState(for:reclamation:)` carried `isReclaimedBySystem: false` with a comment
    /// saying E2 has no watchdog. Mark a fan in the ledger and the snapshot says so; put the
    /// literal back and this goes red.
    @Test("A fan the ledger records as reclaimed is reported on the snapshot")
    func theSnapshotReportsTheReclamationLedger() async throws {
        let ledger = ReclamationLedger()
        await ledger.markReclaimed(fanAt: 1)

        let snapshot = try await authority(
            provider: fanProvider(fanCount: 2), reclamation: ledger
        ).snapshot()

        #expect(try #require(snapshot.fans.first { $0.index == 1 }).isReclaimedBySystem)
    }

    /// The ledger is consulted **per fan**, not collapsed to one bit for the machine.
    ///
    /// § 3's latch is machine-wide because a package temperature is not attributable to a
    /// fan; reclamation is the opposite, and reporting a two-fan machine's reclaimed fan 1
    /// as a reclaimed fan 0 as well would be a false claim in the direction people forget —
    /// saying control was lost that is in fact still held. Replace the per-fan lookup with
    /// `!reclaimedFans.isEmpty` and this goes red where the test above stays green.
    @Test("A reclaimed fan does not make its neighbour report as reclaimed")
    func reclamationIsReportedPerFan() async throws {
        let ledger = ReclamationLedger()
        await ledger.markReclaimed(fanAt: 1)

        let snapshot = try await authority(
            provider: fanProvider(fanCount: 2), reclamation: ledger
        ).snapshot()

        #expect(try #require(snapshot.fans.first { $0.index == 0 }).isReclaimedBySystem == false)
    }

    /// Blindness is never reported as `isReclaimedBySystem` — #140 — and is not an availability
    /// either — #355.
    ///
    /// The two ways § 5 gives a fan up were one `Set<Int>` membership, so a helper that had
    /// merely stopped being able to read told the user the operating system had taken the
    /// fan. `FanState.isReclaimedBySystem`'s contract is narrower than that and the UI
    /// renders it verbatim as "Reclaimed by system". That half is unchanged.
    ///
    /// **The second half is inverted by
    /// [#355](https://github.com/blamechris/Aeolus/issues/355), deliberately.** It used to
    /// require `.unavailable(.supervisorBlind)` here, outranking the build. But § 5's blindness
    /// is a record of what happened — reported by its fault lines and by the lease it ended —
    /// and the grant path never reads it, so as an availability it said "cannot currently
    /// read" for the life of the process, after a reconnect that had often worked, and refused
    /// a lease the helper would grant. The availability is current evidence: here, the build.
    ///
    /// Report `.systemReclaimed` for both causes and the first assertion goes red; re-add the
    /// blindness arm to `ReadOnlyFanReport.availability(writeCapabilityIs:bounds:)`, with the
    /// ledger cause passed back in, and the second does.
    @Test("A fan the ledger records as blind is neither reported reclaimed nor refused for it")
    func theSnapshotDoesNotReportBlindnessAsAReclamationOrARefusal() async throws {
        let ledger = ReclamationLedger()
        await ledger.markSupervisorBlind(fanAt: 1)

        let snapshot = try await authority(
            provider: fanProvider(fanCount: 2), reclamation: ledger
        ).snapshot()

        let blindFan = try #require(snapshot.fans.first { $0.index == 1 })
        #expect(blindFan.isReclaimedBySystem == false)
        #expect(blindFan.manualControlAvailability == .unavailable(.writePathNotBuilt))
    }

    // `blindnessIsReportedPerFan` was deleted by #355. It held the blindness arm of the
    // availability mapping to the fan it named, and with no such arm every fan reads the
    // build's answer, so it could no longer fail. `reclamationIsReportedPerFan` above holds the
    // per-fan rule for the field the ledger still reaches.

    /// An empty ledger reports every fan as ours — the state every build ships in today.
    @Test("An empty ledger reports no fan as reclaimed")
    func anEmptyLedgerReportsNothing() async throws {
        let snapshot = try await authority(provider: fanProvider(fanCount: 2)).snapshot()

        #expect(snapshot.fans.allSatisfy { !$0.isReclaimedBySystem })
    }

    private func authority(
        provider: FakeSensorProvider,
        thermalEmergency: ThermalEmergencyLatch = ThermalEmergencyLatch(),
        reclamation: ReclamationLedger = ReclamationLedger()
    ) -> ReadOnlyFanAuthority {
        ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider),
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Authority"),
            thermalEmergency: thermalEmergency,
            reclamation: reclamation,
            writeCapability: LeaseFixture.writePathNotBuilt(),
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }
}
