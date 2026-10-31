import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// D3's force-key path and its answers on the production plane (C15–C18), over `FirmwareSMC`'s
/// byte-level unlock rule.
extension SMCWritePlaneTests {

    // MARK: - C15: the force key, only after a first step's 0x82 with the flag clear

    /// A first step answered `0x82` with the plane's flag clear sets the key in the same turn and
    /// awaits; a second fan answered `0x82` while the flag is set writes no key and waits under it.
    ///
    /// **Mutation:** in `EngagementRules.afterModeWrite`, drop `!forceKeySet` from the guard, so a
    /// held step writes the key whenever it is a first step. Run: red here, at fan 1's writes.
    @Test("The force key is written only after a first step's 0x82 with the flag clear")
    func theForceKeyFollowsAFirstHeldStepOnly() async throws {
        let fixture = WritePlaneFixture(unlock: .heldUntilForced(stepsToYield: 1))
        let mark = await fixture.prepared()

        fixture.plane.beginEngagement(fanAt: 0)
        #expect(try await fixture.plane.engageManualControl(of: Self.fan(0)) == .awaitingYield)
        #expect(fixture.writes(since: mark) == ["F0Md=1", "Ftst=1"])
        #expect(try fixture.ledger.isForceKeySet)

        let second = fixture.firmware.log.entries.count
        fixture.plane.beginEngagement(fanAt: 1)
        #expect(try await fixture.plane.engageManualControl(of: Self.fan(1)) == .awaitingYield)
        #expect(fixture.writes(since: second) == ["F1Md=1"], "a second fan wrote the key")

        let third = fixture.firmware.log.entries.count
        #expect(try await fixture.plane.engageManualControl(of: Self.fan(0)) == .awaitingYield)
        #expect(try await fixture.plane.engageManualControl(of: Self.fan(0)) == .engaged)
        #expect(fixture.writes(since: third) == ["F0Md=1", "F0Md=1"], "a later step wrote the key")
    }

    /// A firmware recorded without the key cannot take this route: the held first step throws, and
    /// nothing but the mode write was issued.
    ///
    /// **Mutation:** in `EngagementRules.afterModeWrite`, delete the `forceKey != .absent` guard.
    /// Run: red here — the key is written.
    @Test("A held first step on a firmware with no force key throws, writing no key")
    func anAbsentForceKeyIsNeverWritten() async throws {
        let fixture = WritePlaneFixture(unlock: .neverYields)
        let mark = await fixture.prepared()
        try fixture.ledger.recordPreparation(
            enumerated: [0, 1], forceKey: .absent,
            declaredSizes: [Self.modeZero: 1, Self.modeOne: 1])

        fixture.plane.beginEngagement(fanAt: 0)
        let error = await #expect(throws: (any Error).self) {
            try await fixture.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(error.map(Self.isRefusedControl) == true, "\(String(describing: error))")
        #expect(fixture.writes(since: mark) == ["F0Md=1"])
    }

    // MARK: - C16: the epoch, re-checked immediately before Ftst = 1

    /// A restore requested after the held mode write's answer, or after the key's info, is seen by
    /// the re-check immediately before the key's write call: `.supersededAfterWrite`, no key.
    ///
    /// **Mutations:** delete the `isCurrent(fanAt:)` re-check in `SMCWriteTurns.setForceKey`. Run:
    /// red here, both rows. Move it before the key's `freshKeyInfo`. Run: red here, the key-info
    /// row only.
    @Test(
        "A restore requested mid-step, before the key's write, supersedes the step after its write",
        arguments: ["after the mode write", "after the key's info"])
    func theEpochIsReCheckedBeforeTheForceKey(_ moment: String) async throws {
        let fixture = WritePlaneFixture(unlock: .heldUntilForced(stepsToYield: 0))
        let mark = await fixture.prepared()
        let ledger = try fixture.ledger
        let operation: FirmwareSMC.Operation =
            moment == "after the mode write" ? .write(Self.modeZero) : .keyInfo(Self.forceKey)
        await fixture.firmware.onAfter(operation) { ledger.restoreRequested(.fan(1)) }

        fixture.plane.beginEngagement(fanAt: 0)
        await #expect(throws: FanControlPlaneError.supersededAfterWrite) {
            try await fixture.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(fixture.writes(since: mark) == ["F0Md=1"], "\(moment): the key was written")
        #expect(!ledger.isForceKeySet)
    }

