import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// What is sent behind a held `apply` on the same connection, and what it is told
/// ([#413](https://github.com/blamechris/Aeolus/issues/413)).
///
/// The helper answers a connection's `hello`, `snapshot`, `acquireLease` and `apply` in the order
/// they were sent (D25). So a `snapshot` sent while an `apply` is engaging fans waits at the helper
/// for it, and the client now starts that snapshot's deadline when the `apply` settles rather than
/// at its send (`InFlightMessages`). `renewLease`, `releaseLease` and `restoreAllToAutomatic` are
/// dispatched the moment they arrive (#229), and theirs still starts at their send.
///
/// ## Nothing here waits for a deadline, and no clock moves blind
///
/// Every client measures its deadlines on `HelperClientApplyDeadlineTests`' `ManualClock` and
/// deadlines, 7 s for a gated verb and 70 s per fan. A deadline runs out when the test moves the
/// hands past it and at no other time. Before the hands move, the test has observed what they are
/// meant to move past: the arrival at the helper of the message whose deadline is in question, the
/// client's own count of running deadlines (`HelperClient.deadlinesRunning`), and that many
/// sleepers parked on the clock. The count is what makes the last step sound. A deadline's instant
/// is read when its timer first runs (`InFlightMessages`), so a timer that has not run yet has no
/// instant to move past, and only the client knows it exists. The XPC round trips are the only
/// thing on the wall clock, waited for with a generous bound and never asserted on.
@Suite("A sequenced verb's deadline starts at its turn", .timeLimit(.minutes(1)))
struct HelperClientSequencedDeadlineTests {

    typealias Fixture = HelperClientApplyDeadlineTests
    typealias Parked = HelperClientApplyDeadlineTests.ParkedApply

    static let deadlines = HelperClientApplyDeadlineTests.deadlines
    static let lease = HelperClientApplyDeadlineTests.lease
    static let oneFan = [HelperClientApplyDeadlineTests.fan(0)]

    /// The parked `apply`'s own deadline: `gatedVerb` plus one fan, 77 s here.
    static let applyDeadline = deadlines.gatedVerb + deadlines.applyPerFan

    /// Past a gated verb's 7 s and short of the `apply`'s 77 s by any reading.
    static let insideTheApply = deadlines.gatedVerb + deadlines.applyPerFan / 2

    /// `ParkedApply` sends one `snapshot` before the `apply`, so the second to arrive is the one
    /// sent behind it.
    static func snapshotsArrived(at harness: ClientListenerHarness) -> Int {
        harness.arrivals.filter { $0 == "snapshot" }.count
    }

    /// Sends a `snapshot` behind the parked `apply`, and returns once the helper has received it.
    static func snapshotBehind(_ parked: Parked) async throws -> Task<SystemSnapshot, Error> {
        let client = parked.client
        let snapshot = Task { try await client.snapshot() }
        try await waitUntil(
            "the snapshot reached the helper behind the apply",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            snapshotsArrived(at: parked.harness) == 2
        }
        return snapshot
    }

