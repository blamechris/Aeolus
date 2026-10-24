import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusUI

/// `PollingViewModel` against the helper snapshot: zero SMC reads while fresh snapshots
/// arrive, none while the helper is expected, every control claim unknown the moment one may
/// not be rendered, and taken down within a second however long the refresh interval is
/// (#156, ADR 0006, #478's review).
@Suite(
    "PollingViewModel — the helper's snapshot, or no control claim at all",
    .timeLimit(.minutes(1)))
@MainActor
struct PollingViewModelSnapshotTests {

    typealias Support = SnapshotTestSupport

    static let lease = Lease(holderDescription: "fanctl 0.3.0", expiresAt: Date())

    // MARK: - One reader per machine

    /// **Mutation (M5):** in `PollingViewModel.tick()`'s `.fresh` arm, add
    /// `await readDirectly(untracked: .awaitingSnapshot)` before the snapshot is published —
    /// keep polling. Run: red at both read counts.
    @Test("While fresh snapshots arrive the view model reads nothing from the SMC")
    func freshSnapshotsMeanZeroSMCReads() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(fans: [Support.fan(0, actual: 2345)])
        let source = try await Support.freshSource(helper, answering: snapshot)
        let provider = Support.directProvider()
        let viewModel = PollingViewModel(
            provider: provider, clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()
        await viewModel.tick()
        await viewModel.tick()

        #expect(await provider.readAllCallCount == 0)
        #expect(await provider.readKeysCalls.isEmpty)
        #expect(viewModel.phase == .ready)
        #expect(viewModel.fans.map(\.actual) == [.value(key: "F0Ac", 2345)])
        #expect(
            viewModel.fans.map(\.control) == [.reported(snapshot.fans[0], thermalEmergency: false)])
        #expect(viewModel.sensors.map(\.key) == ["Tp09"])
        #expect(viewModel.sensors.first?.kind == .temperatureCelsius)
        #expect(viewModel.thermalEmergency == .inactive)
        #expect(viewModel.controlSource == .helperSnapshot(activeLease: nil))

