import Foundation
import IOKit
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The production plane's write verbs over `FirmwareSMC` (b2): the real scheduler, the real ledger
/// and the real turn bodies, only IOKit faked. This file is the engagement step (ADR 0014 D3, the
/// B1 amendment's rulings); the command, the restore, the preparation step and the bridge are in
/// the `SMCWritePlaneTests+…` files.
@Suite("The production write plane over the fake SMC", .timeLimit(.minutes(1)))
struct SMCWritePlaneTests {

    static let modeZero = smcKey("F0Md")
    static let modeOne = smcKey("F1Md")
    static let targetZero = smcKey("F0Tg")
    static let forceKey = SMCKey.forceTest

    /// A kernel return that is not `kIOReturnNotOpen`: the other cause of `connectionFailed`.
    static let kernelError = SMCError.connectionFailed(kernReturn: kIOReturnError)

    static func fan(_ index: Int) throws -> CommandableFan { try WritePlaneFixture.fan(index) }

    static func isFailedBeforeFirstWrite(_ error: any Error) -> Bool {
        if case .failedBeforeFirstWrite? = error as? FanControlPlaneError { return true }
        return false
    }

    static func isReadFailed(_ error: any Error) -> Bool {
        if case .readFailed? = error as? FanControlPlaneError { return true }
        return false
    }

    static func isRefusedControl(_ error: any Error) -> Bool {
        if case .firmwareRefusedControl? = error as? FanControlPlaneError { return true }
        return false
    }

    // MARK: - C2: the ticket

    /// The ticket is the ledger's: a step with none is `.superseded` at its admission, having read
    /// nothing, and one taken through the plane admits the first step.
    ///
    /// **Mutation:** make `SMCFanControlPlane.beginEngagement(fanAt:)` do nothing. Run: red here,
    /// at the step after the ticket.
    @Test("The ticket is forwarded to the ledger: no ticket, no step, nothing read")
    func theTicketIsForwardedToTheLedger() async throws {
        let fixture = WritePlaneFixture()
        let mark = await fixture.prepared()

        await #expect(throws: FanControlPlaneError.superseded) {
            try await fixture.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(fixture.operations(since: mark).isEmpty, "\(fixture.operations(since: mark))")

        fixture.plane.beginEngagement(fanAt: 0)
        #expect(try await fixture.plane.engageManualControl(of: Self.fan(0)) == .engaged)
    }

    // MARK: - C9: the order, and C8: the raw byte

