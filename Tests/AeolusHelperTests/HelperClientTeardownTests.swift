import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// What it costs to give up on a connection, and what must never cost one.
///
/// Split from `HelperClientConnectionTests` where the subject changes. That file is about a
/// connection that **fails**; this one is about the client deciding to stop using one — which
/// is a different question with a much sharper edge, because the helper releases a
/// connection's leases when it dies. Every teardown here hands the fans back to automatic on
/// a real machine, so the tests are as much about the paths that must *not* reach it as the
/// ones that must.
///
/// Both drive the real client over a real anonymous listener, admitted by a pinning policy
/// declared in the test target that applies no requirement — so neither says anything about
/// whether the production requirement is correct.
@Suite("Giving up on an XPC connection", .timeLimit(.minutes(1)))
struct HelperClientTeardownTests {

    // MARK: - Giving up on a connection

    /// A connection this client gives up on is **invalidated**, so the helper finds out.
    ///
    /// `AeolusXPCProtocol` makes connection death the primary lease teardown and the 120 s
    /// TTL an independent backstop that shares no code path with it. The helper implements
    /// its half from the listener's invalidation handler, which fires only if somebody
    /// invalidates — so a client that dropped its reference and left the object alive would
    /// leave a root daemon holding manual control for a caller that has gone, and the two
    /// mechanisms that are required to be independent would have become one.
    ///
    /// Read at the **authority**, because that is where the consequence lands:
    /// `connectionDidInvalidate` is the call that releases what the connection was holding.
    ///
    /// **Mutation:** in `HelperClient.discardConnection(_:as:)`, delete `dying?.invalidate()`.
    /// Run: red on `waitUntil`'s deadline — the helper is never told, and the authority never
    /// records the release.
    @Test("A connection this client gives up on is invalidated, not merely dropped")
    func aDiscardedConnectionIsInvalidated() async throws {
        let authority = RecordingFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let pinning = CountingClientPinning()
        let client = harness.client(pinning: pinning)

        _ = try await client.snapshot()
        #expect(await client.health == .handshaken)

        await client.disconnect()

        try await waitUntil("the helper was told its connection died") {
            for call in await authority.calls {
                if case .connectionDidInvalidate = call { return true }
            }
            return false
        }
        #expect(await client.negotiated == nil)
        #expect(await client.health == .idle, "a deliberate teardown is not a failure")

        // And it is a teardown rather than a break: the next call is served, on a new
        // connection, from cold.
        _ = try await client.snapshot()
        #expect(pinning.connectionsBuilt == 2)
        #expect(harness.sessions.count == 2)
    }

    /// A reply that could not be delivered costs the **message**, not the connection.
    ///
    /// `NSXPCConnectionReplyInvalid` (4101) is the one transport code here that is not about
    /// the connection: the reply block could not be invoked, and the connection is alive and
    /// still handshaken. It was falling into the arm that treats everything unrecognised as
    /// an invalidation, so one undeliverable answer dropped the client's only reference to a
    /// live connection — orphaning the helper-side session, and any lease bound to it, until
    /// the 120 s TTL. That collapses the two teardown paths `AeolusXPCProtocol` requires to
    /// be independent into one, over a failure that cost a single answer.
    ///
    /// **Driven through `translate` directly, because 4101 cannot be provoked from outside.**
    /// It is raised by libxpc when a reply block is over-released or carries something that
    /// will not encode — neither of which a test can arrange against a well-formed peer. The
    /// alternative was to ship the arm with nothing exercising it, which is the finding this
    /// round is answering.
    ///
    /// **Mutation:** delete the `case XPCTransportCode.replyInvalid` arm from
    /// `HelperClient.translate(_:on:)`. Run: red three times over — the error becomes
    /// `helperUnreachable(code: 4101)`, `negotiated` is cleared, and the next call builds a
    /// second connection.
    @Test("A reply that could not be delivered costs the message, not the connection")
    func anUndeliverableReplyCostsTheMessageNotTheConnection() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let pinning = CountingClientPinning()
        let client = harness.client(pinning: pinning)

        _ = try await client.snapshot()
        #expect(await client.health == .handshaken)

