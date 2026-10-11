import AeolusXPC
import FanKit
import Testing

@testable import AeolusHelper

/// § 7's machine-wide restore ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D5): the
/// panic verb issues `restoreToAutomatic(.everyFan)` if and only if the plane can write, between
/// the lease release and the read-back, and a refusal of it is logged and never fails the
/// message.
///
/// Composed for `HelperRestorerTests`' reason: what is under test is wiring — which roles
/// `SupervisedFanAuthority` was handed, and in what order its body uses them — so every test but
/// one drives `helper.authority`, the object the listener is given. The exception is the
/// `.notBuilt` test, which builds a second authority over the composed lease core: no composed
/// plane both records its restores and answers `.notBuilt`, because a plane that reports no
/// write path takes none, and the two roles are injected apart precisely so that this one
/// question can be asked. Its capability comes from the production `SMCFanControlPlane`.
///
/// `fanctl reset --all` against corrupted helper state, through the real client and listener,
/// is `FanctlResetCorruptedStateTests`. The supervisors are not started.
@Suite("§ 7's machine-wide restore", .timeLimit(.minutes(1)))
struct PanicVerbMachineWideRestoreTests {

    /// One composed helper over scripted firmware whose every write the stage answers with
    /// `writes`, and a log whose fan lines the test can read.
    private static func composed(
        fans: [Int: ScriptedControlPlane.FanCondition] = [0: .automatic(at: 2_400)],
        writes: ScriptedControlPlane.WriteBehaviour = .honoured,
        lines: RecordedHelperLines = RecordedHelperLines()
    ) -> HelperComposition<ScriptedControlPlane> {
        HelperComposition(
            plane: ScriptedControlPlane(
                fans: fans,
                stages: [
                    .nominal(temperatures: LeaseFixture.nominalDieTemperatures, writes: writes)
                ]),
            snapshotProvider: fanProvider(fanCount: fans.count),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            log: Self.log(into: lines),
            leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    /// A helper log whose every line, level included, lands in `lines`.
    private static func log(into lines: RecordedHelperLines) -> HelperLog {
        HelperLog(
            subsystem: "dev.aeolus.AeolusHelperTests", category: "PanicVerb",
            recording: { lines.append($0, $1) })
    }

    /// A lease over fan 0, with the firmware put into manual as E3's engage write would.
    private static func holdFanZero<Plane: FanControlPlane>(
        in helper: HelperComposition<Plane>, setManual: () async -> Void
    ) async throws {
        await helper.bindSafetyRegistries()
        try await HelperRestorerTests.engage(fan: 0, in: helper)
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        await setManual()
    }

    private static func restores(_ plane: ScriptedControlPlane) async -> [FanRestoreScope] {
        await plane.attempts.compactMap {
            if case .restoreToAutomatic(let scope) = $0 { return scope }
            return nil
        }
    }

    // MARK: - A plane that can write

    /// On a `.built` plane the panic verb issues the machine-wide restore once, after the
    /// sweep's per-fan restore, and the force key a dead holder left set is cleared by it.
    ///
    /// The fault-line assertion is the other half of the refusal test below: without it, a body
    /// that logged at fault on every call would satisfy that test too. The closing line says the
    /// firmware accepted the restore, and only this test can tell that line from the other three.
    ///
    /// **Mutation:** delete the `try await keystone.restoreToAutomatic(.everyFan)` statement from
    /// `SupervisedFanAuthority.restoreAllToAutomatic`. Run: red on the restore list and the key.
    /// **Mutation:** in that body, set `machineWide = .notIssued` where it sets `.accepted`.
    /// Run: red on the closing line.
    @Test("On a plane that can write, the panic verb issues the machine-wide restore once")
    func aBuiltPlaneGetsTheMachineWideRestore() async throws {
        let lines = RecordedHelperLines()
        let helper = Self.composed(lines: lines)
        try await Self.holdFanZero(in: helper) {
            await helper.plane.setMode(.manual, ofFan: 0)
        }
        await helper.plane.setForceKey(true)

        try await helper.authority.restoreAllToAutomatic(from: ConnectionID())

        let restores = await Self.restores(helper.plane)
        #expect(restores == [.fan(0), .everyFan], "the panic verb's restores were \(restores)")
        #expect(
            await helper.plane.isForceKeySet == false,
            "the force key a dead holder left set survived fanctl reset --all")
        #expect(await helper.leases.leaseCount == 0)
        #expect(lines.levels(containing: "machine-wide restore that connection").isEmpty)
        #expect(
            lines.levels(containing: Self.acceptedLine) == [.notice],
            "the panic path's closing line does not say the firmware accepted the restore")
    }

