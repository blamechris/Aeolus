import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusUI

/// The menu bar against the helper snapshot: it mirrors what the window shows — the emergency,
/// whose report the fans are, a reclamation of any fan — and its icon never reads as all clear
/// while it cannot tell (#478's review, item 4).
@Suite("Menu bar — the helper's snapshot, mirrored", .timeLimit(.minutes(1)))
@MainActor
struct MenuBarSnapshotTests {

    typealias Support = SnapshotTestSupport

    private static func provider() -> FakeSensorProvider {
        FakeSensorProvider(isAvailable: false)
    }

    private static func freshSource(
        _ helper: FakeSnapshotHelper, answering snapshot: SystemSnapshot
    ) async throws -> HelperSnapshotSource {
        let source = try await Support.handshakenSource(helper)
        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: snapshot)
        try await helper.waitForRequests(2)
        try #require(Support.freshSnapshot(source) == snapshot)
        return source
    }

    /// **Mutation (M-H1):** delete `self.thermalEmergency = polling.thermalEmergency` from
    /// `MenuBarViewModel.refresh()`. Run: red at the `.active` expectation.
    @Test("The menu bar mirrors an emergency, and its loss to unknown when the helper wedges")
    func theEmergencyIsMirrored() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Self.freshSource(
            helper, answering: Support.snapshot(isThermalEmergencyActive: true))
        let polling = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock(), snapshots: source)
        let menuBar = MenuBarViewModel(polling: polling)

        await Support.tickEnds(polling)
        #expect(menuBar.thermalEmergency == .active)

        try await Support.report(.unresponsive, to: source, from: helper)
        await Support.tickEnds(polling)
        #expect(menuBar.thermalEmergency == .unknown)

        await Support.tearDown(source, helper)
    }

    /// **Mutation (D1):** delete `self.controlSource = polling.controlSource` from `refresh()`.
    /// Run: red here.
    @Test("The menu bar mirrors whose report the fans are, lease holder included")
    func theControlSourceIsMirrored() async throws {
        let helper = FakeSnapshotHelper()
        let lease = Lease(holderDescription: "fanctl", expiresAt: Date())
        let source = try await Self.freshSource(
            helper, answering: Support.snapshot(activeLease: lease))
        let polling = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock(), snapshots: source)
        let menuBar = MenuBarViewModel(polling: polling)

        await Support.tickEnds(polling)
        #expect(menuBar.controlSource == .helperSnapshot(activeLease: lease))

        await Support.tearDown(source, helper)
    }

    /// The reclaimed fan is not one of the selected readouts.
    ///
    /// **Mutation (D2):** compute `isAnyFanReportedReclaimed` from `readouts` instead of
    /// `polling.fans`. Run: red here.
    @Test("A reclamation of any fan reaches the menu bar, selected as a readout or not")
    func aReclamationOfAnyFanIsSeen() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(
            fans: [Support.fan(0), Support.fan(1, availability: .available, reclaimed: true)])
        let source = try await Self.freshSource(helper, answering: snapshot)
        let polling = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock(), snapshots: source)
        let menuBar = MenuBarViewModel(
            polling: polling, selection: [MenuBarReadout(key: "F0Ac", source: .fan)])

        await Support.tickEnds(polling)

        #expect(menuBar.readouts.map(\.key) == ["F0Ac"])
        #expect(menuBar.isAnyFanReportedReclaimed)
        #expect(
            MenuBarIcon.systemName(
                thermalEmergency: menuBar.thermalEmergency, controlSource: menuBar.controlSource,
                anyFanReportedReclaimed: menuBar.isAnyFanReportedReclaimed)
                == "exclamationmark.triangle")

        await Support.tearDown(source, helper)
    }

    /// The authority watch takes claims down without changing the phase, so the menu bar must
    /// follow `revision` and not only `phase`.
    ///
    /// **Mutation (D3):** delete `revision &+= 1` from `PollingViewModel.reassessAuthority()`.
    /// Run: red at the `.unknown` expectation.
    @Test("A withdrawal by the authority watch reaches the menu bar without a tick")
    func aWatchWithdrawalReachesTheMenuBar() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Self.freshSource(
            helper, answering: Support.snapshot(isThermalEmergencyActive: true))
        let readClock = GatedPollingClock()
        let watchClock = GatedPollingClock()
        let polling = PollingViewModel(
            provider: Self.provider(), clock: readClock, refreshInterval: 60, snapshots: source,
            authorityWatchClock: watchClock)
        let menuBar = MenuBarViewModel(polling: polling)

        menuBar.start()
        try await readClock.waitForSleeps(1)
        #expect(menuBar.thermalEmergency == .active)
        for _ in 0..<10_000 {
            if await watchClock.parkedCount >= 1 { break }
            await Task.yield()
        }

        try await Support.report(.unresponsive, to: source, from: helper)
        await watchClock.release()
        for _ in 0..<10_000 {
            if await watchClock.sleptSeconds.count >= 2 { break }
            await Task.yield()
        }

        #expect(polling.thermalEmergency == .unknown)
        #expect(menuBar.thermalEmergency == .unknown)
        #expect(menuBar.phase == .ready)

        menuBar.stop()
        await Support.tearDown(source, helper)
    }

    // MARK: - The icon

    static let monitor = ControlSource.notTracked(.noHelperInThisBuild)
    static let wedged = ControlSource.notTracked(.helperConnection(.unresponsive))

    @Test("An emergency outranks everything; a reclamation outranks unknown")
    func theIconOrder() {
        #expect(
            MenuBarIcon.systemName(
                thermalEmergency: .active, controlSource: .helperSnapshot(activeLease: nil),
                anyFanReportedReclaimed: true) == "exclamationmark.triangle.fill")
        #expect(
            MenuBarIcon.systemName(
                thermalEmergency: .unknown, controlSource: Self.wedged,
                anyFanReportedReclaimed: true) == "exclamationmark.triangle")
    }

    /// **Mutation (D4):** drop the unknown branch from `MenuBarIcon.systemName`. Run: red at
    /// the first expectation.
    @Test("Unknown in a build with a helper is not drawn as all clear; in Monitor it is the fan")
    func unknownIsDrawnApartFromOff() {
        let wedged = MenuBarIcon.systemName(
            thermalEmergency: .unknown, controlSource: Self.wedged, anyFanReportedReclaimed: false)
        let inactive = MenuBarIcon.systemName(
            thermalEmergency: .inactive, controlSource: .helperSnapshot(activeLease: nil),
            anyFanReportedReclaimed: false)
        #expect(wedged != inactive)
        #expect(inactive == "fan")
        #expect(
            MenuBarIcon.systemName(
                thermalEmergency: .unknown, controlSource: Self.monitor,
                anyFanReportedReclaimed: false) == "fan")
    }

    /// The icon for every reason nothing is tracked, from `ReasonTag` — exhaustive over
    /// `ControlNotTracked` — with the literal name each must draw. Unknown is a question mark,
    /// never the off icon, wherever there is a helper this build reads or is trying to; the
    /// plain fan only with none (Monitor, a damaged bundle) or nothing read yet. Never red.
    ///
    /// **Mutations (ICa–ICf):** move each reason to the other side of `expectsHelper`.
    /// **Mutation (ICg):** return the emergency icon for unknown. Run, each: red for the reason
    /// moved, or for every reason that expects a helper.
    @Test(
        "Unknown draws the question mark exactly where a helper is expected",
        arguments: ControlSourceDisplayTests.everyReason)
    func unknownIconForEveryReason(_ why: ControlNotTracked) {
        let expected: String
        switch why {
        case .noHelperInThisBuild, .helperInstallIncomplete, .nothingReadYet:
            expected = "fan"
        case .helperConnection, .awaitingSnapshot, .snapshotRequestFailed, .snapshotContradicted,
            .snapshotStale:
            expected = "questionmark.circle"
        }
        let unknown = MenuBarIcon.systemName(
            thermalEmergency: .unknown, controlSource: .notTracked(why),
            anyFanReportedReclaimed: false)
        #expect(unknown == expected)
        #expect(unknown != "exclamationmark.triangle.fill")
        #expect(
            MenuBarIcon.systemName(
                thermalEmergency: .active, controlSource: .notTracked(why),
                anyFanReportedReclaimed: false) == "exclamationmark.triangle.fill")
        // Off, from a snapshot that says so, is the plain fan; where a helper is expected,
        // unknown must not look like it.
        let off = MenuBarIcon.systemName(
            thermalEmergency: .inactive, controlSource: .helperSnapshot(activeLease: nil),
            anyFanReportedReclaimed: false)
        #expect(off == "fan")
        #expect((unknown == off) == (expected == "fan"))
    }
}
