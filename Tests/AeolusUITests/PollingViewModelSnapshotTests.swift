import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusUI

/// `PollingViewModel` against the helper snapshot: zero SMC reads while fresh snapshots
/// arrive, and every control claim unknown the moment one may not be rendered (#156, ADR 0006).
@Suite(
    "PollingViewModel — the helper's snapshot, or no control claim at all",
    .timeLimit(.minutes(1)))
@MainActor
struct PollingViewModelSnapshotTests {

    typealias Support = SnapshotTestSupport

    /// A provider that would answer every direct read, so a view model that read the SMC on a
    /// fresh tick would succeed at it — and the read counts are what show it did.
    private static func provider(isAvailable: Bool = true) -> FakeSensorProvider {
        FakeSensorProvider(
            isAvailable: isAvailable,
            allReadings: [.fake(key: "Tp09", value: 42, kind: .temperatureCelsius)],
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
                "Tp09": .success(.fake(key: "Tp09", value: 44.2, kind: .temperatureCelsius)),
            ])
    }

    /// A started source whose latest reply is `snapshot`, recorded: the loop has sent its next
    /// request, which it does only after recording the last answer.
    private static func freshSource(
        _ helper: FakeSnapshotHelper, answering snapshot: SystemSnapshot,
        clock: SnapshotTestClock = SnapshotTestClock()
    ) async throws -> HelperSnapshotSource {
        let source = try await Support.handshakenSource(helper, clock: clock)
        source.start()
        await helper.waitForRequests(1)
        await helper.reply(with: snapshot)
        await helper.waitForRequests(2)
        try #require(Support.freshSnapshot(source) == snapshot)
        return source
    }

    // MARK: - One reader per machine

    /// **Mutation:** in `PollingViewModel.tick()`'s `.fresh` arm, add
    /// `await readDirectly(untracked: .awaitingSnapshot)` before the snapshot is published —
    /// keep polling. Run: red at both read counts.
    @Test("While fresh snapshots arrive the view model reads nothing from the SMC")
    func freshSnapshotsMeanZeroSMCReads() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(fans: [Support.fan(0, actual: 2345)])
        let source = try await Self.freshSource(helper, answering: snapshot)
        let provider = Self.provider()
        let viewModel = PollingViewModel(
            provider: provider, clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()
        await viewModel.tick()
        await viewModel.tick()

        #expect(await provider.readAllCallCount == 0)
        #expect(await provider.readKeysCalls.isEmpty)
        #expect(viewModel.phase == .ready)
        #expect(viewModel.fans.map(\.actual) == [.value(key: "F0Ac", 2345)])
        #expect(viewModel.fans.map(\.control) == [.reported(snapshot.fans[0])])
        #expect(viewModel.sensors.map(\.key) == ["Tp09"])
        #expect(viewModel.sensors.first?.kind == .temperatureCelsius)
        #expect(viewModel.thermalEmergency == .inactive)
        #expect(viewModel.controlSource == .helperSnapshot(activeLease: nil))

        await Support.tearDown(source, helper)
    }

    // MARK: - Unknown the moment it may not be rendered

    /// **Mutation:** delete the `health == .handshaken` guard in
    /// `HelperSnapshotSource.authority()` — keep rendering the last snapshot. Run: red at every
    /// expectation after the health changes.
    @Test("Health leaving .handshaken makes every control claim unknown on the next tick")
    func healthLeavingHandshakenMakesEveryClaimUnknown() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(
            fans: [Support.fan(0, mode: .manualFixed, target: 3000)],
            isThermalEmergencyActive: true)
        let source = try await Self.freshSource(helper, answering: snapshot)
        let viewModel = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()
        #expect(viewModel.thermalEmergency == .active)
        #expect(viewModel.fans.map(\.control) == [.reported(snapshot.fans[0])])

        helper.report(.unresponsive)
        try #require(await Support.settle { source.health == .unresponsive })
        await viewModel.tick()

        let why = ControlNotTracked.helperConnection(.unresponsive)
        #expect(viewModel.fans.map(\.control) == [.notTracked(why)])
        #expect(viewModel.thermalEmergency == .unknown)
        #expect(viewModel.controlSource == .notTracked(why))
        #expect(FanRowModel(reading: viewModel.fans[0]).controlStateLabel == "Mode not tracked")

        await Support.tearDown(source, helper)
    }

    /// The claims are withdrawn before the direct read, so a direct read that then fails leaves
    /// the snapshot's RPM on screen with the failure noted, and none of its claims.
    ///
    /// **Mutation:** delete the `withdrawControlClaims(why)` call in `tick()`. Run: red at the
    /// control and thermal expectations.
    @Test("A failed direct read after a snapshot leaves its observations and none of its claims")
    func aFailedDirectReadLeavesNoClaims() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(
            fans: [Support.fan(0, mode: .manualFixed, target: 3000, actual: 2999)],
            isThermalEmergencyActive: true)
        let source = try await Self.freshSource(helper, answering: snapshot)
        let viewModel = PollingViewModel(
            provider: Self.provider(isAvailable: false), clock: FakePollingClock(),
            snapshots: source)

        await viewModel.tick()
        helper.report(.invalidated)
        try #require(await Support.settle { source.health == .invalidated })
        await viewModel.tick()

        #expect(viewModel.phase == .failed(.noSMC))
        #expect(viewModel.fans.map(\.actual) == [.value(key: "F0Ac", 2999)])
        #expect(viewModel.fans.map(\.control) == [.notTracked(.helperConnection(.invalidated))])
        #expect(viewModel.thermalEmergency == .unknown)

        await Support.tearDown(source, helper)
    }

    @Test("A stale snapshot makes every control claim unknown on the next tick")
    func aStaleSnapshotMakesEveryClaimUnknown() async throws {
        let helper = FakeSnapshotHelper()
        let clock = SnapshotTestClock()
        let snapshot = Support.snapshot(isThermalEmergencyActive: true)
        let source = try await Self.freshSource(helper, answering: snapshot, clock: clock)
        let viewModel = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()
        #expect(viewModel.thermalEmergency == .active)

        clock.advance(by: source.freshnessBound)
        await viewModel.tick()

        #expect(viewModel.fans.map(\.control) == [.notTracked(.snapshotStale)])
        #expect(viewModel.thermalEmergency == .unknown)
        #expect(viewModel.controlSource == .notTracked(.snapshotStale))

        await Support.tearDown(source, helper)
    }

    // MARK: - Direct reads

    /// **Mutation:** in `FanPoller.poll(provider:untracked:)`, add `import FanKit` and give every
    /// fan `control: .reported(FanKit.FanState(index: fan.index, actualRPM: .measured(1),
    /// minimumRPM: .measured(1), maximumRPM: .measured(2), targetRPM: nil, mode: .automatic,
    /// isReclaimedBySystem: false, manualControlAvailability: .available))` — default the mode
    /// to automatic. Run: red at the control and label expectations, and in
    /// `FanPollerTests.directlyReadFansAreNotTracked`.
    @Test("Direct reads never say Automatic: every fan is not tracked, and says so")
    func directReadsNeverSayAutomatic() async {
        let viewModel = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock(),
            snapshots: HelperSnapshotSource(withoutHelper: .noHelperInThisBuild))

        await viewModel.tick()

        #expect(viewModel.phase == .ready)
        #expect(!viewModel.fans.isEmpty)
        for fan in viewModel.fans {
            #expect(fan.control == .notTracked(.noHelperInThisBuild))
            let label = FanRowModel(reading: fan).controlStateLabel
            #expect(label == "Mode not tracked")
            #expect(label != "Automatic")
        }
        #expect(viewModel.controlSource == .notTracked(.noHelperInThisBuild))
    }

    // MARK: - Thermal emergency: on, off, unknown

    /// The snapshot lists **no lease**: § 3 revokes every lease when it fires, so this is what
    /// an emergency usually looks like, and the banner must not wait for one.
    @Test("An emergency the snapshot reports is active, with no lease listed")
    func anEmergencyWithNoLeaseIsActive() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(activeLease: nil, isThermalEmergencyActive: true)
        let source = try await Self.freshSource(helper, answering: snapshot)
        let viewModel = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()

        #expect(viewModel.thermalEmergency == .active)
        #expect(
            ThermalEmergencyDisplay.banner(for: viewModel.thermalEmergency)
                == ThermalEmergencyDisplay.emergency)

        await Support.tearDown(source, helper)
    }

    @Test("A snapshot that reports no emergency is inactive, and draws no banner")
    func noEmergencyIsInactive() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Self.freshSource(
            helper, answering: Support.snapshot(isThermalEmergencyActive: false))
        let viewModel = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()

        #expect(viewModel.thermalEmergency == .inactive)
        #expect(ThermalEmergencyDisplay.banner(for: viewModel.thermalEmergency) == nil)

        await Support.tearDown(source, helper)
    }

    /// **Mutation:** in `withdrawControlClaims(_:)`, set `thermalEmergency = .inactive` —
    /// unknown becomes off. Run: red at both expectations.
    @Test("With no snapshot to say, the emergency state is unknown, and draws its own line")
    func noSnapshotIsUnknown() async {
        let viewModel = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock(),
            snapshots: HelperSnapshotSource(withoutHelper: .noHelperInThisBuild))

        await viewModel.tick()

        #expect(viewModel.thermalEmergency == .unknown)
        #expect(
            ThermalEmergencyDisplay.banner(for: viewModel.thermalEmergency)
                == ThermalEmergencyDisplay.unknown)
    }

    // MARK: - Consumers

    @Test("start() and stop() tell the shared source a consumer came and went")
    func theViewModelIsASourceConsumer() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)
        let viewModel = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock(cancelAfterSleeps: 1),
            snapshots: source)

        viewModel.start()
        await helper.waitForRequests(1)
        await viewModel.waitUntilLoopFinishes()
        viewModel.stop()

        await helper.reply(with: Support.snapshot())
        await source.waitUntilIdle()
        #expect(await helper.requests == 1)
    }
}