        let undeliverable = NSError(
            domain: NSCocoaErrorDomain, code: XPCTransportCode.replyInvalid)
        let translated = await client.translate(
            undeliverable, on: await client.currentGeneration)

        #expect(translated as? HelperClientError == .replyNotDelivered)
        #expect(
            await client.negotiated != nil,
            "one undeliverable reply tore down a connection that is still alive")
        #expect(await client.health == .handshaken)

        _ = try await client.snapshot()
        #expect(pinning.connectionsBuilt == 1)
        #expect(harness.sessions.count == 1)
    }

    /// A handler from a connection this client has already replaced does not tear down the
    /// live one.
    ///
    /// **The suite plays libxpc here, and that is deliberate.** libxpc fires a dead
    /// connection's handlers on its own schedule, and the interleaving `generation` exists
    /// for — a straggler arriving *after* its replacement is live and handshaken — cannot be
    /// provoked on demand over a real connection: every way of killing connection 1 delivers
    /// its handler long before connection 2 could be built. So these two functions are
    /// called directly, with the generation a straggler would carry. What is under test is
    /// the guard, and this is the only door it has.
    ///
    /// Generation `0` is what this client starts at, before it has built anything, so it
    /// unambiguously names a connection older than the live one. If that ever stopped being
    /// true the guard would reject nothing and this test would go red, not quietly weaken.
    ///
    /// **Mutation:** delete `guard generation == self.generation else { return }` from both
    /// `connectionWasInterrupted(_:)` and `discardConnection(_:as:)` — the pair M2 showed
    /// nothing was testing. Run: red on `negotiated`, which the stale invalidation clears,
    /// and on `connectionsBuilt`, which rises to 2 because the live connection was dropped.
    @Test("A late handler from a replaced connection leaves the live one alone")
    func aLateHandlerLeavesTheLiveConnectionAlone() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let pinning = CountingClientPinning()
        let client = harness.client(pinning: pinning)

        _ = try await client.snapshot()
        #expect(await client.health == .handshaken)

        await client.connectionWasInterrupted(0)
        await client.connectionWasInvalidated(0)

        #expect(
            await client.negotiated != nil,
            "a handler for a connection two generations ago cleared the live handshake")
        #expect(await client.health == .handshaken)

        _ = try await client.snapshot()
        #expect(
            pinning.connectionsBuilt == 1,
            """
            the client built \(pinning.connectionsBuilt) connections. A stale handler tore \
            down a connection that was working, which is the failure the generation exists \
            to prevent and the one that only appears under the timing hardest to reproduce.
            """)
        #expect(harness.sessions.count == 1)
    }

    /// A handshake the helper answered and this client could not read leaves **no reusable
    /// connection**.
    ///
    /// This is the wedge in its permanent form. The peer here is the real
    /// `HelperConnectionSession` and it has recorded the handshake — the harness replaces
    /// only the reply payload — so a second `hello` on that connection is refused with
    /// `invalidParameter` for the rest of its life. A client that kept the connection would
    /// find `negotiatedReply == nil`, send `hello` again, and be refused; every gated verb
    /// after it fails the same way, `releaseLease` included, so the lease teardown ADR 0005
    /// requires to be independent of the TTL goes dark.
    ///
    /// **Mutation:** in `HelperClient.performHandshake(generation:)`, delete the
    /// `catch` that calls `discardConnection`. Run: red on `sessions.count`, and on the
    /// thrown type before it — the second attempt reuses the connection, sends a second
    /// `hello`, and comes back as an `AeolusXPCFault` rather than a `HelperClientError`.
    @Test("A handshake this client could not read leaves no reusable connection")
    func anUnreadableHandshakeLeavesNoReusableConnection() async throws {
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(), garblingHandshakeReplies: true)
        let pinning = CountingClientPinning()
        let client = harness.client(pinning: pinning)

        await #expect(throws: HelperClientError.self) { try await client.snapshot() }
        let first = try #require(harness.sessions.first)
        #expect(
            await first.handshakeState != nil,
            "the peer must have recorded the handshake, or this is not the case under test")

        await #expect(throws: HelperClientError.self) { try await client.snapshot() }

        #expect(pinning.connectionsBuilt == 2)
        #expect(
            harness.sessions.count == 2,
            """
            the client made \(harness.sessions.count) session(s). The second attempt reused \
            a connection whose peer has already negotiated, where no `hello` can ever \
            succeed again — so every gated verb on it, `releaseLease` included, is refused \
            for the life of the client.
            """)
    }

    /// A handshake the helper **refused** also leaves no reusable connection.
    ///
    /// The other door into the same rule, and the one a user meets: a helper whose protocol
    /// range does not overlap this client's. Whether the peer recorded the refused `hello`
    /// is the peer's business and not something a client can see from outside, so the rule
    /// does not try to distinguish — no `HelloReply`, no reusable connection.
    ///
    /// **Mutation:** the same one as above. Run: red on `sessions.count`, which stays at 1.
    @Test("A refused handshake leaves no reusable connection")
    func aRefusedHandshakeLeavesNoReusableConnection() async throws {
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(),
            helperRange: ProtocolVersionRange(minimumSupported: 2, current: 3))
        let pinning = CountingClientPinning()
        let client = harness.client(pinning: pinning)

        await #expect(throws: (any Error).self) { try await client.snapshot() }
        #expect(await client.health == .versionMismatched)

        await #expect(throws: (any Error).self) { try await client.snapshot() }
        #expect(pinning.connectionsBuilt == 2)
        #expect(harness.sessions.count == 2, "the refused connection was handed a second hello")
    }

    /// A verb that timed out does not take every verb after it down with it.
    ///
    /// `docs/SAFETY.md` § 4 calls the wedged `io_connect_t` the expected case, not an exotic
    /// one. The unanswered message stays at the head of its connection's queue with nothing
    /// able to discard it, and since D25 the helper answers a connection's messages in the
    /// order they were sent — so a client that kept that connection would queue every later
    /// gated verb behind a message that is never coming back. `renewLease` and `releaseLease`
    /// are both gated, which is a lease holder that can neither prove it still wants the
    /// fans nor give them up.
    ///
    /// The second verb is `acquireLease`, whose refusal is a **completed round trip**: being
    /// told `manualControlUnavailable` is proof the helper was reached, in a way that a
    /// second `snapshot` — parked in the same authority — could not be.
    ///
    /// **Mutation:** in `HelperClient.translate(_:on:)`, delete the `case
    /// .helperNeverAnswered` arm that discards the connection. Run: red on this
    /// expectation — `acquireLease` queues behind the parked snapshot and comes back as
    /// `helperNeverAnswered` instead of the fault.
    @Test("A verb that timed out does not wedge the verbs after it")
    func aTimedOutVerbDoesNotWedgeTheVerbsAfterIt() async throws {
        let gate = AsyncSignal()
        let harness = ClientListenerHarness(authority: GatedSnapshotAuthority(gate: gate))
        let deadline = Duration.milliseconds(250)
        let client = harness.client(
            deadlines: HelperClientDeadlines(
                gatedVerb: deadline, panicVerb: .seconds(5), handshakeVerb: .seconds(5)))

        await #expect(throws: HelperClientError.helperNeverAnswered(after: deadline)) {
            try await client.snapshot()
        }
        #expect(await client.health == .unresponsive)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
        ) {
            _ = try await client.acquireLease(
                LeaseRequest(holderDescription: "test client", fanIndices: [0]))
        }
        #expect(harness.sessions.count == 2, "the wedged connection was reused")

        await gate.signal()
    }

    /// The panic path still reaches the helper after a gated verb has timed out.
    ///
    /// **A preservation guard, not a mutation kill, and it is written down as such.** The
    /// panic path was already unaffected by a wedge — it takes the ungated proxy and the
    /// helper dispatches it outside the per-connection sequencer — so no mutation of the
    /// C5 fix reddens this. What it exists to catch is a future change to the teardown
    /// making `restoreAllToAutomatic` depend on a connection the client has just discarded.
    /// #159 is built on this working in exactly the state a user reaches for it in.
    @Test("The panic path still reaches the helper after a gated verb has timed out")
    func thePanicPathSurvivesATimedOutVerb() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let deadline = Duration.milliseconds(250)
        let client = harness.client(
            deadlines: HelperClientDeadlines(
                gatedVerb: deadline, panicVerb: .seconds(5), handshakeVerb: .seconds(5)))

        await #expect(throws: HelperClientError.helperNeverAnswered(after: deadline)) {
            try await client.snapshot()
        }

        try await client.restoreAllToAutomatic()
        #expect(await authority.hasRestored)

        await gate.signal()
    }

    /// The panic path is dispatched while a verb sent before it is still parked.
    ///
    /// The property #159 is built on, asserted end to end over a real connection rather than
    /// on either side alone: the helper exempts `restoreAllToAutomatic` from its
    /// per-connection ordering (D27) **and** this client sends it through the ungated proxy,
    /// so the message a user reaches for when the fans are wrong does not queue behind the
    /// message that is wrong. `OrderingExemptionTests` asserts the helper's half against
    /// `HelperXPCService` directly; this one asserts the pair.
    ///
    /// **Mutation:** in `HelperXPCService.restoreAllToAutomatic(reply:)`, replace `Task { … }`
    /// with `sequencer.enqueue { … }`. Run: red — the panic path queues behind the parked
    /// snapshot and this client's `panicVerb` deadline expires.
    @Test("The panic path is dispatched while a gated verb is still parked")
    func thePanicPathIsNotBlockedByAParkedVerb() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client(
            deadlines: HelperClientDeadlines(
                gatedVerb: .seconds(10), panicVerb: .seconds(5), handshakeVerb: .seconds(10)))

        let parked = Task { try await client.snapshot() }
        try await waitUntil("the snapshot reached the authority") { await authority.hasBeenAsked }

        try await client.restoreAllToAutomatic()
        #expect(await authority.hasRestored)

        await gate.signal()
        _ = try await parked.value
        #expect(harness.sessions.count == 1, "the panic path opened a second connection")
    }

    // MARK: - Cancellation is not a teardown

    /// A **cancelled** caller does not cost the connection.
    ///
    /// This is the trap the deadline remedy set. `PendingReply` gives up for two reasons —
    /// the deadline fired, or the caller's task was cancelled — and until the fallbacks were
    /// separated both produced `helperNeverAnswered`, which `translate(_:on:)` now acts on by
    /// invalidating the connection. So a SwiftUI view whose `.task` was cancelled by
    /// navigating away tore down a healthy, handshaken connection, and the helper released
    /// **every lease bound to it**: the fans handed back to automatic because a user changed
    /// tabs.
    ///
    /// Two further consequences make it worse than a spurious reconnect. `.unresponsive`
    /// would be a false statement about a helper that never failed to answer anything; and
    /// ADR 0006 makes `.handshaken` the only value licensing the helper's snapshot, so the
    /// app would start its own SMC poller beside a helper that is still polling — the single
    /// reader invariant that ADR exists to protect, broken by a cancellation.
    ///
    /// The distinction is drawn at the producer rather than guessed at afterwards: the
    /// cancellation fallback is a `CancellationError`, and `translate(_:on:)` passes it
    /// through untouched. **Nothing about the deadline changes** — a helper that genuinely
    /// does not answer still costs its connection.
    ///
    /// The message stays at the head of the helper's queue, and that is deliberate: the next
    /// verb queues behind it, hits its **own** deadline, and discards then. One extra timeout
    /// on a genuinely wedged helper is the correct price for never tearing down a healthy one.
    ///
    /// **Mutation:** in `HelperClient.exchange(on:within:_:)`, build the latch with
    /// `PendingReply(ifNothingArrives:)` so cancellation and the deadline share one fallback
    /// again. Run: red on `health`, which reads `.unresponsive`, and on `negotiated`, which
    /// is `nil`.
    @Test("A cancelled caller does not tear down the connection")
    func aCancelledCallerDoesNotTearDownTheConnection() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client(
            deadlines: HelperClientDeadlines(
                gatedVerb: .seconds(30), panicVerb: .seconds(30), handshakeVerb: .seconds(30)))

        // A completed round trip first, so the connection is unambiguously healthy before
        // anything is cancelled. `acquireLease`'s refusal is a round trip that *finished*;
        // `snapshot` on this authority parks and never comes back, which is the next step.
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
        ) {
            _ = try await client.acquireLease(
                LeaseRequest(holderDescription: "test client", fanIndices: [0]))
        }
        #expect(await client.health == .handshaken)

        let parked = Task { try await client.snapshot() }
        try await waitUntil("the snapshot reached the authority") { await authority.hasBeenAsked }
        parked.cancel()

        // What the caller is *told* is a second assertion, and it needs its own mutation.
        // Separating the fallbacks is what saves the connection; passing the cancellation
        // through `translate(_:on:)` untouched is what stops the client reporting
        // `helperUnreachable` — a statement that the helper did not answer, about a helper
        // that was never given the chance to fail.
        //
        // **Mutation:** delete `if error is CancellationError { return error }` from
        // `translate(_:on:)`. Run: red here alone — the teardown expectations below stay
        // green, because a bridged `CancellationError` is not in `NSCocoaErrorDomain` and so
        // misses the arm that discards. That is exactly why this expectation exists: the
        // first version of this test asserted only the teardown and the mutation survived it.
        guard case .failure(let thrown) = await parked.result else {
            Issue.record("a cancelled verb came back with a snapshot")
            return
        }
        #expect(
            thrown is CancellationError,
            "a cancelled caller was told \(thrown) rather than that it had been cancelled")

        #expect(
            await client.health == .handshaken,
            """
            a cancelled caller moved the connection's health. `.unresponsive` would be a \
            false statement about a helper that answered everything asked of it, and ADR \
            0006 reads anything but `.handshaken` as licence for the app to start its own \
            SMC poller beside one that is already running.
            """)
        #expect(
            await client.negotiated != nil,
            "a cancelled caller discarded a handshake the helper still honours")

        await gate.signal()
    }

    /// A cancelled verb does not release a lease this client is holding.
    ///
    /// The consequence that actually reaches a user, given its own assertion rather than
    /// left riding on the health signal. A lease lives on its connection: the helper releases
    /// it from the listener's invalidation handler, so *any* teardown — however
    /// well-intentioned — hands the fans back. A client that dropped a lease because a view
    /// went away would be `CLAUDE.md` rule 2 inverted, with the lease expiring for a reason
    /// its holder never chose and could not see.
    ///
    /// **The session count is the load-bearing assertion.** It is synchronous with a round
    /// trip that has completed: if the connection had been discarded, the verb after the
    /// cancellation builds a new one and the listener mints a second session. The authority's
    /// own record is checked too, but a teardown reaches it through a detached task, so on
    /// its own it could read empty while one was still in flight.
    ///
    /// **Mutation:** the same one as above. Run: red on `sessions.count`, which becomes 2,
    /// and on `invalidatedConnections`, which names the connection the lease was bound to.
    @Test("A cancelled verb does not release a lease this client is holding")
    func aCancelledVerbDoesNotReleaseALease() async throws {
        let gate = AsyncSignal()
        let lease = Lease(
            id: UUID(),
            holderDescription: "test client",
            expiresAt: Date(timeIntervalSince1970: 1_000_030),
            timeToLive: 30
        )
        let authority = LeaseGrantingAuthority(lease: lease, snapshotGate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client(
            deadlines: HelperClientDeadlines(
                gatedVerb: .seconds(30), panicVerb: .seconds(30), handshakeVerb: .seconds(30)))

        let acquired = try await client.acquireLease(
            LeaseRequest(holderDescription: "test client", fanIndices: [0]))
        #expect(acquired == lease)

        let parked = Task { try await client.snapshot() }
        try await waitUntil("the snapshot reached the authority") {
            await authority.hasBeenAskedForSnapshot
        }
        parked.cancel()
        _ = try? await parked.value

        // Released so the parked message drains, and the connection is then used again —
        // which is what makes the session count below a completed round trip rather than a
        // read taken before any teardown could have landed.
        await gate.signal()
        #expect(try await client.renewLease(id: lease.id) == lease)

        #expect(
            harness.sessions.count == 1,
            """
            the listener minted \(harness.sessions.count) sessions. A second one means the \
            cancelled verb cost the connection, and the lease this client still holds died \
            with it — the fans back to automatic because a caller went away.
            """)
        #expect(await authority.invalidatedConnections.isEmpty)
    }
}
