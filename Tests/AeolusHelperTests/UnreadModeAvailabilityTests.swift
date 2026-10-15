import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// What the snapshot says about a fan whose `F<n>Md` did not read, held to the grant's answer
/// ([#360](https://github.com/blamechris/Aeolus/issues/360)).
///
/// `StartupReconciliation.refusalForGrant` refuses `.supervisorBlind` for any candidate whose
/// fresh read throws, and step 5 of the availability ladder judges the snapshot's own read the
/// same way. These pin where that answer sits: for every fan Aeolus is not accountable for, not
/// only § 3's kept set; below the `held` exemption and the durable refusal; never over
/// `.writePathNotBuilt`; and from the read the fan was built from, not a second one.
/// `TerminalActionAvailabilityTests.aStillBlindFanReadsTheGrantsRefusal` is the scenario #360 was
/// found in, and `FanctlAutoUnreadModeTests` what `fanctl auto` makes of it.
///
/// The fan stops answering on the firmware's own stage, `ScriptedControlPlane.Stage
/// .unreadableModes`, while its temperatures answer, so § 3 is sighted and the grant reaches its
/// read of the fan. The snapshot reads the key from that same firmware (`PlaneBackedProvider`).
/// The supervisors are not started, for `SnapshotAvailabilityTests`' reason.
@Suite("A fan whose mode did not read answers what the grant answers", .timeLimit(.minutes(1)))
struct UnreadModeAvailabilityTests {

    private typealias Fixture = AvailabilityFixture

    /// A stage on which the SMC answers, the temperatures are nominal, and `fans`' `F<n>Md` does
    /// not answer.
    private static func modesUnread(_ fans: Set<Int>) -> ScriptedControlPlane.Stage {
        ScriptedControlPlane.Stage(
            temperatures: LeaseFixture.nominalDieTemperatures, unreadableModes: fans)
    }

