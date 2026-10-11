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
        lines: RecordedHelperFanLines = RecordedHelperFanLines()
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
            log: HelperLog(
                subsystem: "dev.aeolus.AeolusHelperTests", category: "PanicVerb",
                recordingFanLines: { lines.append($0, $1) }),
            leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
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
    /// that logged at fault on every call would satisfy that test too.
    ///
    /// **Mutation:** delete the `try await keystone.restoreToAutomatic(.everyFan)` statement from
    /// `SupervisedFanAuthority.restoreAllToAutomatic`. Run: red on the restore list and the key.
    @Test("On a plane that can write, the panic verb issues the machine-wide restore once")
    func aBuiltPlaneGetsTheMachineWideRestore() async throws {
        let lines = RecordedHelperFanLines()
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
    }

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
    /// red on the restore list.
    @Test("On a plane that cannot write, the panic verb issues no machine-wide restore")
    func aPlaneThatCannotWriteGetsNoMachineWideRestore() async throws {
        let helper = Self.composed()
        try await Self.holdFanZero(in: helper) {
            await helper.plane.setMode(.manual, ofFan: 0)
        }
        await helper.plane.setForceKey(true)
        let capability = LeaseFixture.writePathNotBuilt()
        #expect(capability.writeCapability == .notBuilt, "this test is vacuous on a .built seam")
        let authority = SupervisedFanAuthority(
            reading: helper.reading, leases: helper.leases,
            reconciliation: helper.reconciliation,
            keystone: helper.plane, writeCapability: capability,
            log: HelperRestorerTests.helperLog)

        try await authority.restoreAllToAutomatic(from: ConnectionID())

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
    @Test("A refused machine-wide restore is logged at fault and the panic verb still succeeds")
    func aRefusedMachineWideRestoreIsLoggedAndAccepted() async throws {
        let lines = RecordedHelperFanLines()
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
    }
}