    // MARK: - C17: a first answer other than 0x00 or 0x82

    /// Every other first answer — the codes this machine has returned to reads, and a write with
    /// no answer — throws, with no read-back, no key and no retry.
    ///
    /// **Mutation:** in `SMCWriteTurns.answer(to:)`, read `0x89` as `.heldBySystem`. Run: red here,
    /// on that row.
    @Test(
        "A first answer other than 0x00 or 0x82 throws, with no read-back and no key",
        arguments: [
            FirmwareSMC.WriteAnswer.refuses(code: 0x89), .refuses(code: 0xC7),
            .refuses(code: 0xCB), .refuses(code: 0xD8),
            .unanswered(.truncatedReply(expected: 80, received: 0), applied: false),
        ])
    func anotherFirstAnswerThrows(_ answer: FirmwareSMC.WriteAnswer) async throws {
        let fixture = WritePlaneFixture()
        let mark = await fixture.prepared()
        await fixture.firmware.queueWrites(to: Self.modeZero, [answer])

        fixture.plane.beginEngagement(fanAt: 0)
        let error = await #expect(throws: (any Error).self) {
            try await fixture.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(error.map(Self.isRefusedControl) == true, "\(answer): \(String(describing: error))")
        let operations = fixture.operations(since: mark)
        #expect(operations.last?.isWrite == true, "\(answer): something followed the write")
        #expect(fixture.writes(since: mark) == ["F0Md=1"])
    }

    // MARK: - C18: the read-back

    /// Read back raw `1`, the step is engaged; `0` (accepted, not applied) or any other value is
    /// `.engagementNotConfirmed` with the raw byte.
    ///
    /// **Mutation:** in `EngagementRules.isEngagedMode`, answer `rawMode != 0`. Run: red here, on
    /// the 2 and 3 rows.
    @Test(
        "A read-back of 1 is engaged, and any other raw value is not confirmed",
        arguments: [UInt8(0), 1, 2, 3])
    func theReadBackDecides(_ raw: UInt8) async throws {
        let fixture = WritePlaneFixture(unlock: .readsBack(rawMode: raw))
        await fixture.prepared()

        fixture.plane.beginEngagement(fanAt: 0)
        if raw == 1 {
            #expect(try await fixture.plane.engageManualControl(of: Self.fan(0)) == .engaged)
        } else {
            await #expect(
                throws: FanControlPlaneError.engagementNotConfirmed(index: 0, rawMode: raw)
            ) {
                try await fixture.plane.engageManualControl(of: Self.fan(0))
            }
        }
    }
}

// MARK: - C23–C25: what the turns log, and C25's target that will not read

extension SMCWritePlaneTests {

    /// Every write call is logged once, restores and refusals included, with its key, its bytes and
    /// its answer — and nothing else is logged as a write.
    ///
    /// **Mutation:** in `SMCWriteTurns.issue`, log only an `.accepted` answer. Run: red here.
    @Test("Every write is logged once, whatever it answered")
    func everyWriteIsLoggedOnce() async throws {
        let fixture = WritePlaneFixture(unlock: .heldUntilForced(stepsToYield: 0))
        let mark = await fixture.prepared()
        try await fixture.engage(0)
        try await fixture.plane.commandTarget(Self.fan(0).target(for: 2_400))
        await fixture.firmware.queueWrites(to: Self.modeZero, [.refuses(code: 0x85)])
        await #expect(throws: (any Error).self) {
            try await fixture.plane.restoreToAutomatic(.fan(0))
        }