    /// `AvailabilityFixture.composed`'s wiring over a plane and a provider the test chooses.
    private static func composed<Plane: FanControlPlane>(
        plane: Plane, provider: some SensorProvider
    ) -> HelperComposition<Plane> {
        HelperComposition(
            plane: plane,
            snapshotProvider: provider,
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            log: Fixture.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Fixture.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    // MARK: - Every fan Aeolus is not accountable for

    /// A fan nothing has ever leased, whose mode will not read, reads `.supervisorBlind` as the
    /// grant refuses it — the broad rung rather than one keyed on § 3's kept set.
    ///
    /// The grant refuses any candidate it cannot read, whether or not § 3 is keeping it, so a
    /// rung asked only of § 3's fans would mirror a subset of the grant's rule and leave every
    /// other unreadable fan `.available`: a fan another program holds whose mode then stops
    /// reading, for one.
    ///
    /// **Mutation:** in `ReadOnlyFanReport.reportingForeignControl(of:observedMode:heldByAeolus:
    /// awaitingConfirmation:reconciliation:)`, make the `case nil:` arm's guard
    /// `guard canWrite, awaiting.contains(fan.index) else { return fan }`. Run: red on the
    /// agreement.
    @Test("A fan never leased whose mode will not read reads the grant's own refusal")
    func anUnleasedFanWhoseModeWillNotReadAgreesWithTheGrant() async throws {
        let helper = Fixture.composed(afterwards: [Self.modesUnread([0])])
        await helper.bindSafetyRegistries()
        await helper.plane.advance()
        #expect(
            await helper.thermalEmergency.fansAwaitingRestoreConfirmation.isEmpty,
            "§ 3 is keeping fan 0, so this asks the narrow question rather than the broad one")
        #expect(await helper.leases.activeLeaseView().accountableFans.isEmpty)
        #expect(
            await helper.reconciliation.baseline().durableRefusal(overFans: [0]) == nil,
            "reconciliation refuses fan 0 itself, which would answer in the rung's place")

        let snapshot = try await helper.authority.snapshot()
        let refusal = await Fixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(refusal == .supervisorBlind, "the grant never reached its read of fan 0")
        #expect(
            try Fixture.availability(ofFanAt: 0, in: snapshot) == .unavailable(refusal),
            """
            a fan whose mode did not read is offered for manual control while the grant refuses \
            it as blind: the rung is narrower than the grant's rule.
            """)
    }

    // MARK: - Not over the build

    /// On a seam that cannot write, a fan whose mode will not read reads `.writePathNotBuilt`, the
    /// grant's answer there, through the supervised snapshot.
    ///
    /// `SnapshotAvailabilityTests.theProductionSeamIsWhatTodaysSnapshotReports` goes through the
    /// read path alone, which never reaches step 5, so it cannot see the rung. Every build on
    /// `main` is this case: `.supervisorBlind` here would be stated permanently on every fan of a
    /// Mac without `F<n>Md`, by a reason no grant returns.
    ///
    /// **Mutation:** delete `guard canWrite else { return fan }` from the `case nil:` arm in
    /// `ReadOnlyFanReport.reportingForeignControl(of:observedMode:heldByAeolus:
    /// awaitingConfirmation:reconciliation:)`. Run: red on the agreement.
    @Test("On a seam that cannot write, a fan whose mode will not read reads writePathNotBuilt")
    func aSeamThatCannotWriteStatesTheBuildNotTheRead() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)], stages: [Self.modesUnread([0])])
        let helper = Self.composed(
            plane: ControlStateGatePlane(firmware, capability: .notBuilt),
            provider: PlaneBackedProvider(over: firmware, fanCount: 1))
        await #expect(throws: FanControlPlaneError.self, "fan 0's mode reads") {
            try await firmware.firmwareMode(ofFan: 0)
        }

        let snapshot = try await helper.authority.snapshot()
        let refusal = await Fixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(refusal == .writePathNotBuilt)
        #expect(
            try Fixture.availability(ofFanAt: 0, in: snapshot) == .unavailable(refusal),
            "a build that cannot write states a reason about the fan's read that no grant returns")
    }

    // MARK: - Below the held exemption and the durable refusal

    /// A fan under a live lease whose mode stops reading is not judged blind: it is Aeolus's own,
    /// and the lease core answers for it.
    ///
    /// **Mutation:** hoist the `case nil:` arm above the `held` guard in
    /// `ReadOnlyFanReport.reportingForeignControl(of:observedMode:heldByAeolus:
    /// awaitingConfirmation:reconciliation:)` — insert `if observedMode == nil,
    /// fan.manualControlAvailability != .unavailable(.writePathNotBuilt) { return restating(fan,
    /// as: .unavailable(.supervisorBlind)) }` as its first statement. Run: red.
    @Test("A fan under a live lease whose mode stops reading is not judged blind")
    func aLeasedFanWhoseModeStopsReadingIsNotJudgedBlind() async throws {
        let helper = Fixture.composed(afterwards: [Self.modesUnread([0])])
        await helper.bindSafetyRegistries()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        await helper.plane.advance()
        #expect(await helper.leases.activeLeaseView().accountableFans == [0])

        let snapshot = try await helper.authority.snapshot()

        #expect(snapshot.activeLease != nil, "the lease is gone, so nothing here is held")
        #expect(
            try Fixture.availability(ofFanAt: 0, in: snapshot) == .available,
            "a fan Aeolus holds under a live lease was judged as though nobody held it")
    }

    /// A fan mid-handback whose mode will not read reads `.releaseInProgress`, the grant's answer:
    /// the handback register speaks for it, as it does for any fan Aeolus is accountable for.
    @Test("A fan mid-handback whose mode will not read reads the grant's own refusal")
    func aFanMidHandbackWhoseModeWillNotReadAgreesWithTheGrant() async throws {
        let firmware = Fixture.firmware(
            fanCount: 1, writes: .honoured, afterwards: [Self.modesUnread([0])])
        let helper = Fixture.wedging(firmware: firmware)
        let parked = try await Fixture.parkedHandback(ofFanAt: 0, in: helper)
        await firmware.advance()

        let snapshot = try await helper.authority.snapshot()
        let refusal = await Fixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(refusal == .releaseInProgress)
        #expect(try Fixture.availability(ofFanAt: 0, in: snapshot) == .unavailable(refusal))

        await helper.plane.release()
        await parked.value
    }

    /// A fan reconciliation could not hand back, whose mode will not read, reads the durable
    /// refusal the grant answers from the baseline before it reads anything.
    ///
    /// Fan 0 is in manual when the pass runs and the firmware refuses every restore, so it is a
    /// refused handback; then its mode stops reading.
    ///
    /// **Mutation:** hoist the `case nil:` arm above the durable refusal in
    /// `ReadOnlyFanReport.reportingForeignControl(of:observedMode:heldByAeolus:
    /// awaitingConfirmation:reconciliation:)` — insert `if observedMode == nil, canWrite { return
    /// restating(fan, as: .unavailable(.supervisorBlind)) }` just below `let canWrite`. Run: red —
    /// the snapshot says `.supervisorBlind`.
    @Test("A durable reconciliation refusal outranks a mode that will not read")
    func aDurableRefusalOutranksAnUnreadMode() async throws {
        let refused = Fixture.firmwareRefusesTheModeWrite
        let helper = Fixture.composed(
            writes: refused,
            afterwards: [
                ScriptedControlPlane.Stage(
                    temperatures: LeaseFixture.nominalDieTemperatures, writes: refused,
                    unreadableModes: [0])
            ])
        await helper.plane.setMode(.manual, ofFan: 0)
        await helper.reconciliation.reconcile()
        #expect(
            await helper.reconciliation.fansWithRefusedHandback == [0],
            "reconciliation handed fan 0 back, so there is no durable refusal to outrank anything")
        await helper.plane.advance()

        let snapshot = try await helper.authority.snapshot()
        let refusal = await Fixture.refusalForGrant(over: 0, from: helper.leases)

        #expect(refusal == .restoreToAutomaticFailed)
        #expect(
            try Fixture.availability(ofFanAt: 0, in: snapshot) == .unavailable(refusal),
            "the read that did not answer is standing in for a refusal no read can clear")
    }

    // MARK: - One read

    /// The availability is judged from the `F<n>Md` read the fan was built from, and the snapshot
    /// reads the key once.
    ///
    /// The provider fails `F0Md` on its first read and answers automatic on every one after, so a
    /// second read would judge a different answer from the one the snapshot is built on. The
    /// grant is not asked: its own read is the plane's, which answers.
    ///
    /// **Mutation:** in `ReadOnlyFanAuthority.observe()`, return
    /// `MachineObservation(snapshot: snapshot, modes: await fanModes.modes(ofFans:
    /// fans.fanIndices))`. Run: red on the read count and on the availability.
    @Test("The availability judges the mode read the snapshot was built from, read once")
    func theAvailabilityJudgesTheReadTheSnapshotWasBuiltFrom() async throws {
        let provider = FirstModeReadFailsProvider(fanCount: 1)
        let helper = Self.composed(
            plane: Fixture.firmware(fanCount: 1, writes: .honoured), provider: provider)

        let snapshot = try await helper.authority.snapshot()

        #expect(await provider.modeReads == 1, "the snapshot read F0Md more than once")
        #expect(
            try Fixture.availability(ofFanAt: 0, in: snapshot) == .unavailable(.supervisorBlind),
            "the availability was judged from a read the snapshot was not built from")
    }
}

/// `fanProvider(fanCount:)`, with `F0Md` failing on its first read and answering automatic on
/// every read after it, and a count of how often it was asked.
private actor FirstModeReadFailsProvider: SensorProvider {
    nonisolated let identifier = "first-mode-read-fails"

    private let wrapped: FakeSensorProvider
    private(set) var modeReads = 0

    init(fanCount: Int) {
        wrapped = fanProvider(fanCount: fanCount)
    }

    var isAvailable: Bool {
        get async { await wrapped.isAvailable }
    }

    func readAll() async throws -> [SensorReading] {
        try await wrapped.readAll()
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        try await wrapped.read(keys: keys).map { outcome in
            guard outcome.key == "F0Md" else { return outcome }
            modeReads += 1
            guard modeReads > 1 else {
                return SensorReadOutcome(
                    key: outcome.key, result: .failure(.readFailed(reason: "F0Md did not answer")))
            }
            return SensorReadOutcome(key: outcome.key, result: .reading(outcome.key, 0))
        }
    }
}