    /// A first step on a fan that yields at once: the mode key's fresh info, its raw pre-state,
    /// `F0Md = 1`, the read-back, and the logged target — in that order, in one supervisor turn.
    ///
    /// **Mutation:** move the raw pre-state read after the write — `beforeTheModeWrite` returns
    /// before reading, and `unlockStep` reads and decides it after `issue`. Run: red here, at the
    /// operation order.
    @Test("A first step is key info, the raw pre-state, the write, the read-back, in one turn")
    func aFirstStepReadsThenWritesThenReadsBack() async throws {
        let fixture = WritePlaneFixture()
        let mark = await fixture.prepared()

        try await fixture.engage(0)

        #expect(
            fixture.operations(since: mark) == [
                .keyInfo(Self.modeZero, .answered), .read(Self.modeZero, .answered),
                .write(Self.modeZero, [0x01], .answered), .read(Self.modeZero, .answered),
                .read(Self.targetZero, .answered),
            ])
        #expect(fixture.turns(since: mark).map(\.priority) == [.supervisor])
        #expect(try fixture.ledger.engagedFans == [0])
        #expect(try fixture.ledger.touchedFans == [0])
    }

    /// A fan whose raw mode reads `2` is not Aeolus's to take: `.notAutomatic` carries the byte as
    /// read, decided by `EngagementRules.requireAutomatic`, and nothing is written.
    ///
    /// **Mutation:** in `SMCWriteTurns.beforeTheModeWrite`, decide on the fold's answer,
    /// `rawMode == 0 ? 0 : 1`, instead of the raw byte. Run: red here — `rawMode: 1`.
    @Test("A raw mode of 2 is refused notAutomatic with the raw byte, and nothing is written")
    func aRawModeOfTwoIsNotAutomatic() async throws {
        let fixture = WritePlaneFixture()
        let mark = await fixture.prepared()
        await fixture.firmware.setRegister(Self.modeZero, [0x02])

        fixture.plane.beginEngagement(fanAt: 0)
        await #expect(throws: FanControlPlaneError.notAutomatic(index: 0, rawMode: 2)) {
            try await fixture.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(fixture.writes(since: mark).isEmpty)
    }

    // MARK: - C10: every throw after admission is recorded

    /// How a step can fail after its admission, one per row of C10's table.
    enum StepFailure: String, CaseIterable, Sendable {
        case notAutomatic, preStateUnread, refusedCode, unanswered, notConfirmed, readBackLost
        case supersededAfterWrite
    }

    private static func scripted(_ failure: StepFailure) async throws -> WritePlaneFixture {
        switch failure {
        case .notConfirmed:
            let fixture = WritePlaneFixture(unlock: .readsBack(rawMode: 0))
            await fixture.prepared()
            return fixture
        case .supersededAfterWrite:
            let fixture = WritePlaneFixture(unlock: .heldUntilForced(stepsToYield: 0))
            await fixture.prepared()
            let ledger = try fixture.ledger
            await fixture.firmware.onAfter(.write(Self.modeZero)) {
                ledger.restoreRequested(.fan(1))
            }
            return fixture
        default:
            let fixture = WritePlaneFixture()
            await fixture.prepared()
            switch failure {
            case .notAutomatic: await fixture.firmware.setRegister(Self.modeZero, [0x02])
            case .preStateUnread:
                await fixture.firmware.setRead(of: Self.modeZero, .failsWithCode(0x85))
            case .refusedCode:
                await fixture.firmware.queueWrites(to: Self.modeZero, [.refuses(code: 0x89)])
            case .unanswered:
                await fixture.firmware.queueWrites(
                    to: Self.modeZero, [.unanswered(Self.kernelError, applied: true)])
            case .readBackLost:
                await fixture.firmware.queueReads(
                    of: Self.modeZero,
                    [.answers, .lost(.truncatedReply(expected: 80, received: 0))])
            case .notConfirmed, .supersededAfterWrite: break
            }
            return fixture
        }
    }

    /// Every throw after a first step's admission records the step refused, so the engagement is
    /// over and no later step is admitted under it (`isCurrent` false).
    ///
    /// **Mutation:** in `SMCWriteTurns.step`, skip `recordStepRefused(fanAt:)` when the error is
    /// `.notAutomatic`. Run: red here, on that row only.
    @Test("Every throw after admission records the step refused", arguments: StepFailure.allCases)
    func everyThrowAfterAdmissionIsRecorded(_ failure: StepFailure) async throws {
        let fixture = try await Self.scripted(failure)
        let ledger = try fixture.ledger

        fixture.plane.beginEngagement(fanAt: 0)
        await #expect(throws: (any Error).self) {
            try await fixture.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(!ledger.isCurrent(fanAt: 0), "\(failure): the step's record outlived its throw")
        #expect(ledger.engagedFans.isEmpty)
    }
}

// MARK: - C11: what fails before the first write, and what fails after it

extension SMCWritePlaneTests {

    /// A first step that fails before its write call — the pre-state read, the mode key's info, or
    /// a declared type other than the observed `ui8` of one byte — throws
    /// `.failedBeforeFirstWrite`, with nothing written.
    @Test(
        "A first step that fails before its write is failedBeforeFirstWrite, with nothing written",
        arguments: ["pre-state", "key info", "declared type"])
    func aFirstStepThatFailsBeforeItsWrite(_ cause: String) async throws {
        let fixture = WritePlaneFixture()
        let mark = await fixture.prepared()
        switch cause {
        case "pre-state":
            await fixture.firmware.setRead(of: Self.modeZero, .failsWithCode(0x85))
        case "key info":
            await fixture.firmware.declare(Self.modeZero, .keyInfoFails(Self.kernelError))
        default:
            await fixture.firmware.declare(
                Self.modeZero,
                .present(SMCKeyInfo(key: Self.modeZero, type: .ui16, dataSize: 2, attributes: 0xD0))
            )
        }

        fixture.plane.beginEngagement(fanAt: 0)
        let error = await #expect(throws: (any Error).self) {
            try await fixture.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(
            error.map(Self.isFailedBeforeFirstWrite) == true,
            "\(cause): \(String(describing: error))")
        #expect(fixture.writes(since: mark).isEmpty)
    }

