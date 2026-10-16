import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// What the snapshot and the grant say about a fan **after** § 5's terminal action, composed
/// ([#355](https://github.com/blamechris/Aeolus/issues/355)).
///
/// Since #354 the terminal action keeps the ledger entry it gives a fan up under. Until #355 the
/// snapshot published that entry as an availability — `.reclaimedBySystem` on a seam that can
/// write, `.supervisorBlind` on any — while `LeaseAuthority.acquireLease` never reads the
/// ledger and granted the lease. Only an engagement or a release clears the entry, and both
/// need the lease the snapshot told a compliant client not to ask for.
///
/// The rule these hold: an availability is computed from current evidence the grant path
/// consults, and § 5's ledger is history, reported as a fact (`isReclaimedBySystem`, the log,
/// the lease ending). The grant did not move; the snapshot did. So each test here runs a real
/// terminal action through `FinaliseReleaseLedgerTests`' fixture — the graph the daemon builds,
/// bound as bring-up binds it, § 5 cycled by hand — and then asks both sides.
///
/// **Each proves the terminal action ran, and kept its entry, before it asserts anything
/// about the entry's consequences.** A scenario in which § 5 never gave the fan up, or the
/// revocation erased the mark, would leave every assertion here green for the wrong reason.
@Suite("After § 5's terminal action, the snapshot agrees with the grant", .timeLimit(.minutes(1)))
struct TerminalActionAvailabilityTests {

    private typealias Ledger = FinaliseReleaseLedgerTests

    /// A fan the system took back reads available, still flagged as reclaimed, and is granted.
    ///
    /// The fact and the availability are two fields, and only the first is history: the
    /// grant reads the fan fresh, finds it automatic, and grants. A snapshot that refused it
    /// would refuse a lease the helper grants, for as long as the process lives.
    ///
    /// **Mutation:** re-add `if cause == .systemReclaimed { return
    /// .unavailable(.reclaimedBySystem) }` below the capability guard in
    /// `ReadOnlyFanReport.availability(writeCapabilityIs:bounds:)`, with the ledger cause passed
    /// back in. Run: red on the availability, while `isReclaimedBySystem` stays green.
    @Test("A fan § 5 gave up to the system reads available, still flagged, and is granted")
    func aReclaimedFanReadsAvailableAndIsGranted() async throws {
        let (helper, log) = try await Ledger.holding()
        await Ledger.cycleToTheTerminalAction(helper)
        #expect(
            log.lines(containing: "no speed to re-assert").count == 1,
            "§ 5 never reached its terminal action, so nothing here was tested")
        await Ledger.expectTheRevocationRestoredThroughTheRestorer(helper)
        #expect(await helper.ledger.isReclaimed(fanAt: 0), "the terminal action kept no mark")

