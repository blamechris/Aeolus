import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// `apply` end to end, since A6's third step wired it (ADR 0014's A6 PR-3 amendment): the real
/// `HelperClient`, a real listener with the helper's real session and `HelperXPCService`, and the
/// composed helper over a `.built` `ScriptedControlPlane`. Acquire, apply 50 %, snapshot, release,
/// and the fan back on automatic with § 3 and § 5 holding nothing.
///
/// The firmware takes the force-key path (`heldUntilForced`), so the engagement sets `Ftst` and
/// the release has to clear it: a hand-back that only wrote the mode would leave the key. The clock
/// is a `TestClock`, so the unlock's polls advance it rather than the wall clock; the client's
/// deadlines are the product's.
@Suite("apply end to end, through the real client", .timeLimit(.minutes(1)))
struct ApplyEndToEndTests {

    /// Each step's assertions hold only if the `apply` before them happened, so a helper that
    /// still refused it would fail every step after the grant, not just the second.
    ///
    /// **What the snapshot reports after `apply`, which is what the helper confirmed** (`CLAUDE.md`
    /// rule 6): `mode` is `.manualFixed`, read from the firmware's own `F0Md`; `activeLease` is the
    /// lease; the availability is step 9's `.available`; `isReclaimedBySystem` is `false`. The
    /// target the helper commanded is what § 5 recorded and the firmware was written, and the
    /// snapshot's `targetRPM` is `nil`, stated unconditionally by `ReadOnlyFanReport.fanState`.
    ///
    /// **Mutation:** in `SupervisedFanAuthority.apply`, restore the old body: `heldLease`, then
    /// `throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)`. Run: red at
    /// every step after the grant.
    @Test("Acquire, apply 50 %, snapshot, release: the fan is back on automatic")
    func applyEndToEnd() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)],
            unlock: .heldUntilForced(stepsToYield: 1))
        let helper = await Self.composed(over: firmware)
        let harness = ClientListenerHarness(authority: helper.authority)
        let client = harness.client()

        // 1. Acquire, and read the range the client computes 50 % of.
        let lease = try await client.acquireLease(
            LeaseRequest(holderDescription: "end to end", fanIndices: [0], timeToLive: 30))
        let envelope = try #require(
            try await client.snapshot().fans.first?.controlEnvelope.get(), "fan 0 has no range")
        let fifty =
            envelope.lowestCommandableRPM
            + (envelope.highestCommandableRPM - envelope.lowestCommandableRPM) / 2
        let expected = envelope.target(for: fifty).rpm

        // 2. Apply 50 %.
        let applied = await Self.fault {
            try await client.apply(
                [FanSetting(fanIndex: 0, control: .fixed(rpm: fifty))], leaseID: lease.id)
        }
        #expect(applied == nil, "step 2: apply was answered \(String(describing: applied))")
        let commanded = await firmware.attempts.compactMap { attempt -> Double? in
            if case .commandTarget(fan: 0, let rpm) = attempt { return rpm }
            return nil
        }
        #expect(commanded == [expected], "step 2: the firmware was commanded \(commanded)")
        #expect(await helper.reclamationWatchdog.lastCommanded(ofFan: 0)?.rpm == expected)
        #expect(firmware.ledger.isForceKeySet, "step 2: the force-key path set no key")

        // 3. Snapshot: what the helper confirmed.
        let held = try #require(try await client.snapshot().fans.first)
        #expect(held.mode == .manualFixed, "step 3: the snapshot reports fan 0 \(held.mode)")
        #expect(
            try await client.snapshot().activeLease?.id == lease.id, "step 3: no lease reported")
        #expect(held.manualControlAvailability == .available)
        #expect(!held.isReclaimedBySystem)
        // `targetRPM` is `nil` by a literal in `ReadOnlyFanReport.fanState`, pinned as it is: #410.
        #expect(held.targetRPM == nil)

        try await Self.releaseAndReadBack(lease.id, through: client, from: helper, over: firmware)
    }

    // MARK: - Fixtures

    /// Steps 4 and 5: the release hands fan 0 back, clearing the mode and the key and telling § 3,
    /// and § 3's read-back leaves the fan on automatic with § 3 and § 5 holding nothing.
    private static func releaseAndReadBack(
        _ lease: UUID, through client: HelperClient,
        from helper: HelperComposition<ScriptedControlPlane>, over firmware: ScriptedControlPlane
    ) async throws {
        // 4. Release: the hand-back clears the mode and the key, and § 3 is told.
        let writesBefore = await firmware.keyWrites.count
        try await client.releaseLease(id: lease)
        let released = Array(await firmware.keyWrites.dropFirst(writesBefore))
        #expect(
            released.contains(.mode(fan: 0, value: 0)) && released.contains(.forceKey(0)),
            "step 4: the release wrote \(released)")
        #expect(
            await helper.thermalEmergency.fansOwedHandbackReadBack == [0],
            "step 4: § 3 was not told of the hand-back")
        #expect(await helper.reclamationWatchdog.fansUnderManualControl.isEmpty)

        // 5. § 3's read-back: the fan is on automatic, and § 3 and § 5 hold nothing.
        await helper.thermalEmergency.cycle()
        #expect(try await firmware.firmwareMode(ofFan: 0) == .automatic)
        #expect(!firmware.ledger.isForceKeySet, "step 5: the force key is still set")
        #expect(
            await helper.thermalEmergency.fansUnderManualControl.isEmpty,
            "step 5: § 3 still holds fan 0")
        #expect(await helper.thermalEmergency.fansOwedHandbackReadBack.isEmpty)
        #expect(await helper.reclamationWatchdog.fansUnderManualControl.isEmpty)
        let after = try await client.snapshot()
        #expect(after.fans.first?.mode == .automatic && after.activeLease == nil)
        #expect(
            await firmware.keyWrites.contains(.mode(fan: 0, value: 1)),
            "step 5: the fan was never off automatic, so nothing was handed back")
    }

    /// The composed helper over `firmware` directly, bound as bring-up binds it.
    private static func composed(
        over firmware: ScriptedControlPlane
    ) async -> HelperComposition<ScriptedControlPlane> {
        let helper = HelperComposition(
            plane: firmware,
            snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: TestClock(),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
        #expect(helper.plane.writeCapability == .built, "this test is vacuous unless it can write")
        await helper.bindSafetyRegistries()
        return helper
    }

    /// The fault `work` ended with, or `nil` when it returned.
    private static func fault(_ work: () async throws -> Void) async -> (any Error)? {
        do {
            try await work()
            return nil
        } catch {
            return error
        }
    }
}
