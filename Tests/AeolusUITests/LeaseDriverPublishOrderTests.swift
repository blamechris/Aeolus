import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// ADR 0015 D2's publishing half (#511). Every state the driver enters reaches a subscriber, in
/// the order the driver entered it, as one element with the floor published with it. That holds
/// however many states the driver enters in one turn of its actor, and however slowly the
/// subscriber reads.
///
/// The subscribers here **suspend**. Each takes the value now, then waits on a gate while the
/// driver changes state three times in one turn. So every change of that turn is in the stream's
/// buffer before either subscriber reads again. A subscriber that kept up could not tell a stream
/// that keeps every element from one that keeps only the newest.
@Suite(
    "LeaseDriver — every state published in order, with its own floor", .timeLimit(.minutes(1)))
struct LeaseDriverPublishOrderTests {

    /// Three changes of state in one turn of the driver's actor, then a fourth once the helper
    /// answers. A suspended subscriber to each stream is handed every one of them: nothing
    /// coalesced, in order, and each report with its own floor.
    ///
    /// What each element should be is the report the driver held right after the change that
    /// published it, read in the same turn. None of the mutations below touches that report;
    /// each changes only what reaches a subscriber.
    ///
    /// **Mutation (P1, coalesce):** in `Followers.stream()`, buffer with `.bufferingNewest(1)`.
    /// Run, debug, with this suite, `LeaseDriverStreamTerminationTests` and
    /// `LeaseDriverPublisherTests`: red at "nothing coalesced" in 3 of 3, and red in
    /// `LeaseDriverPublisherTests`' race test too. Before #541 the streams were made in
    /// `LeaseDriverPublisher.stream(of:add:remove:)` and the same edit there was red at "nothing
    /// coalesced", three reports where five were published, with no other lease-driver,
    /// lease-state-model or lifecycle test red.
    /// **Mutation (P2, reorder):** in `LeaseDriver.transition(to:)`, publish a state that stops
    /// acting from a `Task` on the driver's actor, with its report taken at the transition
    /// (`let stopped = report; Task { self.publisher.publishStateChange(stopped) }`), and every
    /// other state as now. Run: red at the two order assertions, the reports' ("in order") and
    /// the state stream's, and nowhere else. Every report still arrives with its own floor, but
    /// `lost` arrives after the two changes made after it in the same turn.
    /// **Mutation (P3, publish before minting):** in `transition(to:)`, move
    /// `publisher.publishStateChange(report)` above the `hasStoppedActing` block that sets
    /// `evidence`. Run: red at "each with its own floor" and at the release's later floor; the
    /// count and the order hold. `lost` goes out with the evidence from before it, and
    /// `released` with the loss's floor. `LeaseDriverFloorTests` goes red too (its F3).
    /// **Mutation (P4, a deferred publish):** in `transition(to:)`, replace the publish with
    /// `Task { self.publisher.publishStateChange(self.report) }`. Run: red at the two order
    /// assertions. Each of the turn's three tasks publishes the report as it is when the task
    /// runs, so the subscriber reads `releasing` three times and never `lost` or `acquiring`.
    @Test("Changes in one turn reach a suspended subscriber, each in order with its own floor")
    func aTurnOfChangesIsPublishedWhole() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(try LeaseScene.target([0: 3000])))
        // The loss's release waits for the test, so after the turn nothing moves until it is
        // answered.
        await scene.helper.script(.release, .parked)

        let gate = Gate()
        let received = LeaseLedger()
        let readers = [
            Self.follow(scene.driver.reportUpdates(), into: received, of: scene, parkingOn: gate) {
                .report($0)
            },
            Self.follow(scene.driver.stateUpdates(), into: received, of: scene, parkingOn: gate) {
                .state($0)
            },
        ]
        // Each has the value now, and reads nothing more until the gate opens.
        await received.waitFor { !$0.reports.isEmpty && !$0.states.isEmpty }
        let start = await scene.driver.report

        let before = await scene.driver.beginSnapshotRead()
        let turn = await Self.changeThreeTimes(
            scene.driver, readWith: before, thenTaking: try LeaseScene.target([0: 3500]))
        let between = await scene.driver.beginSnapshotRead()
        await gate.open()

        await scene.ledger.waitFor { $0.releases == [held.lease.id] }
        await scene.helper.answerParked(.release)
        await received.waitFor {
            $0.reports.contains { $0.state.isReleased } && $0.states.contains(.released)
        }
        let released = await scene.driver.report
        let after = await scene.driver.beginSnapshotRead()

        // The turn did what the test needs: three changes, the first a new floor.
        try #require(turn.count == 3 && turn[0].state.isLost, "\(turn)")
        try #require(turn[1...].map(\.state) == [.acquiring(fans: [0]), .releasing], "\(turn)")
        try #require(!turn[0].automaticEvidence.admits(before), "the loss set a floor: \(turn)")
        try #require(turn[0].automaticEvidence.admits(between), "\(turn)")
        try #require(released.state.isReleased, "\(released)")

        let expected = [start] + turn + [released]
        let got = await received.entries.reports
        try #require(got.count == expected.count, "nothing coalesced: \(got)")
        #expect(got.map(\.state) == expected.map(\.state), "in order")
        #expect(
            got.map(\.automaticEvidence) == expected.map(\.automaticEvidence),
            "each with its own floor")
        #expect(!got[4].automaticEvidence.admits(between), "the release set a later floor")
        #expect(got[4].automaticEvidence.admits(after))
        #expect(
            await received.entries.states == expected.map(\.state),
            "the state stream has every state of the reports, in their order")

        for reader in readers { reader.cancel() }
        await scene.finish()
    }

    /// Reads `stream` into `received` on a task of its own, each element as `event` records it,
    /// and parks on `gate` once it has the first: the value now.
    static func follow<Element: Sendable>(
        _ stream: AsyncStream<Element>, into received: LeaseLedger, of scene: LeaseScene,
        parkingOn gate: Gate, as event: @escaping @Sendable (Element) -> LeaseLedger.Event
    ) -> Task<Void, Never> {
        let clock = scene.clock
        return Task {
            var first = true
            for await element in stream {
                await received.record(event(element), at: clock.now)
                if first {
                    first = false
                    await gate.park()
                }
            }
        }
    }

    /// In one turn of `driver`'s actor, three changes of state, and the report the driver holds
    /// after each:
    ///
    /// 1. a snapshot that lists no lease ends the lease held (`lost`), which sets a floor;
    /// 2. `take` acquires (`acquiring`);
    /// 3. Auto asks for whatever that acquisition is granted back (`releasing`).
    ///
    /// Nothing else runs on the actor until it returns, and no task the driver started does
    /// either. Since #541 no stream's registration runs on the actor at all: a stream registers in
    /// the step that makes it, on whatever thread that is.
    static func changeThreeTimes(
        _ driver: isolated LeaseDriver, readWith ticket: LeaseDriver.SnapshotTicket,
        thenTaking target: LeaseTarget
    ) -> [LeaseDriverReport] {
        var reports: [LeaseDriverReport] = []
        driver.observe(SnapshotTestSupport.snapshot(activeLease: nil), readWith: ticket)
        reports.append(driver.report)
        driver.take(target)
        reports.append(driver.report)
        driver.selectAutomatic()
        reports.append(driver.report)
        return reports
    }

    /// Holds every subscriber that parks here until `open()`, and holds none after it.
    actor Gate {
        private var isOpen = false
        private var parked: [CheckedContinuation<Void, Never>] = []

        func park() async {
            guard !isOpen else { return }
            await withCheckedContinuation { parked.append($0) }
        }

        func open() {
            isOpen = true
            let all = parked
            parked = []
            for continuation in all { continuation.resume() }
        }
    }
}