        let writes = fixture.operations(since: mark).filter(\.isWrite).count
        let logged = fixture.lines.lines(containing: "Wrote ")
        #expect(writes == 6, "\(fixture.writes(since: mark))")
        #expect(logged.count == writes, "\(logged)")
        #expect(fixture.lines.lines(containing: "Wrote F0Md = 0x0: answered 0x85").count == 1)
        #expect(fixture.lines.lines(containing: "Wrote Ftst = 0x1: answered 0x00").count == 1)
    }

    /// A step's line carries the raw values before and after and how it ended; the engaged turn
    /// logs the raw target it read and that it held the floor. The raise's line is
    /// `anEngagementAtRestRaisesTheTarget`'s.
    ///
    /// **Mutation:** in `SMCWriteTurns.beforeTheModeWrite`, delete `trace.before = hex(rawMode)`.
    /// Run: red here.
    @Test("A step logs the raw mode before and after, and the engaged turn the raw target")
    func aStepLogsItsRawValues() async throws {
        let fixture = WritePlaneFixture()
        await fixture.prepared()
        try await fixture.engage(0)

        let step = fixture.lines.lines(containing: "Fan 0's first engagement step")
        #expect(step.count == 1, "\(fixture.lines.lines)")
        #expect(step.first?.contains("raw F0Md 0x0 before") == true, "\(step)")
        #expect(step.first?.contains("0x1 after; engaged") == true, "\(step)")
        #expect(
            fixture.lines.lines(
                containing:
                    "Fan 0 read back engaged with raw F0Tg 0x0 0xc0 0xa8 0x44 (1350.0 RPM): "
                    + "held at or above its floor; nothing written."
            ).count == 1, "\(fixture.lines.lines)")
    }

    /// C25, inverted by ADR 0014's P1′ amendment (decision 4): a target the engaged turn cannot
    /// read, or that is not finite, has no floor to be judged by. The step throws `.readFailed`
    /// after its mode write, writes no target, is recorded refused and leaves the fan out of the
    /// engaged set, and the driver undoes. Before P1′ the read was a record and the step engaged.
    ///
    /// **Mutation:** in `SMCWriteTurns.holdFloor`, `return` from the target read's `catch`, taking
    /// a target that did not read as held. Run: red here, on the unread row.
    @Test(
        "A target that will not read, or is not finite, in the engaged turn fails the step",
        arguments: ["unread", "not finite"])
    func anUnreadTargetFailsTheStep(_ target: String) async throws {
        let fixture = WritePlaneFixture()
        let mark = await fixture.prepared()
        if target == "unread" {
            await fixture.firmware.setRead(of: Self.targetZero, .lost(Self.kernelError))
        } else {
            await fixture.firmware.setRegister(Self.targetZero, FirmwareSMC.flt(rpm: .nan))
        }
        let ledger = try fixture.ledger

        fixture.plane.beginEngagement(fanAt: 0)
        let error = await #expect(throws: FanControlPlaneError.self) {
            try await fixture.plane.engageManualControl(of: Self.fan(0))
        }
        guard case .readFailed(let detail)? = error else {
            Issue.record("\(target): the step threw \(String(describing: error)), not the target's")
            return
        }
        #expect(detail.hasPrefix("F0Tg after the engaged read-back"), "\(target): \(detail)")
        #expect(fixture.writes(since: mark) == ["F0Md=1"], "\(target): a target was written")
        #expect(ledger.engagedFans.isEmpty, "\(target)")
        #expect(!ledger.isCurrent(fanAt: 0), "\(target): the step was not recorded refused")
        let holds = fixture.lines.lines(containing: "Fan 0 read back engaged with raw F0Tg")
        #expect(holds.count == 1, "\(target): \(fixture.lines.lines)")
        #expect(holds.allSatisfy { $0.contains(": threw readFailed") }, "\(holds)")
    }

    // MARK: - C26: round trips per turn

    /// Every turn the plane takes stays within its bound. The engaged step — the one that reads
    /// back `1` — stays within `WatchdogLimits.engagedStepRoundTrips`, whatever the key-info cache
    /// holds: raising the floor at rest it is eight with `F0Tg`'s key info cached and **nine**, the
    /// bound itself, when the key's info failed at preparation and answers by the engaged turn, so
    /// that the target's read takes it; holding under load it is five and six. The floor's write
    /// and read-back still land (ADR 0012's 2026-10-31 amendment). Every other turn stays within
    /// `writeTurnRoundTrips`: a held first step that sets the key five, a waiting later step three,
    /// a command three, a `.fan(n)` restore one or two, a machine-wide one three.
    ///
    /// **Mutations:** `engagedStepRoundTrips` at 8. Run: red here, at the cold raise. In
    /// `SMCWriteTurns.holdFloor`, read the target twice (the cold raise becomes ten). Run: red
    /// here. **C27's premise:** in `SMCWriteTurns.survey`, take no target key info. Run: red here,
    /// the warm rows become nine and six.
    @Test("Every step, command and restore turn stays within its round trips")
    func everyTurnStaysWithinItsRoundTrips() async throws {
        let fixture = WritePlaneFixture(unlock: .heldUntilForced(stepsToYield: 1))
        let mark = await fixture.prepared()

        try await fixture.engage(0)
        try await fixture.plane.commandTarget(Self.fan(0).target(for: 2_400))
        try await fixture.plane.restoreToAutomatic(.fan(0))
        try await fixture.plane.restoreToAutomatic(.everyFan)

        let perTurn = fixture.roundTripsPerTurn(since: mark)
        #expect(perTurn == [5, 3, 5, 3, 2, 3], "\(perTurn)")
        #expect(perTurn.allSatisfy { $0 <= WatchdogLimits.writeTurnRoundTrips })

        let naive = WritePlaneFixture()
        let naiveMark = await naive.prepared()
        try await naive.engage(0)
        let underLoad = naive.roundTripsPerTurn(since: naiveMark)
        #expect(underLoad == [5])

        let atRest = WritePlaneFixture(stoppedByApple: [0, 1])
        let restMark = await atRest.prepared()
        try await atRest.engage(0)
        let raised = atRest.roundTripsPerTurn(since: restMark)
        #expect(raised == [8])

        // Cold: `F0Tg`'s key info failed at preparation and answers by the engaged turn.
        let bound = WatchdogLimits.engagedStepRoundTrips
        let coldRest = try await Self.engagedCold(stoppedByApple: [0, 1])
        #expect(coldRest.turns == [9], "at rest: \(coldRest.turns)")
        #expect(coldRest.turns == [bound], "the cold raise is not the bound, \(bound)")
        #expect(coldRest.target == Self.floorBytes, "the cold raise did not land")
        let coldLoad = try await Self.engagedCold(stoppedByApple: [])
        #expect(coldLoad.turns == [6], "under load: \(coldLoad.turns)")
        let engaged = underLoad + raised + coldRest.turns + coldLoad.turns
        #expect(engaged.allSatisfy { $0 <= bound }, "\(engaged)")
    }

    /// Engages fan 0 on a fixture whose `F0Tg` key info fails at preparation and is declared again
    /// before the engagement, and answers the engagement's round trips per turn and the target.
    private static func engagedCold(
        stoppedByApple: Set<Int>
    ) async throws -> (turns: [Int], target: [UInt8]?) {
        let fixture = WritePlaneFixture(stoppedByApple: stoppedByApple)
        let info = SMCKeyInfo(key: Self.targetZero, type: .flt, dataSize: 4, attributes: 0xD4)
        await fixture.firmware.declare(Self.targetZero, .keyInfoFails(.firmware(code: 0x85)))
        let mark = await fixture.prepared()
        await fixture.firmware.declare(Self.targetZero, .present(info))
        try await fixture.engage(0)
        let target = await fixture.firmware.register(Self.targetZero)
        return (fixture.roundTripsPerTurn(since: mark), target)
    }
}