    /// The closing line's three phrases, one per outcome a composed authority can reach.
    static let acceptedLine = "the firmware accepted the machine-wide restore"
    static let noWritePathLine = "because the plane reports no SMC write path"
    static let refusedLine = "the machine-wide restore was refused (the fault line"

    // MARK: - A plane that cannot write

    /// On a `.notBuilt` plane the panic verb issues no machine-wide restore, and still drops
    /// every lease and sweeps its fans.
    ///
    /// The keystone role here is the scripted plane, which records every restore; the capability
    /// is the real `SMCFanControlPlane`'s `.notBuilt`. So a `.everyFan` in the record can only
    /// mean the body issued one without asking.
    ///
    /// **Mutation:** drop the `if writeCapability.writeCapability == .built` condition from
    /// `SupervisedFanAuthority.restoreAllToAutomatic`, issuing the restore unconditionally. Run:
    /// red on the restore list. **Mutation:** start `machineWide` at `.notIssued` rather than
    /// `.noWritePath`. Run: red on the closing line.
    @Test("On a plane that cannot write, the panic verb issues no machine-wide restore")
    func aPlaneThatCannotWriteGetsNoMachineWideRestore() async throws {
        let helper = Self.composed()
        try await Self.holdFanZero(in: helper) {
            await helper.plane.setMode(.manual, ofFan: 0)
        }
        await helper.plane.setForceKey(true)
        let capability = LeaseFixture.writePathNotBuilt()
        #expect(capability.writeCapability == .notBuilt, "this test is vacuous on a .built seam")
        let lines = RecordedHelperLines()
        let authority = SupervisedFanAuthority(
            reading: helper.reading, leases: helper.leases,
            reconciliation: helper.reconciliation,
            keystone: helper.plane, writeCapability: capability, log: Self.log(into: lines))

        try await authority.restoreAllToAutomatic(from: ConnectionID())
        #expect(
            lines.levels(containing: Self.noWritePathLine) == [.notice],
            "the closing line does not say the restore was withheld for want of a write path")

