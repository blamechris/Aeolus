import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// What the snapshot says a fan's manual control availability is, held to the one rule that
/// makes the field worth rendering: **it agrees with `acquireLease`.**
///
/// ## The two defects this suite is the evidence for
///
/// [#187](https://github.com/blamechris/Aeolus/issues/187): the lease core's three handback
/// registers reached a client only as an `acquireLease` fault. Nothing put any of them into
/// `SystemSnapshot`, so a fan mid-handback — or one whose handback had been abandoned outright,
/// which never resolves — rendered as `.available` in the same instant a grant over it was
/// refused. The user clicks and the click fails for a reason the screen never showed.
///
/// [#194](https://github.com/blamechris/Aeolus/issues/194): the other end of the same field.
/// `.unavailable(.writePathNotBuilt)` was a **literal** in `ReadOnlyFanReport`, while the grant
/// path sourced the identical refusal from `FanControlPlane.writeCapability`. True of every
/// build that has shipped, and wrong on the first build that can write — at which point one
/// helper would grant leases while telling every client manual control does not exist.
///
/// ## Why the assertions compare two values rather than naming one
///
/// The acceptance #187 asks for is *agreement*, so a test that asserted the snapshot said
/// `.releaseInProgress` would pass against a helper whose grant path had drifted to some other
/// reason. Every agreement test below therefore reads the reason out of the snapshot, reads the
/// reason out of the thrown fault, and requires the two to be **equal** — so a change to either
/// side alone is red. `AvailabilityFixture.refusalForGrant(over:from:)` and
/// `AvailabilityFixture.availability(ofFanAt:in:)` are the two readers, and neither names a
/// reason.
///
/// ## The plane answers `.built`, which is what makes any of this reachable
///
/// `ScriptedControlPlane.writeCapability` is `.built`, so the capability gate clears and every
/// later gate is reachable. On the shipped `SMCFanControlPlane` it is `.notBuilt` and nothing
/// here would be — `theProductionSeamIsWhatTodaysSnapshotReports` is that end, and the two
/// together are the whole of #194: the seam decides, and neither answer is written out.
///
/// The supervisors are not started, for `HelperRestorerTests`' reason: three 1 Hz loops over
/// the same scripted firmware would move the registries these tests assert on.
@Suite("What the snapshot says a fan's manual control availability is", .timeLimit(.minutes(1)))
struct SnapshotAvailabilityTests {

    /// The graphs and the two readers, in `SnapshotAvailabilityDoubles.swift`. Aliased because
    /// the full name puts the agreement assertions past the 100-column line length.
    private typealias Fixture = AvailabilityFixture

    // MARK: - #194: the capability, and the gates it stops shortcutting

    /// A fan that clears every gate on a seam that can write reads `.available`.
    ///
    /// This is the assertion the literal made impossible: while `.writePathNotBuilt` was written
    /// out, no arrangement of machine, ledger or lease core could produce `.available` from this
    /// helper at all — so the vocabulary's one affirmative answer was unreachable and untested.
    ///
    /// **Mutation:** in `ReadOnlyFanReport.availability(writeCapabilityIs:bounds:)`, replace the
    /// body with `.unavailable(.writePathNotBuilt)` — the literal #194 removed. Run: red.
    @Test("A fan on a seam that can write, with nothing else against it, reads available")
    func aFanThatClearsEveryGateOnABuiltSeamReadsAvailable() async throws {
        let helper = Fixture.composed()
        #expect(
            helper.plane.writeCapability == .built,
            "this test is vacuous unless the seam under the helper really can write")

        let snapshot = try await helper.authority.snapshot()

