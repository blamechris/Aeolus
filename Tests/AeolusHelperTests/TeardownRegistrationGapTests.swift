import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// A teardown begins its fans' handbacks before it can suspend, so an acquirer it lets through
/// finds them begun (#516).
///
/// ADR 0015 D5's *Identity* rests on it: every path that removes a lease calls `restore`, which
/// registers each fan as mid-handback before its first `await`. Then the gap between a lease's
/// removal and its fans' registration contains no suspension, and no grant can be decided inside
/// it. One decided there finds an empty table and no handback, and grants a lease over a fan whose
/// restore is about to be issued, so the restore lands under a live lease: `CLAUDE.md` rule 6.
///
/// `LeaseHandbackWindowTests` and `LeaseHandbackGuardPlacementTests` park each acquirer until
/// both the removal and the registration have happened, so neither can see a suspension between
/// them. `TeardownCountTripwireTests` (#368) holds the same gap in the source text, for every
/// teardown path, and goes red on the mutation below too; this holds it in behaviour, for
/// `connectionDidInvalidate`, whatever the spelling. Here the acquirer is parked in the bounds
/// read, the last suspension before `acquireLease`'s marker, and is resumed inside the teardown's
/// first job, so it runs at that job's first suspension. `TeardownGapFixture` says why that
/// ordering is deterministic, and `theScheduleLandsTheAcquirerAtOneSuspension` holds it to that.
///
/// **The acquirer reads its fan before the dying lease is granted.** Asked once that lease held
/// fan 0, the foreign-control step would exempt fan 0 as Aeolus's own, and in the gap
/// `refuseIfExemptionLapsed` would refuse it `.releaseInProgress` too (#311): the downstream
/// guard, not the one under test, would be what answered.
///
/// **Needs macOS 15** for `Task(executorPreference:)`. On an older system each test records an
/// issue and stops, rather than passing while it watches nothing.
@Suite("A teardown begins its handbacks before it can suspend", .timeLimit(.minutes(1)))
struct TeardownRegistrationGapTests {

    private typealias Fixture = TeardownGapFixture

    /// What a run needs once the newcomer is parked and the holder's lease is granted.
    private struct Scene: Sendable {
        let authority: LeaseAuthority
        let gate: ParkingEnvelopeRead
        let answer: Fixture.GrantAnswer
        let holder: ConnectionID
        let restoreEntered: AsyncSignal
        let restoreRelease: AsyncSignal
    }

    /// A newcomer parked in the bounds read over fan 0, and only then a holder's lease over fan 0.
    @available(macOS 15.0, *)
    private static func parkedNewcomer(on lane: OneLaneTaskExecutor) async throws -> Scene {
        let gate = ParkingEnvelopeRead(over: LeaseFixture.plausibleEnvelopes())
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let authority = LeaseFixture.authority(
            restorer: RecordingFanRestorer(entered: entered, release: release), envelopes: gate)
        let answer = Fixture.GrantAnswer()
        let newcomer = ConnectionID()

        Task(executorPreference: lane, priority: .medium) {
            await Fixture.acquiring(
                LeaseFixture.request(fans: [0]), from: newcomer, answeringInto: answer,
                on: authority)
        }
        try await waitUntil("the newcomer parked in the bounds read") { gate.isParked }

        let holder = ConnectionID()
        _ = try await authority.acquireLease(LeaseFixture.request(fans: [0]), from: holder)
        #expect(answer.recorded == nil, "the newcomer was answered before the gate opened")
        return Scene(
            authority: authority, gate: gate, answer: answer, holder: holder,
            restoreEntered: entered, restoreRelease: release)
    }

    /// The fact, stated as the failure it prevents: an acquirer released inside a connection's
    /// teardown is refused `.releaseInProgress` over the dying lease's fan, and holds nothing.
    ///
    /// **Mutation:** in `LeaseAuthority.connectionDidInvalidate`, insert `await Task.yield()`
    /// immediately before `await restore(fans, because: .connectionInvalidated)`. Run: red, on
    /// the answer (`.granted`) and on the count, in each of 10 debug and 10 release runs.
    @Test("An acquirer resumed inside a teardown finds the dying lease's fan mid-handback")
    func anAcquirerResumedInsideATeardownFindsTheHandbackBegun() async throws {
        guard #available(macOS 15.0, *) else {
            Issue.record("Task(executorPreference:) needs macOS 15; this test watches nothing here")
            return
        }
        let lane = OneLaneTaskExecutor()
        let scene = try await Self.parkedNewcomer(on: lane)
        defer { scene.gate.open() }

        let tornDown = AsyncSignal()
        Task(executorPreference: lane, priority: .medium) {
            await Fixture.openingThenInvalidating(
                scene.holder, opening: scene.gate, on: scene.authority)
            await tornDown.signal()
        }
        try await waitUntil("the newcomer was answered") { scene.answer.recorded != nil }

        #expect(
            scene.answer.recorded
                == .refused(.manualControlUnavailable(reason: .releaseInProgress)),
            """
            an acquirer that ran inside the holder's teardown was not told the fan is being handed \
            back. Granted, it holds fan 0 while the restore the teardown is about to issue is not \
            yet registered, so nothing refuses the lease and the restore lands under it.
            """)
        #expect(await scene.authority.leaseCount == 0)

        try await scene.restoreEntered.wait()
        await scene.restoreRelease.signal()
        try await tornDown.wait()
        #expect(await scene.authority.fansMidHandback.isEmpty, "the handback never returned")
    }

    /// The schedule can see one suspension: a job on the lease core that opens the gate and
    /// suspends once finds the newcomer answered when it resumes. The holder's lease still
    /// stands, so the answer is `.leaseHeldByAnotherClient`.
    ///
    /// The test above is only as strong as this. If the newcomer could not reach its decision
    /// within one suspension, a teardown that suspended between removal and registration would
    /// let it resume and then lose the race at its next suspension, and that test would stay
    /// green over the mutation it names. This fails in that case instead.
    ///
    /// **Mutation:** in `TeardownGapFixture.openingThenSuspendingOnce`, delete `await
    /// Task.yield()`. Run: red, unanswered, so the measurement is not vacuous.
    @Test("One suspension of the lease core lets the parked acquirer reach its answer")
    func theScheduleLandsTheAcquirerAtOneSuspension() async throws {
        guard #available(macOS 15.0, *) else {
            Issue.record("Task(executorPreference:) needs macOS 15; this test watches nothing here")
            return
        }
        let lane = OneLaneTaskExecutor()
        let scene = try await Self.parkedNewcomer(on: lane)
        defer { scene.gate.open() }

        let measured = Fixture.GrantAnswer()
        Task(executorPreference: lane, priority: .medium) {
            let seen = await Fixture.openingThenSuspendingOnce(
                opening: scene.gate, reading: scene.answer, on: scene.authority)
            measured.record(seen ?? .failed("unanswered after one suspension of the lease core"))
        }
        try await waitUntil("the measuring job resumed") { measured.recorded != nil }

        #expect(
            measured.recorded
                == .refused(.manualControlUnavailable(reason: .leaseHeldByAnotherClient)),
            """
            the newcomer had not reached its decision when the lease core's job resumed from one \
            suspension, so a suspension between a teardown's removal and its registration could \
            go unseen by the test above.
            """)
        #expect(await scene.authority.leaseCount == 1)
    }
}