        let snapshot = try await helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })

        #expect(fan.isReclaimedBySystem, "the fact left the wire along with the refusal")
        #expect(
            fan.manualControlAvailability == .available,
            """
            the snapshot refuses a fan the grant path grants: § 5's ledger is being published \
            as an availability, and nothing a compliant client does can clear it.
            """)
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
    }

    /// A fan § 5 gave up blind, whose mode answers again, reads available and is granted.
    ///
    /// § 5's blindness was "cannot currently read", stated in the present tense for the life of
    /// the process — false from the first read that answered after it. The grant reads the fan
    /// fresh and grants, so the snapshot says so. #140's half is unchanged: blindness is never
    /// reported as a system reclamation.
    ///
    /// **Both sides read the fan once it answers.** The grant reads through the plane, whose
    /// blind stage ends. The snapshot reads `F0Md` through its own provider, which does not
    /// answer the key while the plane is blind and answers automatic afterwards; its count of
    /// answered reads proves the snapshot read the mode, because an unreadable mode is reported
    /// automatic too (#178). Since #360 the availability tells this fan from one still blind as
    /// well — `aStillBlindFanReadsTheGrantsRefusal`.
    ///
    /// **Mutation:** re-add `if cause == .supervisorBlind { return
    /// .unavailable(.supervisorBlind) }` as the first statement of
    /// `ReadOnlyFanReport.availability(writeCapabilityIs:bounds:)`, with the ledger cause passed
    /// back in. Run: red on the availability.
    @Test("A fan § 5 gave up blind reads available once its mode answers, and is granted")
    func aBlindFanReadableAgainReadsAvailableAndIsGranted() async throws {
        let provider = ModeSwitchingProvider(fanCount: 1)
        let (helper, log) = try await Ledger.holding(
            afterwards: [
                .blind(), .nominal(temperatures: LeaseFixture.nominalDieTemperatures),
            ],
            snapshotProvider: provider)
        await helper.plane.advance()
        await Ledger.cycleToTheTerminalAction(helper)
        #expect(
            log.lines(containing: "because the helper cannot read its state").count == 1,
            "§ 5 never gave the blind fan up, so nothing here was tested")
        await Ledger.expectTheRevocationRestoredThroughTheRestorer(helper)
        #expect(await helper.ledger.isSupervisorBlind(fanAt: 0), "the terminal action kept no mark")
        await helper.plane.advance()
        await provider.setMode(0, ofFan: 0)

        let snapshot = try await helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })

        #expect(
            await provider.answeredModeReads > 0,
            "the snapshot never read fan 0's mode, so it said nothing about the fan answering")
        #expect(fan.isReclaimedBySystem == false, "blindness reported as a system reclamation")
        #expect(
            fan.manualControlAvailability == .available,
            """
            the snapshot still says the helper cannot read a fan it now reads, and refuses a \
            lease the grant path grants.
            """)
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
    }

    /// A fan § 5 gave up, that another program takes afterwards, reads the reason the grant
    /// throws for it.
    ///
    /// Step 5 of the ladder used to exempt every fan § 5 had given up, so this fan read
    /// `.available` — the read path's answer, untouched — while the grant refused it
    /// `.foreignManualControl`. § 3 is cycled first so its read-back confirms the terminal
    /// action's hand-back (#303); the fan is then taken without a recorded attempt, on the plane
    /// the grant reads and on the provider the snapshot reads, as another tool would take it.
    /// `isReclaimedBySystem` stays set — it is history, and stale now — and the availability
    /// beside it is current.
    ///
    /// **Mutation:** re-add `, !fan.isReclaimedBySystem` to the `held` guard in
    /// `ReadOnlyFanReport.reportingForeignControl(of:observedMode:heldByAeolus:
    /// awaitingConfirmation:reconciliation:)`. Run: red on the agreement.
    @Test("A fan § 5 gave up that another program then takes reads the grant's own refusal")
    func aFanTakenAfterTheTerminalActionAgreesWithTheGrant() async throws {
        let provider = ModeSwitchingProvider(fanCount: 1)
        let (helper, log) = try await Ledger.holding(snapshotProvider: provider)
        await Ledger.cycleToTheTerminalAction(helper)
        #expect(
            log.lines(containing: "no speed to re-assert").count == 1,
            "§ 5 never reached its terminal action, so nothing here was tested")
        await Ledger.expectTheRevocationRestoredThroughTheRestorer(helper)
        #expect(await helper.ledger.isReclaimed(fanAt: 0), "the terminal action kept no mark")
        await helper.thermalEmergency.cycle()
        #expect(
            await helper.thermalEmergency.fansAwaitingRestoreConfirmation.isEmpty,
            "§ 3 still keeps fan 0, so the grant would answer for Aeolus's restore instead")

        await helper.plane.setMode(.manual, ofFan: 0)
        await provider.setMode(1, ofFan: 0)

        let snapshot = try await helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })
        let refusal = await AvailabilityFixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(fan.mode == .manualFixed, "the snapshot never saw the fan taken")
        #expect(fan.isReclaimedBySystem, "the mark was cleared, so the exemption is not reachable")
        #expect(
            fan.manualControlAvailability == .unavailable(refusal),
            """
            the snapshot and the grant disagree about a fan § 5 gave up and another program \
            then took: a past diagnosis is standing in for what the fan reads now.
            """)
        #expect(refusal == .foreignManualControl)
    }

    /// A fan § 5 gave up that § 3 is still keeping, then taken into manual, reads the reason the
    /// grant throws: `.restoreToAutomaticUnconfirmed`.
    ///
    /// The terminal action's hand-back is Aeolus's own restore, and until § 3's read-back
    /// confirms it the fan is in § 3's kept set (#303). A kept fan that reads manual is that
    /// unconfirmed restore by the grant's own reclassification, not another program's — and
    /// the ledger mark beside it must not exempt it. Unlike the test above, § 3 is not cycled.
    ///
    /// **Mutation:** in `ReadOnlyFanReport.reportingForeignControl(of:observedMode:heldByAeolus:
    /// awaitingConfirmation:reconciliation:)`, make the guard
    /// `guard !held.contains(fan.index), !(fan.isReclaimedBySystem && awaiting.contains(fan.index))
    /// else { return fan }`. Run: red on the agreement, while the test above stays green.
    @Test("A fan § 5 gave up that § 3 still keeps, then taken, reads the grant's own refusal")
    func aKeptFanTakenAfterTheTerminalActionAgreesWithTheGrant() async throws {
        let provider = ModeSwitchingProvider(fanCount: 1)
        let (helper, log) = try await Ledger.holding(snapshotProvider: provider)
        await Ledger.cycleToTheTerminalAction(helper)
        #expect(
            log.lines(containing: "no speed to re-assert").count == 1,
            "§ 5 never reached its terminal action, so nothing here was tested")
        await Ledger.expectTheRevocationRestoredThroughTheRestorer(helper)
        #expect(await helper.ledger.isReclaimed(fanAt: 0), "the terminal action kept no mark")
        #expect(
            await helper.thermalEmergency.fansAwaitingRestoreConfirmation == [0],
            "§ 3 is not keeping fan 0, so the kept-set reclassification is not what is asked")

        await helper.plane.setMode(.manual, ofFan: 0)
        await provider.setMode(1, ofFan: 0)

        let snapshot = try await helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })
        let refusal = await AvailabilityFixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(fan.mode == .manualFixed, "the snapshot never saw the fan taken")
        #expect(fan.isReclaimedBySystem, "the mark was cleared, so the exemption is not reachable")
        #expect(
            fan.manualControlAvailability == .unavailable(refusal),
            """
            the snapshot and the grant disagree about a fan § 5 gave up and § 3 still keeps: \
            the ledger mark is exempting it from the reclassification the grant makes.
            """)
        #expect(refusal == .restoreToAutomaticUnconfirmed)
    }

    // MARK: - The gap #360 closed

    /// A fan § 5 gave up blind whose mode *still* will not read reads the reason the grant throws
    /// for it, `.supervisorBlind`.
    ///
    /// **Pinned as a known gap until [#360](https://github.com/blamechris/Aeolus/issues/360)
    /// closed it.** This test asserted that the snapshot said `.available` here while the grant's
    /// fresh read refused the fan `.supervisorBlind`: fail-safe for the grant, and not for
    /// `fanctl auto`, which read the fan as cleared and exited 0 without its restore. Step 5 of the
    /// ladder now judges the snapshot's own `F0Md` answer as the grant judges its read, so the two
    /// agree. `FanState.mode` still folds the unread mode into automatic (#178).
    ///
    /// The firmware's own stage leaves `F0Md` unanswered while its temperatures answer, so § 3 is
    /// sighted and the grant reaches its read of the fan, and the snapshot's provider reads the key
    /// from the same firmware (`PlaneBackedProvider`). Each step is proved before the claim: the
    /// snapshot read the mode while the fan was held, § 5 gave it up blind, § 3 still keeps it,
    /// reconciliation refused nothing that could answer `.supervisorBlind` in the rung's place, and
    /// the grant's refusal is the fresh read's.
    ///
    /// **Mutation:** delete the `case nil:` arm's restatement in
    /// `ReadOnlyFanReport.reportingForeignControl(of:observedMode:heldByAeolus:
    /// awaitingConfirmation:reconciliation:)`, returning `fan`. Run: red on the agreement.
    /// **Mutation:** in `SupervisedFanAuthority.snapshot()`, pass `observedMode: .automatic`.
    /// Run: red on the agreement.
    @Test("A fan § 5 gave up whose mode still will not read reads the grant's own refusal")
    func aStillBlindFanReadsTheGrantsRefusal() async throws {
        let (helper, log) = try await Ledger.holding(
            afterwards: [
                ScriptedControlPlane.Stage(
                    temperatures: LeaseFixture.nominalDieTemperatures, unreadableModes: [0])
            ])
        await helper.plane.setMode(.manual, ofFan: 0)
        let held = try #require(try await helper.authority.snapshot().fans.first { $0.index == 0 })
        #expect(held.mode == .manualFixed, "the snapshot does not read the plane's firmware")
        await helper.plane.advance()

        await Ledger.cycleToTheTerminalAction(helper)
        #expect(
            log.lines(containing: "because the helper cannot read its state").count == 1,
            "§ 5 never gave the blind fan up, so nothing here was tested")
        await Ledger.expectTheRevocationRestoredThroughTheRestorer(helper)
        #expect(await helper.ledger.isSupervisorBlind(fanAt: 0), "the terminal action kept no mark")
        await helper.thermalEmergency.cycle()
        #expect(
            await helper.thermalEmergency.fansAwaitingRestoreConfirmation == [0],
            "§ 3 confirmed a hand-back it cannot read, so the fan is not the one #360 is about")
        #expect(
            await helper.reconciliation.baseline().durableRefusal(overFans: [0]) == nil,
            "reconciliation refuses fan 0 itself, which would answer in the rung's place")

        let snapshot = try await helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })
        let refusal = await AvailabilityFixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(refusal == .supervisorBlind, "the grant never reached its fresh read of fan 0")
        #expect(fan.mode == .automatic, "#178's fold moved: an unread mode is reported automatic")
        #expect(fan.isReclaimedBySystem == false, "blindness reported as a system reclamation")
        #expect(
            fan.manualControlAvailability == .unavailable(refusal),
            """
            the snapshot offers a fan the grant refuses as blind: its own read of fan 0's mode did \
            not answer, and step 5 reported the fan available.
            """)
    }
}