        #expect(
            try Fixture.availability(ofFanAt: 0, in: snapshot) == .available,
            """
            a helper whose seam can write is still reporting manual control unavailable, so \
            every client is told the write path does not exist by the same helper that would \
            grant it a lease.
            """)
    }

    /// The shipped seam's answer, read through the read path that reports it.
    ///
    /// The line every other assertion in this file rests on: they describe a `.built`
    /// executable, and this is the one that says today's is not.
    ///
    /// **Mutation:** make `SMCFanControlPlane.writeCapability` return `.built`. Run: red.
    @Test("The production seam is what today's snapshot reports about the write path")
    func theProductionSeamIsWhatTodaysSnapshotReports() async throws {
        let provider = fanProvider(fanCount: 1)
        let capability = LeaseFixture.writePathNotBuilt()
        #expect(capability.writeCapability == .notBuilt, "the shipped seam claims a write path")
        let reading = ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider),
            log: Fixture.helperLog,
            thermalEmergency: ThermalEmergencyLatch(),
            reclamation: ReclamationLedger(),
            writeCapability: capability)

        let snapshot = try await reading.snapshot()

        #expect(
            try Fixture.availability(ofFanAt: 0, in: snapshot)
                == .unavailable(.writePathNotBuilt))
    }

    /// A `.built` seam does not shortcut § 2's bounds gate.
    ///
    /// #194's third acceptance criterion, and the reason the capability could not simply be
    /// mapped to `.available`: a fan whose declared maximum is ~1e14 — the shape of a
    /// byte-swapped `flt` — has no envelope to clamp into, so no target could ever be minted
    /// for it however capable the build is.
    ///
    /// **Mutation:** in `availability(writeCapabilityIs:bounds:)`, delete the `bounds` arm so a
    /// `.built` seam falls straight through to `.available`. Run: red.
    @Test("A bounds-implausible fan is refused for its bounds even on a seam that can write")
    func aBoundsImplausibleFanIsStillRefusedOnABuiltSeam() async throws {
        let helper = Fixture.composed(
            fanCount: 1,
            extraKeys: [
                SMCFanEnumeration.maximumKey(forFan: 0): .reading(
                    SMCFanEnumeration.maximumKey(forFan: 0), 1e14)
            ])

        let snapshot = try await helper.authority.snapshot()

        #expect(
            try Fixture.availability(ofFanAt: 0, in: snapshot)
                == .unavailable(.boundsImplausible),
            """
            a fan whose firmware bounds cannot be trusted is being offered for manual control \
            on the strength of the build alone. Nothing could ever mint a target for it.
            """)
    }

    /// A fan § 5's ledger records as reclaimed is flagged, and reads what the grant answers.
    ///
    /// **Inverted by [#355](https://github.com/blamechris/Aeolus/issues/355), deliberately.**
    /// This test used to require `.unavailable(.reclaimedBySystem)` here, on the argument that a
    /// bare fall-through would offer a fan macOS is holding. But `acquireLease` never reads the
    /// ledger: it reads the fan fresh and grants it, so that availability refused a lease the
    /// helper grants, and nothing a compliant client could do would clear it. The ledger is
    /// history and is reported as a fact, on `isReclaimedBySystem`; the availability is current
    /// evidence, and agrees with the grant. `TerminalActionAvailabilityTests` asks the same
    /// question after a real terminal action.
    ///
    /// **Mutation:** re-add `if cause == .systemReclaimed { return
    /// .unavailable(.reclaimedBySystem) }` to `availability(writeCapabilityIs:bounds:)`, with
    /// the ledger cause passed back in. Run: red — and note the fan still reports
    /// `isReclaimedBySystem`, so a test reading only that field agrees with the mutant.
    @Test("A reclaimed fan is flagged as reclaimed and reads available, as the grant answers")
    func aReclaimedFanReadsWhatTheGrantAnswers() async throws {
        let helper = Fixture.composed()
        await helper.bindSafetyRegistries()
        await helper.ledger.markReclaimed(fanAt: 0)

        let snapshot = try await helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })

        #expect(fan.isReclaimedBySystem, "the ledger is not reaching the snapshot at all")
        #expect(
            fan.manualControlAvailability == .available,
            "the snapshot refuses a fan the grant path grants, on the strength of § 5's history")
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
    }

    // MARK: - #187: the lease core's refusals, in the read path

    /// A fan whose handback was abandoned reads the reason the grant path throws for it.
    ///
    /// The durable half, and the one that made #187 safety-critical: `.releaseInProgress`
    /// resolves in milliseconds, so a client that retried would eventually be granted its
    /// lease. This one never resolves — nothing clears `restoreAbandoned` for the life of the
    /// helper process — so before this the fan was *permanently* unleasable and *permanently*
    /// displayed as available.
    ///
    /// The firmware refuses the mode write, which is what puts the fan in the register:
    /// `BoundedFanRestorer` spends `RestoreLimits.attemptBudget` and reports the fan as one it
    /// could not hand back.
    ///
    /// **Mutation:** delete the `abandonedHandbacks` arm from
    /// `ReadOnlyFanReport.handbackRefusal(forFanAt:given:)`. Run: red — the snapshot says
    /// `.available` while the grant path refuses.
    @Test("An abandoned handback reads the same reason the grant path throws")
    func anAbandonedHandbackAgreesWithTheGrantPath() async throws {
        let helper = Fixture.composed(writes: Fixture.firmwareRefusesTheModeWrite)
        try await Fixture.acquireAndRelease(fanAt: 0, in: helper)
        #expect(
            await helper.leases.fansWithAbandonedHandbacks.contains(0),
            "the refused restore never reached the durable register, so nothing is being tested")

        let snapshot = try await helper.authority.snapshot()
        let refusal = await Fixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(try Fixture.availability(ofFanAt: 0, in: snapshot) == .unavailable(refusal))
        #expect(refusal == .restoreToAutomaticFailed)
    }

    /// A fan whose restore is on the wire reads the reason the grant path throws for it.
    ///
    /// The transient half. `CycleWedgingRestorePlane` parks the restore, so the window
    /// `LeaseAuthority.releasing` exists to describe is held open for as long as the assertions
    /// need — which is the only way to observe a state that is otherwise milliseconds wide.
    ///
    /// **Mutation:** delete the `handbacksInFlight` arm from
    /// `ReadOnlyFanReport.handbackRefusal(forFanAt:given:)`. Run: red.
    @Test("A fan mid-handback reads the same reason the grant path throws")
    func aFanMidHandbackAgreesWithTheGrantPath() async throws {
        let helper = Fixture.wedging()
        let parked = try await Fixture.parkedHandback(ofFanAt: 0, in: helper)

        let snapshot = try await helper.authority.snapshot()
        let refusal = await Fixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(try Fixture.availability(ofFanAt: 0, in: snapshot) == .unavailable(refusal))
        #expect(refusal == .releaseInProgress)

        await helper.plane.release()
        await parked.value
    }

    /// A fan § 4 gave up waiting for reads the reason the grant path throws for it.
    ///
    /// Decision D33's middle register, and the ordering that matters: the fan is *also* in
    /// `releasing` by the lease core's own subset invariant, so a snapshot that answered from
    /// that register alone would tell a client "retry in a moment" about a restore that has
    /// already outlived a five-second budget.
    ///
    /// **Mutation:** delete the `unconfirmedHandbacks` arm from
    /// `ReadOnlyFanReport.handbackRefusal(forFanAt:given:)`. Run: red — and the failure is the
    /// *wrong reason*, `.releaseInProgress`, not `.available`, which is what makes the ordering
    /// rather than the presence of the arm the thing under test.
    @Test("An unconfirmed handback reads the same reason the grant path throws")
    func anUnconfirmedHandbackAgreesWithTheGrantPath() async throws {
        let helper = Fixture.wedging()
        let parked = try await Fixture.parkedHandback(ofFanAt: 0, in: helper)
        let recorded = await helper.leases.recordUnconfirmedHandbacks()
        #expect(recorded.contains(0), "§ 4's budget path recorded nothing to assert about")

        let snapshot = try await helper.authority.snapshot()
        let refusal = await Fixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(try Fixture.availability(ofFanAt: 0, in: snapshot) == .unavailable(refusal))
        #expect(refusal == .handbackUnconfirmed)

        await helper.plane.release()
        await parked.value
    }

    /// One fan's handback does not speak for its neighbour.
    ///
    /// The per-fan half, which every field on this path has needed its own test for — see
    /// `ReadOnlyFanAuthorityLatchTests.reclamationIsReportedPerFan`. A re-statement keyed on
    /// "any fan is in the register" would disable the control for a whole machine because one
    /// fan's handback failed.
    ///
    /// **Mutation:** in `handbackRefusal(forFanAt:given:)`, replace
    /// `leases.abandonedHandbacks.contains(index)` with
    /// `!leases.abandonedHandbacks.isEmpty`. Run: red on fan 1 while the test above stays green.
    @Test("An abandoned handback does not make the neighbour fan unavailable")
    func aHandbackRegisterIsReadPerFan() async throws {
        let helper = Fixture.composed(writes: Fixture.firmwareRefusesTheModeWrite, fanCount: 2)
        try await Fixture.acquireAndRelease(fanAt: 0, in: helper)

        let snapshot = try await helper.authority.snapshot()

        #expect(
            try Fixture.availability(ofFanAt: 0, in: snapshot)
                == .unavailable(.restoreToAutomaticFailed))
        #expect(
            try Fixture.availability(ofFanAt: 1, in: snapshot) == .available,
            "one fan's abandoned handback has taken manual control of the whole machine away")
    }

    /// Every fan in a handback register is one Aeolus is accountable for.
    ///
    /// The invariant that lets `ReadOnlyFanReport`'s two re-statements compose in either order,
    /// asserted rather than described.
    /// `reportingForeignControl(of:observedMode:heldByAeolus:awaitingConfirmation:reconciliation:)`
    /// returns an accountable fan untouched, so while this holds the foreign-control rule and the
    /// handback rule can never speak about the same fan — and the day it stops holding, the
    /// composition order in `restatingAvailability(of:observedMode:given:reconciliation:)` starts
    /// deciding which reason a user sees, silently.
    ///
    /// **Mutation:** drop `.union(restoreAbandoned)` from
    /// `LeaseAuthority.fansAeolusIsAccountableFor`. Run: red.
    @Test("Every fan in a handback register is one Aeolus is accountable for")
    func handbackRegistersAreContainedInTheAccountableSet() async throws {
        let helper = Fixture.composed(writes: Fixture.firmwareRefusesTheModeWrite)
        try await Fixture.acquireAndRelease(fanAt: 0, in: helper)

        let view = await helper.leases.activeLeaseView()
        let registers = view.abandonedHandbacks
            .union(view.unconfirmedHandbacks)
            .union(view.handbacksInFlight)

        #expect(!registers.isEmpty, "no register was populated, so the containment is vacuous")
        #expect(
            registers.isSubset(of: view.accountableFans),
            """
            a fan in a handback register is not in the accountable set, so \
            reportingForeignControl can now overwrite the handback reason with \
            .foreignManualControl — blaming another program for a fan Aeolus pinned itself.
            """)
    }
}
