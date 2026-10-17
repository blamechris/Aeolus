import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// `apply` at the privilege boundary, since A6's third step wired it to level 6 (ADR 0014's A6
/// PR-3 amendment): the authority's shutdown refusal first, and the answers through the listener.
///
/// The listener is `AnonymousListenerHarness`'s, the production `HelperListenerDelegate` exporting
/// the production `HelperXPCService`, so each message crosses the session's gates and the
/// connection's sequencer exactly as a client's does. The authority behind it is a composed
/// helper's, so `apply` reaches the composition's `LeaseApplier`.
@Suite("apply at the privilege boundary", .timeLimit(.minutes(1)))
struct SupervisedApplyBoundaryTests {

    /// The authority's teardown refusal, as a client receives it.
    static let shuttingDown = AeolusXPCFault.helperFailed(detail: "the helper is shutting down")

    // MARK: - The shutdown refusal

    /// An `apply` that arrives once the teardown has begun gets the shutdown refusal, and reaches
    /// no `LeaseApplier`: under a lease that is still live, no gate is entered and nothing reaches
    /// the firmware.
    ///
    /// The fault alone cannot tell the order apart: a delegation ahead of the refusal engages and
    /// commands the fan and is then refused with the same fault. So the assertions are on the gate
    /// and the firmware.
    ///
    /// **Mutation:** in `SupervisedFanAuthority.apply`, delegate before `refuseIfShuttingDown`.
    /// Run: red, on the gate's entrants and the firmware's attempts.
    @Test("An apply after the teardown began is refused and reaches no level 6")
    func anApplyAfterTheTeardownBeganReachesNoLevelSix() async throws {
        let helper = HelperRestorerTests.composed(clock: TestClock())
        await helper.bindSafetyRegistries()
        let connection = ConnectionID()
        let lease = try await helper.authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        await helper.authority.controlGate.close()
        let before = await helper.plane.attempts

        await #expect(throws: Self.shuttingDown) {
            try await helper.authority.apply(
                [FanSetting(fanIndex: 0, control: .fixed(rpm: 2_400))],
                leaseID: lease.id,
                from: connection)
        }

        #expect(await helper.leases.activeLease()?.id == lease.id, "the lease was not live")
        #expect(helper.examinationGate.entrants == 0, "level 6 took a gate after the refusal")
        let after = await helper.plane.attempts
        #expect(
            after == before,
            "an apply refused for shutdown reached the firmware: \(after.dropFirst(before.count))")
    }

    // MARK: - On a build that cannot write

    /// On `.notBuilt`, `apply` answers what it answered before A6's third step, in the same order:
    /// the handshake gate, the session's lease-ID check, the authority's shutdown refusal, and the
    /// lease core's fault. Nothing is written and the gate is never entered.
    ///
    /// A composed `.notBuilt` helper can hold no lease, so `heldLease(id:from:)` answers
    /// `leaseUnknown` for every lease a client can name. `LeaseApplier`'s `.writePathNotBuilt`,
    /// which comes after the lease, is reachable only under a lease granted on a capability the
    /// write path does not share; `LeaseApplierAnswerTests` holds that row.
    ///
    /// **Mutation:** in `SupervisedFanAuthority.apply`, delegate before `refuseIfShuttingDown`.
    /// Run: red, the apply after the teardown began is answered `leaseUnknown`.
    @Test("On a build that cannot write, apply answers the same faults in the same order")
    func onANotBuiltPlaneApplyAnswersAsBefore() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let helper = await Self.notBuilt(over: firmware)
        let harness = AnonymousListenerHarness(authority: helper.authority)
        let settings = try Self.settingsPayload(rpm: 2_400)
        let unknown = UUID().uuidString

        let beforeHandshake = await harness.acknowledgementMessage { proxy, reply in
            proxy.apply(settings: settings, leaseID: unknown, reply: reply)
        }
        let request = try helloPayload()
        let hello = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: request, reply: reply)
        }
        let leaseRequest = try leasePayload()
        let grant = await harness.payloadMessage { proxy, reply in
            proxy.acquireLease(request: leaseRequest, reply: reply)
        }
        let malformed = await harness.acknowledgementMessage { proxy, reply in
            proxy.apply(settings: settings, leaseID: "not-a-lease", reply: reply)
        }
        let unknownLease = await harness.acknowledgementMessage { proxy, reply in
            proxy.apply(settings: settings, leaseID: unknown, reply: reply)
        }
        await helper.authority.controlGate.close()
        let shuttingDown = await harness.acknowledgementMessage { proxy, reply in
            proxy.apply(settings: settings, leaseID: unknown, reply: reply)
        }
        let malformedInTeardown = await harness.acknowledgementMessage { proxy, reply in
            proxy.apply(settings: settings, leaseID: "not-a-lease", reply: reply)
        }

        #expect(beforeHandshake.fault == .handshakeRequired)
        #expect(hello.payload != nil, "the handshake failed, so nothing after it was tested")
        #expect(
            grant.fault == .manualControlUnavailable(reason: .writePathNotBuilt),
            "a lease was granted on .notBuilt, so this is not the shipped build's answer")
        #expect(Self.refusesTheLeaseID(malformed.fault), "answered \(malformed)")
        #expect(unknownLease.fault == .leaseUnknown)
        #expect(
            shuttingDown.fault == Self.shuttingDown,
            """
            an apply after the teardown began was answered \(String(describing: shuttingDown)). \
            The shutdown refusal comes before the lease: ADR 0014's A6 PR-3 amendment.
            """)
        #expect(
            Self.refusesTheLeaseID(malformedInTeardown.fault),
            "the session's lease-ID check no longer comes before the authority's refusal")
        #expect(helper.examinationGate.entrants == 0, "the gate was entered on a shipped build")
        let writes = await firmware.attempts.filter(Self.isForwardWrite)
        #expect(writes.isEmpty, "a build that cannot write was asked to: \(writes)")
    }

    // MARK: - Fixtures

    /// A composed helper over `firmware` behind a plane that answers `.notBuilt`, as every build
    /// on `main` does, bound as bring-up binds it.
    static func notBuilt(
        over firmware: ScriptedControlPlane
    ) async -> HelperComposition<ControlStateGatePlane> {
        let helper = HelperComposition(
            plane: ControlStateGatePlane(firmware, capability: .notBuilt),
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: TestClock(),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
        #expect(helper.plane.writeCapability == .notBuilt, "this helper is vacuous on .built")
        await helper.bindSafetyRegistries()
        return helper
    }

    /// `settings` as a client's `apply` carries it: one fixed setting for fan 0.
    static func settingsPayload(rpm: Double) throws -> Data {
        try AeolusXPCCoding.encoder().encode([FanSetting(fanIndex: 0, control: .fixed(rpm: rpm))])
    }

    private static func refusesTheLeaseID(_ fault: AeolusXPCFault?) -> Bool {
        guard case .invalidParameter(let name, _)? = fault else { return false }
        return name == "leaseID"
    }

    private static func isForwardWrite(_ attempt: ScriptedControlPlane.Attempt) -> Bool {
        switch attempt {
        case .engageManualControl, .commandTarget: return true
        default: return false
        }
    }
}