        let restores = await Self.restores(helper.plane)
        #expect(
            restores == [.fan(0)],
            """
            a build that cannot write issued \(restores). On every \
            build on main the plane throws for that call, and a build that cannot write cannot \
            have put a fan into manual.
            """)
        #expect(await helper.leases.leaseCount == 0, "the lease release is not conditional")
        #expect(await helper.plane.isForceKeySet, "nothing on this build may clear the key")
    }

    /// The **composed** helper over a plane that cannot write: `helper.authority`, as the
    /// listener gets it, issues no machine-wide restore — so the composition hands the authority
    /// the plane's own capability, and not some other answer.
    ///
    /// The test above builds its authority by hand, so it cannot see how `HelperComposition`
    /// wires the capability; this one cannot see anything else. On `.notBuilt` no lease can be
    /// granted, so the only state to set up is what a build that cannot write can still find:
    /// a fan another tool left in manual, and a force key a dead holder left set. Both stay.
    ///
    /// **Mutation:** in `HelperComposition.init`, pass the authority
    /// `writeCapability: AlwaysBuilt()` — a reporter answering `.built` — instead of `plane`.
    /// Run: red on the restore list, the key and the closing line.
    @Test("The composed helper over a plane that cannot write issues no machine-wide restore")
    func theCompositionAsksThePlaneItCannotWrite() async throws {
        let lines = RecordedHelperLines()
        let firmware = ScriptedControlPlane(
            fans: [0: .init(mode: .manual)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let helper = HelperComposition(
            plane: ControlStateGatePlane(firmware, capability: .notBuilt),
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            log: Self.log(into: lines),
            leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
        await firmware.setForceKey(true)
        #expect(helper.plane.writeCapability == .notBuilt, "this test is vacuous on a .built plane")

        try await helper.authority.restoreAllToAutomatic(from: ConnectionID())

        let restores = await helper.plane.restoreAttempts
        #expect(restores.isEmpty, "the shipped composition issued \(restores) on .notBuilt")
        #expect(await firmware.isForceKeySet, "nothing on a build that cannot write may clear it")
        #expect(
            try await firmware.readControlState(ofFan: 0).mode == .manual,
            "a build that cannot write put another tool's fan back")
        #expect(lines.levels(containing: Self.noWritePathLine) == [.notice])
    }

    /// `ReadOnlyFanAuthority`'s closing line gives "no SMC write path" as the cause only when its
    /// seam said so; behind a seam that can write it says only that it issues no machine-wide
    /// restore. That type answers the panic verb with a no-op whatever the seam can do.
    ///
    /// **Mutation:** in `ReadOnlyFanAuthority.restoreAllToAutomatic`, pass `.noWritePath`
    /// unconditionally. Run: red on the seam that can write.
    @Test(
        "The read-only authority's closing line names a cause only when it asked the seam",
        arguments: [false, true])
    func theReadOnlyLineNamesOnlyACauseItChecked(seamCanWrite: Bool) async throws {
        let lines = RecordedHelperLines()
        let provider = fanProvider(fanCount: 1)
        let capability: any FanWriteCapabilityReporting =
            seamCanWrite ? ScriptedControlPlane(fans: [:]) : LeaseFixture.writePathNotBuilt()
        let authority = ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider),
            log: Self.log(into: lines),
            thermalEmergency: ThermalEmergencyLatch(),
            reclamation: ReclamationLedger(),
            writeCapability: capability)

        try await authority.restoreAllToAutomatic(from: ConnectionID())

        let named = lines.levels(containing: Self.noWritePathLine)
        let bare = lines.levels(containing: "this authority issues none")
        #expect(named == (seamCanWrite ? [] : [.notice]), "the cause line was \(named)")
        #expect(bare == (seamCanWrite ? [.notice] : []), "the cause-free line was \(bare)")
    }

    // MARK: - Errors no stage throws

    /// A keystone that throws a fixed error: the two `FanControlPlaneError`s the catch must
    /// absorb that no scripted stage produces, since a stage refuses only with
    /// `.firmwareRefusedControl`.
    private struct ThrowingKeystone: KeystoneRestoring {
        let error: FanControlPlaneError
        func restoreToAutomatic(_ scope: FanRestoreScope) async throws { throw error }
    }

    /// Whatever the keystone throws, the panic verb does not: through a real
    /// `HelperConnectionSession` the reply is success — v1's *accepted* — and the refusal is one
    /// fault line. `.controlPathNotBuilt` behind a `.built` capability is a state no executable
    /// can be in, which is the point: the catch must not depend on which errors are plausible.
    ///
    /// **Mutation:** narrow the `catch` to `catch FanControlPlaneError.firmwareRefusedControl`,
    /// rethrowing the rest. Run: red for both errors — the reply is a failure.
    @Test(
        "Any error from the keystone is caught, logged at fault, and answered accepted",
        arguments: [
            FanControlPlaneError.controlPathNotBuilt,
            .readFailed(detail: "F0Md did not answer"),
        ])
    func anyKeystoneErrorIsAbsorbed(_ error: FanControlPlaneError) async throws {
        let lines = RecordedHelperLines()
        let helper = Self.composed()
        let authority = SupervisedFanAuthority(
            reading: helper.reading, leases: helper.leases,
            reconciliation: helper.reconciliation,
            keystone: ThrowingKeystone(error: error), writeCapability: helper.plane,
            log: Self.log(into: lines))
        let session = HelperConnectionSession(
            id: ConnectionID(), authority: authority, helperBuild: "test",
            log: Self.log(into: lines))

        let reply = await session.restoreAllToAutomatic()

        #expect(reply.isSuccess, "\(error) from the keystone failed the panic verb's reply")
        #expect(lines.levels(containing: "machine-wide restore that connection") == [.fault])
        #expect(lines.levels(containing: Self.refusedLine) == [.notice])
    }

    // MARK: - The order

    /// With the read-back parked, the machine-wide restore has already been issued: the read
    /// follows the keystone and is never queued ahead of it (ADR 0007's 2026-09-20 amendment).
    ///
    /// Fan 0's handback is refused, so it is abandoned; the firmware comes good; the panic
    /// verb's sweep restores fan 0, which marks it owed a read-back, and `.everyFan` is issued.
    /// Only then may the read go out. `ControlStateGatePlane` parks it, so the order is an
    /// observation rather than an argument — `ScriptedControlPlane`'s methods never suspend.
    ///
    /// **Mutation:** in `SupervisedFanAuthority.restoreAllToAutomatic`, move
    /// `await leases.confirmAcceptedHandbacks()` above the `.built` block. Run: red — with the
    /// read parked, no `.everyFan` has been issued, so a read that never returns would hold the
    /// machine-wide restore for ever.
    @Test("The read-back is issued after the machine-wide restore, never ahead of it")
    func theKeystoneIsNotQueuedBehindTheReadBack() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)],
            stages: [
                .nominal(
                    temperatures: LeaseFixture.nominalDieTemperatures,
                    writes: .refused(reason: "firmware answered 0x82")),
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures),
            ])
        let helper = HelperComposition(
            plane: ControlStateGatePlane(firmware),
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
        await helper.bindSafetyRegistries()
        try await HelperRestorerTests.engage(fan: 0, in: helper)
        let connection = ConnectionID()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        await firmware.setMode(.manual, ofFan: 0)
        try await helper.leases.releaseLease(id: lease.id, from: connection)
        #expect(
            await helper.leases.fansWithAbandonedHandbacks == [0],
            "the setup did not abandon fan 0, so the panic verb has nothing to read back")
        await firmware.advance()

        await helper.plane.modeReads(.held)
        let panic = observing {
            try await helper.authority.restoreAllToAutomatic(from: ConnectionID())
        }
        let parked = await yieldUntil("the panic verb's read-back to park") {
            await helper.plane.heldModeReads == 1
        }

        let issued = await helper.plane.restoreAttempts
        #expect(parked)
        #expect(
            issued.last == .everyFan && issued.filter { $0 == .everyFan }.count == 1,
            """
            the read-back went out before the machine-wide restore (restores so far: \
            \(issued)). A read that never returns would hold the keystone behind it.
            """)

        await helper.plane.modeReads(.answered)
        _ = try await finished("the panic verb to finish once the read is let through", panic)
        #expect(
            await helper.leases.fansWithAbandonedHandbacks.isEmpty,
            "the read after the keystone found fan 0 automatic and did not lift its refusal")
    }

    // MARK: - A refusal

    /// A machine-wide restore the firmware refuses is logged at fault, and the panic verb still
    /// succeeds: v1's reply is *accepted* in every case, so no `AeolusXPCVersion` bump.
    ///
    /// Fan 0 is in manual under no lease, and the force key is set. Both stay as they were —
    /// the firmware refused — and the fault line is the only report of the key, which has no
    /// snapshot field.
    ///
    /// **Mutation:** in `SupervisedFanAuthority.restoreAllToAutomatic`, delete the
    /// `log.panicRestoreRefused(...)` call from the `catch`, swallowing the refusal. Run: red on
    /// the fault line.
    /// **Mutation:** replace the `do`/`catch` with a bare `try await`, so the refusal
    /// propagates. Run: red — the panic verb throws.
    /// **Mutation:** in the `catch`, set `machineWide = .accepted` rather than `.refused`. Run:
    /// red on the closing line, which would otherwise tell an operator the firmware took it.
    @Test("A refused machine-wide restore is logged at fault and the panic verb still succeeds")
    func aRefusedMachineWideRestoreIsLoggedAndAccepted() async throws {
        let lines = RecordedHelperLines()
        let helper = Self.composed(
            fans: [0: .init(mode: .manual)],
            writes: .refused(reason: "firmware answered 0x82"),
            lines: lines)
        await helper.plane.setForceKey(true)

        try await helper.authority.restoreAllToAutomatic(from: ConnectionID())

        #expect(await Self.restores(helper.plane) == [.everyFan], "the restore was not issued")
        #expect(
            lines.levels(containing: "machine-wide restore that connection") == [.fault],
            """
            a refused machine-wide restore was not reported at fault level, so a force key left \
            set is reported by nothing at all.
            """)
        #expect(await helper.plane.isForceKeySet, "a refused write cleared the key")
        #expect(
            lines.levels(containing: Self.refusedLine) == [.notice],
            "the closing line does not say the machine-wide restore was refused")
        #expect(lines.levels(containing: Self.acceptedLine).isEmpty)
    }
}
