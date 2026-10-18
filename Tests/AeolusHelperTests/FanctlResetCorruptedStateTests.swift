import ArgumentParser
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl reset --all` against **deliberately corrupted** helper state: `docs/SAFETY.md` § 7's
/// *"integration tests invoked against a deliberately corrupted helper state"*, which #104 asks
/// for because a panic path exercised only on a working system is not a panic path.
///
/// End to end, as `FanctlResetTests` is: the shipping `run()`, the real `HelperClient`, a real
/// `NSXPCListener` and the real `HelperConnectionSession` — here in front of the **composed**
/// helper, so the authority behind the listener is the `SupervisedFanAuthority`
/// `HelperComposition` builds, over `ScriptedControlPlane` answering `.built`
/// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D8). Every build on `main` answers
/// `.notBuilt`, so this is the panic path as it will behave once a write path exists, and
/// nothing here is evidence about the hardware: row 18's hardware half is run 1's.
///
/// **The state is inconsistent on purpose**, and each inconsistency is one the panic verb has
/// to survive rather than one it can be expected to find tidy:
///
/// - **A lease whose connection is gone.** Fan 0 is held under a lease bound to a connection no
///   session will ever invalidate, so nothing but § 7 or its TTL ends it.
/// - **A fan in manual under no lease, and a registry that disagrees with the table.** Fan 1 is
///   off automatic control and registered with § 3, and no lease covers it. § 5 refuses a
///   registration under a lease that does not cover the fan since #357, so it cannot be put in
///   that state by registering; the refusal is part of the setup. It can still disagree with
///   the table another way — a lease that ends unannounced leaves its record until the next
///   examination hands it back — but the composed restorer announces every lease end.
/// - **A stale `restoreAbandoned` entry.** Fan 2's handback was refused, so its refusal stands,
///   and the firmware has since come good with nothing having asked it again.
/// - **A latched § 3 with nothing bridged under it.** The latch is engaged directly, as no cycle
///   would: it claims an emergency nothing is enacting, and refuses every grant meanwhile.
/// - **A force key set with nothing engaged** — what a helper that died holding it leaves.
///
/// The supervisors are not started: a § 5 or § 3 cycle would start repairing the state before
/// the command under test ever ran.
@Suite("fanctl reset --all against corrupted helper state", .timeLimit(.minutes(1)))
struct FanctlResetCorruptedStateTests {

    private static let refusing = ScriptedControlPlane.WriteBehaviour.refused(
        reason: "firmware answered 0x82")

    /// The composed helper over three fans, with `stages` as the firmware's script.
    private static func composed(
        fans: [Int: ScriptedControlPlane.FanCondition],
        stages: [ScriptedControlPlane.Stage],
        lines: RecordedHelperLines
    ) -> HelperComposition<ScriptedControlPlane> {
        HelperComposition(
            plane: ScriptedControlPlane(fans: fans, stages: stages),
            snapshotProvider: fanProvider(fanCount: fans.count),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            log: HelperLog(
                subsystem: "dev.aeolus.AeolusHelperTests", category: "ResetCorrupted",
                recording: { lines.append($0, $1) }),
            leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    /// Every restore the firmware was asked for, from `attempts[from...]`, in order.
    private static func restores(
        _ plane: ScriptedControlPlane, from start: Int
    ) async -> [FanRestoreScope] {
        await plane.attempts[start...].compactMap {
            if case .restoreToAutomatic(let scope) = $0 { return scope }
            return nil
        }
    }

    private static func modes(
        _ plane: ScriptedControlPlane, of fans: [Int]
    ) async throws -> [FirmwareFanMode] {
        var modes: [FirmwareFanMode] = []
        for fan in fans { modes.append(try await plane.readControlState(ofFan: fan).mode) }
        return modes
    }

    // MARK: - Every inconsistency at once

    /// The composed helper in every corrupted state the suite's header lists, at once, with the
    /// setup's own claims asserted — without them, every assertion after the command would be
    /// about some other state.
    private static func corrupted(
        lines: RecordedHelperLines
    ) async throws -> HelperComposition<ScriptedControlPlane> {
        let helper = Self.composed(
            fans: [0: .automatic(at: 2_400), 1: .automatic(at: 2_400), 2: .automatic(at: 2_400)],
            stages: [
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures, writes: Self.refusing),
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures),
            ],
            lines: lines)
        let plane = helper.plane
        await helper.bindSafetyRegistries()

        // Fan 2: held, released against a firmware that refuses — abandoned — and then the
        // firmware comes good with nothing having asked it again.
        let released = ConnectionID()
        let abandoned = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [2]), from: released)
        try await HelperRestorerTests.engage(fan: 2, in: helper, under: abandoned.id)
        await plane.setMode(.manual, ofFan: 2)
        try await helper.leases.releaseLease(id: abandoned.id, from: released)
        await plane.advance()

        // Fan 0: held under a lease whose connection no session will ever invalidate.
        let orphaned = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        try await HelperRestorerTests.engage(fan: 0, in: helper, under: orphaned.id)
        await plane.setMode(.manual, ofFan: 0)

        // Fan 1: registered with § 3, in manual, under no lease. § 5 refuses it: the only live
        // lease does not cover fan 1.
        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 1)) {
            try await HelperRestorerTests.engage(fan: 1, in: helper, under: orphaned.id)
        }
        await helper.thermalEmergency.manualControlEngaged(
            try commandableFan(1, declaring: .held(at: 2_400)))
        await plane.setMode(.manual, ofFan: 1)

        // The key a dead holder left, and § 3 latched with nothing bridged under it.
        await plane.setForceKey(true)
        await helper.latch.engage(
            by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99),
            answering: [smcKey("Tp01")])

        #expect(await helper.leases.leaseCount == 1, "fan 0's orphaned lease is not held")
        #expect(await helper.leases.fansWithAbandonedHandbacks == [2], "fan 2 is not abandoned")
        #expect(
            await helper.thermalEmergency.fansUnderManualControl.contains(1),
            "§ 3 is not holding fan 1, so its registry and the table agree")
        #expect(await helper.reclamationWatchdog.fansUnderManualControl == [0])
        #expect(try await Self.modes(plane, of: [0, 1, 2]) == [.manual, .manual, .manual])
        #expect(await plane.isForceKeySet)
        #expect(await helper.latch.isActive)
        return helper
    }

    /// The command exits 0 saying the helper accepted the request, and afterwards every fan is
    /// automatic, the force key is clear, no lease is held and no handback refusal stands.
    ///
    /// **§ 3's latch is still set afterwards, and that is asserted rather than tidied away.** The
    /// panic verb hands the fans back; it does not end a thermal emergency, which only § 3's own
    /// cool-down releases (`CLAUDE.md` rule 5: no message disables a safety mechanism). So grants
    /// stay refused until § 3 says otherwise, however the panic path went.
    ///
    /// The restore list is the half that says *how*: the sweep hands back the two fans Aeolus is
    /// accountable for — fan 0's lease and fan 2's abandoned handback — and the machine-wide
    /// restore then reaches fan 1, which no lease covers, and the key, which only `.everyFan`
    /// clears. The read-back of fan 2 follows it, and is what lifts fan 2's refusal.
    ///
    /// **Mutation:** delete the `try await keystone.restoreToAutomatic(.everyFan)` statement
    /// from `SupervisedFanAuthority.restoreAllToAutomatic`. Run: red — fan 1 stays manual and the
    /// key stays set, while the command still prints the same acceptance.
    /// **Mutation:** move `await leases.confirmAcceptedHandbacks()` above the `.built` block.
    /// Run: red on the order — the read of fan 2 comes before `.everyFan`.
    @Test("Every fan ends automatic and the force key clear, and the reply says accepted")
    func corruptedStateEndsRestored() async throws {
        let lines = RecordedHelperLines()
        let helper = try await Self.corrupted(lines: lines)
        let plane = helper.plane
        let before = await plane.attempts.count

        let harness = ClientListenerHarness(authority: helper.authority)
        let emitted = try await FanctlResetTests.emitted(over: harness)

        #expect(emitted.exitCode == .success, "fanctl reset --all exited \(emitted.exitCode)")
        #expect(emitted.message.contains("accepted the reset request"))
        #expect(
            emitted.message.contains(
                "has not reported that any fan is back under automatic control"),
            "the reply claimed more than v1's accepted: \(emitted.message)")
        #expect(
            harness.arrivals == ["restoreAllToAutomatic", "restoreAllToAutomatic→replied"],
            "the arrivals were \(harness.arrivals)")

        // Captured before the mode reads below, which would add attempts of their own.
        let restores = await Self.restores(plane, from: before)
        let panicAttempts = Array(await plane.attempts[before...])

        // The end state first: it is what a user running the command is owed, and nothing above
        // it may throw past it.
        #expect(
            try await Self.modes(plane, of: [0, 1, 2]) == [.automatic, .automatic, .automatic],
            "a fan is still off automatic control after fanctl reset --all")
        #expect(
            await plane.isForceKeySet == false,
            "the force key is still set after fanctl reset --all")
        #expect(await helper.leases.leaseCount == 0, "the orphaned lease survived the panic path")
        #expect(
            await helper.leases.fansWithAbandonedHandbacks.isEmpty,
            "fan 2 was handed back and read back automatic, and its refusal still stands")
        #expect(lines.levels(containing: "machine-wide restore that connection").isEmpty)
        #expect(
            await helper.latch.isActive,
            "the panic path released § 3's latch, which only § 3's own cool-down may do")

        // Then how.
        #expect(
            restores.count == 3 && Set(restores.prefix(2)) == [.fan(0), .fan(2)]
                && restores.last == .everyFan,
            """
            the panic verb's restores were \(restores): the sweep over the two fans Aeolus is \
            accountable for, then one machine-wide restore, is what reaches fan 1 and the key.
            """)
        let keystone = panicAttempts.firstIndex(of: .restoreToAutomatic(.everyFan))
        let readBack = panicAttempts.firstIndex(of: .readControlState(fan: 2))
        #expect(readBack != nil, "fan 2 was never read back, so nothing could lift its refusal")
        if let keystone, let readBack {
            #expect(
                keystone < readBack,
                "fan 2's read-back did not follow the machine-wide restore: \(panicAttempts)")
        }
    }

    // MARK: - A firmware that refuses

    /// A firmware that refuses the machine-wide restore still gets v1's *accepted*: exit 0, and
    /// a fault line in the helper's log. The fans and the key stay as they were, and the reply
    /// says nothing that contradicts that.
    ///
    /// **Mutation:** replace the `do`/`catch` in `SupervisedFanAuthority.restoreAllToAutomatic`
    /// with a bare `try await`, so the refusal propagates. Run: red — the helper's reply is a
    /// fault and the command exits non-zero, a v1 contract change made by a firmware refusal.
    /// **Mutation:** delete the `log.panicRestoreRefused(...)` call from that `catch`. Run: red
    /// on the fault line.
    @Test("A refused machine-wide restore is still accepted, and logged at fault")
    func aRefusingFirmwareStillGetsAccepted() async throws {
        let lines = RecordedHelperLines()
        let helper = Self.composed(
            fans: [0: .init(mode: .manual)],
            stages: [
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures, writes: Self.refusing)
            ],
            lines: lines)
        await helper.plane.setForceKey(true)

        let harness = ClientListenerHarness(authority: helper.authority)
        let emitted = try await FanctlResetTests.emitted(over: harness)

        #expect(emitted.exitCode == .success, "fanctl reset --all exited \(emitted.exitCode)")
        #expect(emitted.message.contains("accepted the reset request"))
        #expect(await Self.restores(helper.plane, from: 0) == [.everyFan])
        #expect(
            lines.levels(containing: "machine-wide restore that connection") == [.fault],
            "the refusal was not reported at fault level")
        #expect(await helper.plane.isForceKeySet, "a refused restore cleared the key")
        #expect(harness.sessions.count == 1)
    }
}
