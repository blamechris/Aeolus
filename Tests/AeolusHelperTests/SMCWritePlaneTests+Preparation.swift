import Foundation
import IOKit
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The production plane's preparation step (C21, C22) and § 3's bridge job on it (W2, W3, and the
/// write turns' admission, W1 and #440's B1).
extension SMCWritePlaneTests {

    // MARK: - C21: one test per branch

    /// A quiescent machine: the step's reads in one turn — each fan's mode and target key info,
    /// then the key's info and its value — and no restore. Its first channel operation is a read.
    /// At rest too, with both fans in Apple's stopped state (raw `3`): the step reads no mode, so
    /// a stopped fan asks for no restore (U14 holds, ADR 0014's P1′ amendment).
    @Test(
        "On a quiescent machine the preparation step reads in one turn and restores nothing",
        arguments: [Set<Int>(), [0, 1]])
    func aQuiescentPreparationRestoresNothing(_ stoppedByApple: Set<Int>) async throws {
        let fixture = WritePlaneFixture(stoppedByApple: stoppedByApple)
        let report = await fixture.plane.prepareWritePath(
            enumerating: ScriptedFanEnumeration(indices: [0, 1]))

        #expect(report?.enumeratedFans == [0, 1])
        #expect(report?.forceKey == .reads(0))
        #expect(report?.machineWideRestore == nil)
        #expect(report?.declaredSizes == [Self.modeZero: 1, Self.modeOne: 1, Self.forceKey: 1])
        #expect(
            fixture.firmware.log.operations == [
                .keyInfo(Self.modeZero, .answered), .keyInfo(Self.targetZero, .answered),
                .keyInfo(Self.modeOne, .answered), .keyInfo(smcKey("F1Tg"), .answered),
                .keyInfo(Self.forceKey, .answered), .read(Self.forceKey, .answered),
            ])
        #expect(fixture.turns(since: 0).map(\.priority) == [.supervisor])
        #expect(try fixture.ledger.forceKey == .present)
    }

    /// The step's three reasons to issue its one machine-wide restore: the key reads non-zero,
    /// its info will not read (unknown), or its value will not (unreadable). Each issues
    /// `.everyFan`
    /// once, after the reads' turn.
    ///
    /// **Mutations:** in `WritePathPreparation.needsMachineWideRestore`, answer `false` for
    /// `.unreadable`. Run: red here, on that row. Answer `true` for `.reads(0)`. Run: red at
    /// `aQuiescentPreparationRestoresNothing`.
    @Test(
        "The preparation step restores machine-wide when the key is set, unknown or unread",
        arguments: ["set", "unknown", "unreadable"])
    func aPreparationRestoresWhenTheKeyIsNotClear(_ state: String) async throws {
        let fixture = WritePlaneFixture()
        switch state {
        case "set": await fixture.firmware.setRegister(Self.forceKey, [0x01])
        case "unknown":
            await fixture.firmware.declare(Self.forceKey, .keyInfoFails(Self.kernelError))
        default: await fixture.firmware.setRead(of: Self.forceKey, .failsWithCode(0x85))
        }

        let report = await fixture.plane.prepareWritePath(
            enumerating: ScriptedFanEnumeration(indices: [0, 1]))

        #expect(report?.machineWideRestore == .landed, "\(state): \(String(describing: report))")
        #expect(fixture.writes(since: 0) == ["F0Md=0", "F1Md=0", "Ftst=0"], "\(state)")
        #expect(fixture.turns(since: 0).count == 2, "\(state): the reads and the restore")
    }

    /// The step never throws: a failed enumeration and a refused restore are reported, not thrown.
    @Test("A failed enumeration and a refused restore are reported, and the step never throws")
    func aPreparationNeverThrows() async throws {
        let fixture = WritePlaneFixture()
        await fixture.firmware.setRegister(Self.forceKey, [0x01])
        await fixture.firmware.setDefaultWrite(.refuses(code: 0x85))

        let report = await fixture.plane.prepareWritePath(
            enumerating: ScriptedFanEnumeration(indices: [], failure: Self.kernelError))

        #expect(report?.enumeratedFans == nil)
        guard case .refused? = report?.machineWideRestore else {
            Issue.record("the refused restore was not reported: \(String(describing: report))")
            return
        }
        #expect(fixture.writes(since: 0) == ["Ftst=0"], "with no fan set it writes the key alone")
    }

    // MARK: - C22: absent only on the not-found answer

    /// The preparation's read turn, with a not-found answer given: `.absent` only when the key's
    /// info answered exactly that; any other key-info failure is `.unknown`; and a present key
    /// whose **value** fails with the same code is `.unreadable`, never absent — absence comes
    /// from key info alone.
    ///
    /// **Mutation:** in `SMCWriteTurns.survey`, classify every key-info failure as `.absent`. Run:
    /// red here, at the other-code and pre-P1 rows.
    @Test(
        "Ftst is absent only on the not-found answer; every other failure is unknown",
        arguments: ["not found", "other code", "pre-P1", "value fails"])
    func theForceKeyIsAbsentOnlyOnNotFound(_ row: String) async throws {
        let notFound = SMCError.firmware(code: 0x84)
        let firmware = FirmwareSMC.mac16x5()
        switch row {
        case "not found", "pre-P1":
            await firmware.declare(Self.forceKey, .absent(answering: notFound))
        case "other code":
            await firmware.declare(Self.forceKey, .keyInfoFails(.firmware(code: 0x85)))
        default: await firmware.setRead(of: Self.forceKey, .failsWithCode(0x84))
        }
        let scheduler = SMCReadScheduler(provider: firmware.provider)
        let given: SMCError? = row == "pre-P1" ? SMCWriteTurns.forceKeyNotFoundAnswer : notFound

        let survey = try await scheduler.withWriteTurn(at: .supervisor, on: firmware) { channel in
            SMCWriteTurns.survey(fans: [0], notFound: given, on: channel)
        }

        switch (row, survey.forceKey) {
        case ("not found", .absent), ("other code", .unknown), ("pre-P1", .unknown),
            ("value fails", .unreadable):
            break
        default:
            Issue.record("\(row): \(survey.forceKey)")
        }
    }

    /// **Unprobed** (ADR 0014's P1′ amendment): P1 did not probe the not-found answer, so the
    /// shipped classifier has none, and no failure classifies `Ftst` absent until a probe defines
    /// one.
    @Test("No not-found answer ships while it is unprobed")
    func noNotFoundAnswerShipsUnprobed() {
        #expect(SMCWriteTurns.forceKeyNotFoundAnswer == nil)
    }

    // MARK: - W2: the bridge job is the command's body and the restore's, in one turn

    /// The bridge job's operations are the command's then the `.fan(n)` restore's, in one turn at
    /// the plane's admission: four round trips while another engaged fan holds the key, five on the
    /// last engaged fan, whose restore clears it.
    ///
    /// **Mutation:** in `SMCFanControlPlane.bridgeThenRestore(_:)`, run the restore half in a
    /// second write turn. Run: red here, at the turns.
    @Test("A bridge job is the command's operations then the restore's, in one turn")
    func aBridgeJobIsOneTurn() async throws {
        let fixture = WritePlaneFixture(unlock: .heldUntilForced(stepsToYield: 0))
        await fixture.prepared()
        try await fixture.engage(0)
        try await fixture.engage(1)

        var mark = fixture.firmware.log.entries.count
        let first = await fixture.plane.bridgeThenRestore(try Self.fan(0).target(for: 5_777))
        #expect(try first.maximum.get().rpm == 5_777)
        #expect(throws: Never.self) { try first.restore.get() }
        #expect(
            fixture.turns(since: mark).map(\.operations) == [
                [
                    .keyInfo(Self.targetZero, .answered),
                    .write(Self.targetZero, FirmwareSMC.flt(rpm: 5_777), .answered),
                    .read(Self.targetZero, .answered), .write(Self.modeZero, [0], .answered),
                ]
            ])

        mark = fixture.firmware.log.entries.count
        let last = await fixture.plane.bridgeThenRestore(try Self.fan(1).target(for: 5_777))
        #expect(throws: Never.self) { try last.restore.get() }
        #expect(fixture.roundTripsPerTurn(since: mark) == [WatchdogLimits.writeTurnRoundTrips])
        #expect(fixture.writes(since: mark).suffix(2) == ["F1Md=0", "Ftst=0"])
    }

    // MARK: - W3: the command half's admission, and the restore half whatever it answered

    /// A seal requested while the bridge job waits refuses its command half at admission — no
    /// target is written — and its restore half still writes. A refused maximum still restores.
    ///
    /// **Mutation:** in `SMCFanControlPlane.bridgeThenRestore(_:)`, run the restore half only when
    /// the command half succeeded. Run: red here, both halves.
    @Test("A refused or sealed command half still runs the restore half")
    func theRestoreHalfRunsWhateverTheCommandAnswered() async throws {
        let fixture = WritePlaneFixture()
        await fixture.prepared()
        try await fixture.engage(0)
        let ledger = try fixture.ledger
        let plane = fixture.plane
        let target = try Self.fan(0).target(for: 5_777)
        await fixture.firmware.holdReads()

        var mark = fixture.firmware.log.entries.count
        let read = observing { try await fixture.scheduler.read(keys: ["F0Md"], at: .supervisor) }
        await yieldUntil("the read to hold its turn") { await fixture.firmware.readsParked == 1 }
        let bridge = observing { await plane.bridgeThenRestore(target) }
        await yieldUntil("the bridge to queue") {
            await fixture.scheduler.queuedTurns(at: .supervisor) == 1
        }
        ledger.restoreRequested(.forExit)
        await fixture.firmware.releaseReads()
        _ = try await finished("the read", read)
        let sealed = try #require(try await finished("the bridge", bridge))
        #expect(throws: FanControlPlaneError.superseded) { try sealed.maximum.get() }
        #expect(throws: Never.self) { try sealed.restore.get() }
        #expect(fixture.writes(since: mark) == ["F0Md=0"], "a target was written after the seal")

        let refusing = WritePlaneFixture()
        await refusing.prepared()
        try await refusing.engage(0)
        await refusing.firmware.queueWrites(to: Self.targetZero, [.refuses(code: 0x85)])
        mark = refusing.firmware.log.entries.count
        let refused = await refusing.plane.bridgeThenRestore(target)
        #expect(throws: (any Error).self) { try refused.maximum.get() }
        #expect(
            refusing.writes(since: mark).last == "F0Md=0", "the refused bridge restored nothing")
    }

    // MARK: - W1 / #440's B1: every write turn at its plane's admission

    /// Every write verb takes its turn at the admission of the view it was called through: through
    /// § 3's lane view, the lane; through the plane, `.supervisor`. The verbs take no admission
    /// argument; the view is the only way to choose one.
    ///
    /// **Mutations:** in `SMCReadScheduler.withWriteTurn`, take the turn at `.supervisor` whatever
    /// it is given. Run: red here, the lane row. Take it at `.thermalCycle`. Run: red here, the
    /// supervisor row.
    @Test("Every write verb's turn is at the admission of the view it came through")
    func everyWriteTurnIsAtItsViewsAdmission() async throws {
        for admission in PlaneAdmission.allCases {
            let fixture = WritePlaneFixture()
            await fixture.prepared()
            let view = fixture.plane.admitted(at: admission)
            let mark = fixture.firmware.log.entries.count

            view.beginEngagement(fanAt: 0)
            #expect(try await view.engageManualControl(of: Self.fan(0)) == .engaged)
            try await view.commandTarget(Self.fan(0).target(for: 2_400))
            _ = await view.bridgeThenRestore(try Self.fan(0).target(for: 5_777))
            try await view.restoreToAutomatic(.fan(0))

            let priorities = fixture.turns(since: mark).map(\.priority)
            #expect(priorities.count == 4, "\(admission): \(priorities)")
            #expect(Set(priorities) == [admission.priority], "\(admission): \(priorities)")
        }
    }
}