        await Support.tearDown(source, helper)
    }

    /// ADR 0006 allows the app's own reads in a build with a helper only while that helper is
    /// absent, unapproved, refused, mismatched or unreachable — not while it is being connected
    /// to, and not while a handshaken helper owes its first answer.
    ///
    /// **Mutation (I1):** in `HelperSnapshotSource.authority()`, return `.readDirectly(why)` for
    /// `.idle` too. Run: red at the first two `readCount` expectations and the first `phase`.
    @Test("No direct read while the helper is expected; the fallback reads once it is refused")
    func noDirectReadsWhileTheHelperIsExpected() async throws {
        let helper = FakeSnapshotHelper()
        let source = Support.source(helper)
        let provider = Support.directProvider()
        let viewModel = PollingViewModel(
            provider: provider, clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()
        #expect(await Support.readCount(provider) == 0)
        #expect(viewModel.phase == .waitingForHelper)
        #expect(viewModel.controlSource == .notTracked(.helperConnection(.idle)))

        try await Support.report(.handshaken, to: source, from: helper)
        await viewModel.tick()
        #expect(await Support.readCount(provider) == 0)
        #expect(viewModel.phase == .waitingForHelper)
        #expect(viewModel.controlSource == .notTracked(.awaitingSnapshot))

        try await Support.report(.refused, to: source, from: helper)
        await viewModel.tick()
        #expect(await Support.readCount(provider) > 0)
        #expect(viewModel.phase == .ready)
        #expect(viewModel.fans.map(\.control) == [.notTracked(.helperConnection(.refused))])
    }

    // MARK: - Unknown the moment it may not be rendered

    /// **Mutation (M2):** delete the `health == .handshaken` guard in
    /// `HelperSnapshotSource.authority()`. Run: red at the `fans` and `controlSource`
    /// expectations, which name the reason. The emergency and label expectations stay green,
    /// because leaving `.handshaken` also advances the episode, and that alone withdraws the
    /// claims.
    @Test("Health leaving .handshaken makes every control claim unknown on the next tick")
    func healthLeavingHandshakenMakesEveryClaimUnknown() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(
            fans: [Support.fan(0, mode: .manualFixed, target: 3000)],
            isThermalEmergencyActive: true)
        let source = try await Support.freshSource(helper, answering: snapshot)
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()
        #expect(viewModel.thermalEmergency == .active)
        #expect(
            viewModel.fans.map(\.control) == [.reported(snapshot.fans[0], thermalEmergency: true)])

        try await Support.report(.unresponsive, to: source, from: helper)
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
    /// **Mutation (M10):** delete the `withdrawControlClaims(why)` call in `tick()`'s
    /// `.readDirectly` arm. Run: red at the control and thermal expectations.
    @Test("A failed direct read after a snapshot leaves its observations and none of its claims")
    func aFailedDirectReadLeavesNoClaims() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(
            fans: [Support.fan(0, mode: .manualFixed, target: 3000, actual: 2999)],
            isThermalEmergencyActive: true)
        let source = try await Support.freshSource(helper, answering: snapshot)
        let viewModel = PollingViewModel(
            provider: Support.directProvider(isAvailable: false), clock: FakePollingClock(),
            snapshots: source)

        await viewModel.tick()
        try await Support.report(.invalidated, to: source, from: helper)
        await viewModel.tick()

        #expect(viewModel.phase == .failed(.noSMC))
        #expect(viewModel.fans.map(\.actual) == [.value(key: "F0Ac", 2999)])
        #expect(viewModel.fans.map(\.control) == [.notTracked(.helperConnection(.invalidated))])
        #expect(viewModel.thermalEmergency == .unknown)

        await Support.tearDown(source, helper)
    }

    /// Stale while handshaken: the next answer is due, so the view model waits and reads
    /// nothing, with every claim down.
    @Test("A stale snapshot makes every control claim unknown on the next tick, and reads nothing")
    func aStaleSnapshotMakesEveryClaimUnknown() async throws {
        let helper = FakeSnapshotHelper()
        let clock = SnapshotTestClock()
        let snapshot = Support.snapshot(isThermalEmergencyActive: true)
        let source = try await Support.freshSource(helper, answering: snapshot, clock: clock)
        let provider = Support.directProvider()
        let viewModel = PollingViewModel(
            provider: provider, clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()
        #expect(viewModel.thermalEmergency == .active)

        clock.advance(by: source.freshnessBound)
        await viewModel.tick()

        #expect(viewModel.fans.map(\.control) == [.notTracked(.snapshotStale)])
        #expect(viewModel.thermalEmergency == .unknown)
        #expect(viewModel.controlSource == .notTracked(.snapshotStale))
        #expect(viewModel.phase == .waitingForHelper)
        #expect(await Support.readCount(provider) == 0)

        await Support.tearDown(source, helper)
    }

    // MARK: - Direct reads

    /// **Mutation (M4):** in `FanPoller.poll(provider:untracked:)`, add `import FanKit` and give
    /// every fan `control: .reported(FanKit.FanState(index: fan.index, actualRPM: .measured(1),
    /// minimumRPM: .measured(1), maximumRPM: .measured(2), targetRPM: nil, mode: .automatic,
    /// isReclaimedBySystem: false, manualControlAvailability: .available), thermalEmergency:
    /// false)` — default the mode to automatic. Run: red at the control and label
    /// expectations, and in `FanPollerTests.directlyReadFansAreNotTracked`.
    @Test("Direct reads never say Automatic: every fan is not tracked, and says so")
    func directReadsNeverSayAutomatic() async {
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(),
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

    // MARK: - What a fresh tick carries

    /// **Mutation (O5):** `controlSource = .helperSnapshot(activeLease: nil)` in `render`.
    /// **Mutation (O6):** infer the emergency from `snapshot.activeLease != nil` as well. Run,
    /// each: red here.
    @Test("A listed lease is carried, and does not make an emergency")
    func aLeaseIsCarriedAndIsNotAnEmergency() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(
            activeLease: Self.lease, isThermalEmergencyActive: false)
        let source = try await Support.freshSource(helper, answering: snapshot)
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()

        #expect(viewModel.controlSource == .helperSnapshot(activeLease: Self.lease))
        #expect(viewModel.thermalEmergency == .inactive)

        await Support.tearDown(source, helper)
    }

    /// **Mutation (O27):** `lastUpdated = snapshot.capturedAt` in `render`. Run: red here.
    @Test("A fresh tick's lastUpdated is when the reply arrived, not the helper's capturedAt")
    func lastUpdatedIsTheArrival() async throws {
        let helper = FakeSnapshotHelper()
        let capturedAt = Date(timeIntervalSince1970: 1_000_000)
        let source = try await Support.freshSource(
            helper, answering: Support.snapshot(capturedAt: capturedAt))
        guard case .fresh(_, let receivedAt) = source.authority() else {
            Issue.record("no fresh snapshot")
            return
        }
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()

        #expect(viewModel.lastUpdated == receivedAt)
        #expect(viewModel.lastUpdated != capturedAt)

        await Support.tearDown(source, helper)
    }

    // MARK: - Thermal emergency: on, off, unknown

    /// The snapshot lists **no lease**: § 3 revokes every lease when it fires, so this is what
    /// an emergency usually looks like, and the banner must not wait for one.
    @Test("An emergency the snapshot reports is active, with no lease listed")
    func anEmergencyWithNoLeaseIsActive() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(activeLease: nil, isThermalEmergencyActive: true)
        let source = try await Support.freshSource(helper, answering: snapshot)
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()

        #expect(viewModel.thermalEmergency == .active)
        #expect(
            ThermalEmergencyDisplay.banner(
                for: viewModel.thermalEmergency, source: viewModel.controlSource)
                == ThermalEmergencyDisplay.emergency)

        await Support.tearDown(source, helper)
    }

    @Test("A snapshot that reports no emergency is inactive, and draws no banner")
    func noEmergencyIsInactive() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.freshSource(
            helper, answering: Support.snapshot(isThermalEmergencyActive: false))
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()

        #expect(viewModel.thermalEmergency == .inactive)
        #expect(
            ThermalEmergencyDisplay.banner(
                for: viewModel.thermalEmergency, source: viewModel.controlSource) == nil)

        await Support.tearDown(source, helper)
    }

    /// **Mutation (M7a):** in `withdrawControlClaims(_:)`, set `thermalEmergency = .inactive` —
    /// unknown becomes off. Run: red at both expectations.
    @Test("With no snapshot to say, the emergency state is unknown, and draws its own line")
    func noSnapshotIsUnknown() async {
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(),
            snapshots: HelperSnapshotSource(withoutHelper: .noHelperInThisBuild))

        await viewModel.tick()

        #expect(viewModel.thermalEmergency == .unknown)
        #expect(
            ThermalEmergencyDisplay.banner(
                for: viewModel.thermalEmergency, source: viewModel.controlSource)
                == ThermalEmergencyDisplay.unknown(because: .noHelperInThisBuild))
    }

}