    /// Once a write call is made the engagement has written, so a failure after it is thrown as it
    /// is: a first step's lost read-back, and a later step's key-info failure, are `.readFailed`.
    ///
    /// **Mutations:** in `SMCWriteTurns.unlockStep`, throw the read-back's failure as
    /// `.failedBeforeFirstWrite`. Run: red here, at the read-back row. Separately, delete the
    /// `guard first else` line in `beforeTheModeWrite`, so a later step's failure is wrapped too.
    /// Run: red here, at the later-step row.
    @Test("A failure after the first write is thrown as it is, never failedBeforeFirstWrite")
    func aFailureAfterTheFirstWriteIsThrownAsItIs() async throws {
        let lostReadBack = WritePlaneFixture()
        await lostReadBack.prepared()
        await lostReadBack.firmware.queueReads(
            of: Self.modeZero, [.answers, .lost(.truncatedReply(expected: 80, received: 0))])
        lostReadBack.plane.beginEngagement(fanAt: 0)
        let afterWrite = await #expect(throws: (any Error).self) {
            try await lostReadBack.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(afterWrite.map(Self.isReadFailed) == true, "\(String(describing: afterWrite))")

        let later = WritePlaneFixture(unlock: .heldUntilForced(stepsToYield: 1))
        await later.prepared()
        later.plane.beginEngagement(fanAt: 0)
        #expect(try await later.plane.engageManualControl(of: Self.fan(0)) == .awaitingYield)
        await later.firmware.declare(Self.modeZero, .keyInfoFails(Self.kernelError))
        let laterStep = await #expect(throws: (any Error).self) {
            try await later.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(laterStep.map(Self.isReadFailed) == true, "\(String(describing: laterStep))")
    }

    // MARK: - C12: no cancellation once admitted

    /// A step whose task was cancelled before it asked still runs to its answer: the turn's wait is
    /// not cancellable and the job is synchronous, so nothing can throw a `CancellationError`
    /// between its admission and its last write.
    ///
    /// **Mutation:** add `try Task.checkCancellation()` after the admission in
    /// `SMCWriteTurns.step`.
    /// Run: red here.
    @Test("A step in a cancelled task is admitted and answers; it never throws CancellationError")
    func anAdmittedStepIsNotCancelled() async throws {
        let fixture = WritePlaneFixture()
        await fixture.prepared()
        let plane = fixture.plane
        let fan = try Self.fan(0)

        plane.beginEngagement(fanAt: 0)
        let step = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await plane.engageManualControl(of: fan)
        }
        #expect(try await step.value == .engaged)
    }

    // MARK: - C14: the mode write is recorded issued before the call

    /// A mode write the firmware does not answer may have landed, so the fan is touched before the
    /// call is made: with the bring-up enumeration failed, `.everyFan` still writes it — and the
    /// key — and then says the fan set was unknown.
    ///
    /// **Mutation:** in `SMCWriteTurns.unlockStep`, record the mode write issued after the call,
    /// and only when it answered `.accepted`. Run: red here — the restore writes the key alone.
    @Test("An unanswered mode write is touched, so a machine-wide restore writes that fan")
    func anUnansweredModeWriteIsRestored() async throws {
        let fixture = WritePlaneFixture()
        let mark = fixture.firmware.log.entries.count
        await fixture.firmware.queueWrites(
            to: Self.modeOne, [.unanswered(Self.kernelError, applied: false)])

        fixture.plane.beginEngagement(fanAt: 1)
        let error = await #expect(throws: (any Error).self) {
            try await fixture.plane.engageManualControl(of: Self.fan(1))
        }
        #expect(error.map(Self.isRefusedControl) == true, "\(String(describing: error))")

        await #expect(throws: FanControlPlaneError.fanSetUnknown(refusedWrite: nil)) {
            try await fixture.plane.restoreToAutomatic(.everyFan)
        }
        #expect(fixture.writes(since: mark) == ["F1Md=1", "F1Md=0", "Ftst=0"])
    }
}