    /// The `apply`'s deadline is the only one running, and it has parked, so the hands can move.
    ///
    /// The first half is the claim behind every test here: a message waiting for its turn has no
    /// deadline yet. Read from the client's own count, it holds whether or not a timer started too
    /// early has run. The second half is what makes the move that follows land past every
    /// running deadline, the early one included.
    static func expectOnlyTheApplysDeadline(
        _ parked: Parked, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let running = await parked.client.deadlinesRunning
        #expect(
            running == 1, "\(running) deadlines are running behind a held apply",
            sourceLocation: sourceLocation)
        try await waitUntil(
            "every running deadline has parked on the clock",
            timeout: StallTolerantWait.deliveryBudget,
            { await parked.client.deadlinesRunning == parked.clock.sleepers },
            sourceLocation: sourceLocation)
    }

    /// What every message this client killed itself is told, and must not be: the answer to an
    /// `apply` is "may have applied; control ended" (#414), never 4099's "not installed".
    static func expectToldTheClientGaveUp(
        _ error: HelperClientError?, _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            error == .connectionAbandoned, "\(what) was told \(String(describing: error))",
            sourceLocation: sourceLocation)
        let description = error?.errorDescription ?? ""
        for truth in [
            "Nothing can be said about whether it took effect", "ends any manual control",
        ] {
            #expect(
                description.contains(truth), "\(what) was told: \(description)",
                sourceLocation: sourceLocation)
        }
        #expect(
            !description.contains("not installed"), "\(what) was told: \(description)",
            sourceLocation: sourceLocation)
    }

    // MARK: - Behind a held apply

    /// **D5. A snapshot sent while an `apply` is held inside its own deadline is answered.**
    ///
    /// The defect: the snapshot's 7 s ran from its send while it waited at the helper behind an
    /// `apply` that may lawfully take 77 s here. It was cut off, the cut-off discarded the
    /// connection, and the lease ended for a helper inside its contract.
    ///
    /// With the snapshot at the helper, the only deadline running is the `apply`'s. The hands move
    /// to 42 s, past the snapshot's own deadline and inside the `apply`'s. Then the helper answers
    /// the `apply`, the snapshot's turn comes, and it is answered on the connection the test
    /// started with.
    ///
    /// **Mutation:** in `InFlightMessages.admit`, start every message's deadline at once, turn or
    /// not. Run: red on the client's count of running deadlines, 2 where the claim is 1, and on
    /// the snapshot's answer, thrown `helperNeverAnswered(after: 7.0 seconds)`: cut off at the
    /// move, inside the `apply`'s deadline.
    @Test("A snapshot behind a lawful apply is not cut off")
    func aSnapshotBehindALawfulApplyIsNotCutOff() async throws {
        let parked = try await Parked.sending(Self.oneFan)
        defer { parked.watcher.cancel() }
        let snapshot = try await Self.snapshotBehind(parked)
        try await Self.expectOnlyTheApplysDeadline(parked)

        parked.clock.advance(by: Self.insideTheApply)

        await parked.release.signal()
        _ = try await Fixture.answer(of: snapshot)
        try await parked.expectAnsweredOnTheSameConnection()
    }

    /// **A snapshot behind an `apply` that runs past its own deadline is answered by the discard,
    /// and told what is true.**
    ///
    /// Past its deadline the `apply` is cut off and the connection discarded, as #414 ruled. The
    /// snapshot was waiting for its turn on that connection. It must not be left waiting, and it
    /// must not be told the helper is not installed, which is what the client's own `invalidate()`
    /// says when it reaches a parked message as 4099. Health stays `.unresponsive`: the snapshot's
    /// answer passes through `translate(_:on:)` as itself and is not a second timeout.
    ///
    /// **Mutation:** in `HelperClient.discardConnection`, delete
    /// `inFlight.abandonAll(on: generation, answering: verdict)`, which leaves the parked snapshot
    /// to translate's default arm. Run: red on the snapshot's error, `helperUnreachable(code:
    /// 4099)`, and on the three lines of its description.
    @Test("A snapshot behind an apply past its deadline is answered with the discard")
    func aSnapshotBehindACutOffApplyIsAnsweredWithTheDiscard() async throws {
        let parked = try await Parked.sending(Self.oneFan)
        defer { parked.watcher.cancel() }
        let snapshot = try await Self.snapshotBehind(parked)
        try await Self.expectOnlyTheApplysDeadline(parked)

        parked.clock.advance(by: Self.applyDeadline)
        await #expect(throws: HelperClientError.helperNeverAnswered(after: Self.applyDeadline)) {
            try await Fixture.answer(of: parked.apply)
        }
        let error = await #expect(throws: HelperClientError.self) {
            _ = try await Fixture.answer(of: snapshot)
        }
        Self.expectToldTheClientGaveUp(error, "the snapshot behind the cut-off apply")

        #expect(await parked.client.health == .unresponsive)
        #expect(parked.clock.sleepers == 0, "a deadline outlived the connection it was on")
        try await waitUntil(
            "the helper saw the connection go", timeout: StallTolerantWait.deliveryBudget
        ) {
            await parked.authority.invalidatedConnections.count == 1
        }

        await parked.release.signal()
        #expect(parked.harness.sessions.count == 1)
    }

    /// **An `apply` ended by the client's own discard says "may have applied; control ended"
    /// (#413's comment).**
    ///
    /// Behind the parked `apply`, a heartbeat the helper holds runs out its own deadline, counted
    /// from its send. The client discards the connection, and that discard is what ends the
    /// `apply`: before #413 the `apply` then read the client's own `invalidate()` as 4099, "not
    /// installed or not yet approved", about a helper that had accepted it.
    ///
    /// The comment's own route — a *sequenced* verb behind the `apply` timing out — no longer
    /// exists: the verb behind waits for its turn, and the `apply` settles before its deadline can
    /// begin. The heartbeat is the verb behind an `apply` that can still time out while the `apply`
    /// is parked, because its deadline runs from its send.
    ///
    /// **Mutation:** in `HelperClient.discardConnection`, delete
    /// `inFlight.abandonAll(on: generation, answering: verdict)`, so the `apply` falls back to
    /// `translate`'s default arm. Run: red on the `apply`'s error, `helperUnreachable(code: 4099)`,
    /// and on the three lines of its description.
    @Test("An apply ended by the client's own discard says control ended")
    func anApplyEndedByTheClientsOwnDiscardSaysControlEnded() async throws {
        let releaseRenewal = AsyncSignal()
        let parked = try await Parked.sending(Self.oneFan, holdingRenewals: releaseRenewal)
        defer { parked.watcher.cancel() }

        let client = parked.client
        let renewal = Task { try await client.renewLease(id: Self.lease.id) }
        try await waitUntil(
            "the renewal is held beside the apply, its deadline running",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            await parked.authority.hasBeenAskedToRenew && parked.clock.sleepers == 2
        }

        parked.clock.advance(by: Self.deadlines.gatedVerb)
        await #expect(
            throws: HelperClientError.helperNeverAnswered(after: Self.deadlines.gatedVerb)
        ) {
            _ = try await Fixture.answer(of: renewal)
        }
        let error = await #expect(throws: HelperClientError.self) {
            try await Fixture.answer(of: parked.apply)
        }
        Self.expectToldTheClientGaveUp(error, "the apply the discard ended")
        #expect(await parked.client.health == .unresponsive)
        try await waitUntil(
            "the helper saw the connection go", timeout: StallTolerantWait.deliveryBudget
        ) {
            await parked.authority.invalidatedConnections.count == 1
        }

        await releaseRenewal.signal()
        await parked.release.signal()
        #expect(parked.harness.sessions.count == 1)
    }

    /// **A heartbeat beside a held `apply` keeps its own deadline, counted from its send.**
    ///
    /// The helper does not queue `renewLease` (#229), so nothing it waits for at the helper is
    /// ahead of it. Its deadline starts as it is sent, while the `apply` is still held: two
    /// deadlines are running. It is answered inside it, and the `apply` is then answered on the
    /// same connection.
    ///
    /// **Mutation:** in `InFlightMessages.admit`, record every message as sequenced. Run: red on
    /// the wait for the second sleeper, which never parks, the renewal's deadline waiting for the
    /// `apply` to settle.
    @Test("A renewal beside a held apply keeps its own deadline")
    func aRenewalBesideAHeldApplyKeepsItsOwnDeadline() async throws {
        let releaseRenewal = AsyncSignal()
        let parked = try await Parked.sending(Self.oneFan, holdingRenewals: releaseRenewal)
        defer { parked.watcher.cancel() }

        let client = parked.client
        let renewal = Task { try await client.renewLease(id: Self.lease.id) }
        try await waitUntil(
            "the renewal is held beside the apply, its own deadline running from its send",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            await parked.authority.hasBeenAskedToRenew && parked.clock.sleepers == 2
        }

        parked.clock.advance(by: Self.deadlines.gatedVerb / 2)
        #expect(parked.clock.sleepers == 2, "a deadline ran out short of the renewal's own")
        await releaseRenewal.signal()
        #expect(try await Fixture.answer(of: renewal) == Self.lease)

        await parked.release.signal()
        try await parked.expectAnsweredOnTheSameConnection()
    }

    // MARK: - Behind a cancelled apply

    /// **A snapshot behind a cancelled `apply` still waits for the `apply`'s turn.**
    ///
    /// Cancelling a caller says nothing about the helper, which is still inside the `apply`, and
    /// the snapshot sent after it still waits for it there. If the cancellation settled the
    /// `apply`, the snapshot's deadline would start while the helper was lawfully engaging: the
    /// app cancelling an `apply` it had started, by navigating away, would cut off its next read
    /// and end the lease. So the `apply`'s deadline outlives its caller.
    ///
    /// **Mutation:** in `HelperClient.exchange`, settle the message when its caller's wait comes
    /// back cancelled. Run: red on the sleeper count after the cancellation, and on
    /// `snapshot.value`, cut off at `helperNeverAnswered(after: 7.0 seconds)`.
    @Test("A snapshot behind a cancelled lawful apply is not cut off")
    func aSnapshotBehindACancelledLawfulApplyIsNotCutOff() async throws {
        let parked = try await Parked.sending(Self.oneFan)
        defer { parked.watcher.cancel() }

        parked.apply.cancel()
        guard case .failure(let thrown) = await parked.apply.result else {
            Issue.record("a cancelled apply came back answered")
            return
        }
        #expect(thrown is CancellationError, "a cancelled caller was told \(thrown)")
        #expect(parked.clock.sleepers == 1, "the apply's deadline ended with its caller")

        let snapshot = try await Self.snapshotBehind(parked)
        try await Self.expectOnlyTheApplysDeadline(parked)
        parked.clock.advance(by: Self.insideTheApply)
        #expect(parked.clock.sleepers == 1)

        await parked.release.signal()
        _ = try await Fixture.answer(of: snapshot)
        #expect(await parked.client.currentGeneration == parked.generation)
        #expect(await parked.client.health == .handshaken)
        #expect(!parked.health.entries.contains(.unresponsive), "\(parked.health.entries)")
        #expect(await parked.authority.invalidatedConnections.isEmpty)
        #expect(parked.harness.sessions.count == 1)
    }

    /// **Behind a cancelled `apply` that never answers, the snapshot is cut off after the
    /// `apply`'s deadline and then its own.**
    ///
    /// The bound the previous test's rule still needs. With nobody waiting on the `apply`, its
    /// deadline running out settles it and discards nothing, because cancellation is not a
    /// teardown; the snapshot's turn comes then, and its own deadline is what discards. One extra
    /// deadline on a genuinely wedged helper, and no read held for ever.
    ///
    /// **Mutation:** in `InFlightMessages.deadlineRanOut`, remove the message without passing the
    /// turn. Run: red on the sleeper count after the `apply`'s deadline, and on the time limit,
    /// the snapshot waiting for a turn nothing will pass.
    @Test("A snapshot behind a cancelled wedged apply is cut off after both deadlines")
    func aSnapshotBehindACancelledWedgedApplyIsCutOffAfterBothDeadlines() async throws {
        let parked = try await Parked.sending(Self.oneFan)
        defer { parked.watcher.cancel() }

        parked.apply.cancel()
        _ = await parked.apply.result
        let snapshot = try await Self.snapshotBehind(parked)

        parked.clock.advance(by: Self.applyDeadline)
        try await waitUntil(
            "the snapshot's turn came when the apply's deadline ran out",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            parked.clock.sleepers == 1
        }
        #expect(
            await parked.client.currentGeneration == parked.generation,
            "a deadline with nobody waiting on it discarded the connection")
        #expect(await parked.client.health == .handshaken)

        parked.clock.advance(by: Self.deadlines.gatedVerb)
        await #expect(
            throws: HelperClientError.helperNeverAnswered(after: Self.deadlines.gatedVerb)
        ) {
            _ = try await Fixture.answer(of: snapshot)
        }
        #expect(await parked.client.health == .unresponsive)

        await parked.release.signal()
        #expect(parked.harness.sessions.count == 1)
    }

    // MARK: - Behind a disconnect

    /// **An `apply` in flight when its caller disconnects says control ended.**
    ///
    /// `disconnect()` is the teardown a caller asks for, and it ends any lease the connection
    /// held. A message still in flight on it was killed by this client, not refused by a missing
    /// helper, and is told so. Health is `.idle`, because asking to disconnect is not a failure.
    ///
    /// **Mutation:** in `HelperClient.disconnect()`, answer with `.helperUnreachable(code:
    /// XPCTransportCode.invalid)`. Run: red on the `apply`'s error and on all three lines of its
    /// description.
    @Test("An apply in flight at a disconnect says control ended")
    func anApplyInFlightAtADisconnectSaysControlEnded() async throws {
        let parked = try await Parked.sending(Self.oneFan)
        defer { parked.watcher.cancel() }

        await parked.client.disconnect()
        let error = await #expect(throws: HelperClientError.self) {
            try await Fixture.answer(of: parked.apply)
        }
        Self.expectToldTheClientGaveUp(error, "the apply in flight at the disconnect")
        #expect(await parked.client.health == .idle)
        #expect(parked.clock.sleepers == 0, "a deadline outlived the connection it was on")

        await parked.release.signal()
        #expect(parked.harness.sessions.count == 1)
    }
}