/// `fanProvider(fanCount:)` with each fan's `F<n>Md` movable mid-test, so the snapshot's read
/// path can see a fan taken at the moment the scripted plane does — the snapshot reads the mode
/// through its provider, never through the plane (`SnapshotFanModeReads`).
///
/// Until a mode is set the key answers as that provider's does: not present, which the snapshot
/// reports as automatic (#178) and, on this plane that can write, as `.supervisorBlind` for a fan
/// nothing holds (#360). Every test here sets the mode before the snapshot it asserts on.
private actor ModeSwitchingProvider: SensorProvider {
    nonisolated let identifier = "mode-switching"

    private let wrapped: FakeSensorProvider
    private var rawModes: [String: Double] = [:]

    /// How many `F<n>Md` reads this answered with a set mode — the evidence a snapshot really
    /// read one, since an unanswered mode is reported automatic as well.
    private(set) var answeredModeReads = 0

    init(fanCount: Int) {
        wrapped = fanProvider(fanCount: fanCount)
    }

    /// What `F<index>Md` reads from now on, as a raw value: `0` automatic, non-zero manual.
    func setMode(_ raw: Double, ofFan index: Int) {
        rawModes["F\(index)Md"] = raw
    }

    var isAvailable: Bool {
        get async { await wrapped.isAvailable }
    }

    func readAll() async throws -> [SensorReading] {
        try await wrapped.readAll()
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        let modes = rawModes
        let outcomes = try await wrapped.read(keys: keys).map { outcome in
            guard let raw = modes[outcome.key] else { return outcome }
            return SensorReadOutcome(key: outcome.key, result: .reading(outcome.key, raw))
        }
        answeredModeReads += keys.filter { modes[$0] != nil }.count
        return outcomes
    }
}
