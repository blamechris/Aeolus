import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// What the client does when the connection underneath it fails, and what it refuses to do
/// before one exists.
///
/// The other half of `HelperClientTests`, split where the subject changes: everything there
/// is about a connection that works, and everything here is about one that stops — or one
/// this client will not open at all. Both drive the real client over a real anonymous
/// listener, and both are admitted by a pinning policy declared in the test target that
/// applies no requirement, so neither says anything about whether the production requirement
/// is correct.
@Suite("The XPC client when the connection fails", .timeLimit(.minutes(1)))
struct HelperClientConnectionTests {

    // MARK: - Interruption and invalidation

    /// The helper process was replaced: the connection survives, everything it negotiated
    /// does not, and the next verb re-handshakes.
    ///
    /// The `HelloReply` describes a process that no longer exists — its build string, its
    /// capabilities — and a lease it granted died with it. Keeping the reply would be a
    /// claim about a peer nobody has spoken to.
    ///
    /// **Mutation:** in `HelperClient.connectionWasInterrupted(_:)`, stop clearing
    /// `negotiatedReply`. Run: red — the second session never sees a `hello`, so its
    /// `messageCount` is 1 and its `handshakeState` is `nil`, and the snapshot is refused
    /// with `handshakeRequired`.
    @Test("Interruption discards the negotiated reply and the next verb re-handshakes")
    func interruptionDiscardsTheHandshake() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client()

        _ = try await client.snapshot()
        #expect(await client.negotiated != nil)

        harness.killHelperSideOfEveryConnection()
        try await waitUntil("the client saw the interruption") {
            await client.health == .interrupted
        }
        #expect(await client.negotiated == nil, "the old process's reply was kept")

        _ = try await client.snapshot()

        #expect(harness.sessions.count == 2, "libxpc reconnected to a new session")
        let second = try #require(harness.sessions.last)
        #expect(await second.messageCount == 2, "the client re-handshook: hello and snapshot")
        #expect(await second.handshakeState != nil)
        #expect(await client.health == .handshaken)
    }

    /// A message in flight when the helper dies fails as a restart, not as a refusal and not
    /// as silence.
    ///
    /// The reply block is dropped by libxpc and only the error handler runs, which is the
    /// case `AeolusXPCProtocol` calls the one that matters most.
    ///
    /// **Mutation:** in `HelperClient.exchange(on:within:_:)`, take the proxy with bare
    /// `remoteObjectProxy` instead of `remoteObjectProxyWithErrorHandler`. Run: red — the
    /// error handler never runs, so the call fails with `helperNeverAnswered` after the
    /// deadline instead.
    @Test("A message in flight when the helper dies is reported as a restart")
    func aMessageInFlightWhenTheHelperDiesIsARestart() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client(
            deadlines: HelperClientDeadlines(
                gatedVerb: .seconds(10), panicVerb: .seconds(10), handshakeVerb: .seconds(10)))

        // The hello is answered without touching the authority, so by the time the
        // authority has been asked the message in flight is the gated verb and not the
        // handshake.
        let parked = Task { try await client.snapshot() }
        try await waitUntil("the snapshot reached the authority") { await authority.hasBeenAsked }

        harness.killHelperSideOfEveryConnection()

        await #expect(throws: HelperClientError.helperRestarted) { _ = try await parked.value }
        await gate.signal()
    }

    /// A helper that refuses every connection is reported promptly, and the report names
    /// both of the things it could be.
    ///
    /// ADR 0005 measured that a requirement-refused peer and an absent one are
    /// indistinguishable at this layer: libxpc drops the connection with no message
    /// delivered either way. Naming one alone would be a guess presented as a diagnosis, so
    /// the client names both and leaves the narrowing to a caller that has another source —
    /// `HelperInstallationState` in the app.
    ///
    /// **What this test measured, which ADR 0005 did not.** A listener whose delegate
    /// returns `false` is reported to the client as `NSCocoaErrorDomain` **4097**, the same
    /// code a helper that died mid-call produces — not as the 4099 invalidation one might
    /// expect from "the connection was refused". That is why the client decides between
    /// "restarted" and "never answered" on whether this connection ever handshook rather
    /// than on the code: keying on the code alone would tell a user with no helper at all
    /// that theirs had restarted.
    ///
    /// **Mutation:** in `HelperClient.exchange(on:within:_:)`, take the proxy with bare
    /// `remoteObjectProxy`, so nothing reports the transport failure. Run: red —
    /// `helperNeverAnswered` after the deadline, which is the "it hung" answer this
    /// expectation exists to exclude.
    @Test("A helper refusing every connection is a prompt, honest error")
    func aRefusingHelperIsPromptAndNamesBothPossibilities() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        harness.isAdmitting = false
        let client = harness.client()

        let error = await #expect(throws: HelperClientError.self) { try await client.snapshot() }

        let unreachable = try #require(error)
        guard case .helperUnreachable = unreachable else {
            Issue.record("a refused connection became \(unreachable)")
            return
        }
        let described = try #require(unreachable.errorDescription)
        #expect(described.contains("not installed"))
        #expect(described.contains("approved"))
        #expect(described.contains("refused"))
        #expect(
            await client.health != .handshaken,
            "a client that never handshook must not report a healthy connection")

        // The precondition, pinned portably. Without it this test passes under either
        // teardown order — both the 4097 arm and the `default` arm produce
        // `helperUnreachable` — so it would assert none of the measurement that justifies
        // deciding on `hasEverHandshaken` rather than on the code. It also keeps `harness`
        // alive to here: its `deinit` invalidates the listener, and a harness released at
        // the line above would leave this observing a dead listener rather than a refusing
        // delegate.
        #expect(harness.sessions.isEmpty, "the delegate refused, so it minted no session")
    }

    /// An invalidated connection is dropped, and the next call builds a new one — once.
    ///
    /// Counted at the pinning policy, because that is where a connection is actually made:
    /// from outside the actor a reused connection object and its replacement look identical.
    ///
    /// **Reached through a requirement the peer cannot satisfy, and deliberately not through
    /// a dead listener.** The first version of this test killed the listener and asserted the
    /// sequence measured on `Mac16,5` / macOS 26.6.2 — 4097, then 4099, then a rebuild. CI's
    /// older macOS does not reproduce it: invalidating an anonymous listener there left its
    /// client connection working, and the test failed on a machine where the client was
    /// behaving correctly. What is portable is the requirement refusal: libxpc reports it,
    /// this client treats the connection as dead, and the next call must therefore build
    /// another one.
    ///
    /// One attempt per call and no internal retry loop: a client that retried on its own
    /// against a mach name launchd is restarting a daemon behind is a boot-loop amplifier.
    /// The reconnect is observed as *the caller asking again*, which is what the second
    /// `snapshot()` here is.
    ///
    /// **Mutation:** in `HelperClient.connectionWasInvalidated(_:)`, stop clearing
    /// `connection`. Run: red — the count stays at one, because the dead object is reused.
    @Test("An invalidated connection is dropped and the next call builds another")
    func anInvalidatedConnectionIsDroppedAndTheNextCallBuildsAnother() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let pinning = CountingClientPinning(requirement: ImpossibleClientPinning.text)
        let client = harness.client(pinning: pinning)

        await #expect(throws: HelperClientError.self) { try await client.snapshot() }
        #expect(
            await client.health == .refused, "the peer failed the requirement this client pinned")
        #expect(pinning.connectionsBuilt == 1)

        await #expect(throws: HelperClientError.self) { try await client.snapshot() }
        #expect(
            pinning.connectionsBuilt == 2,
            """
            the client built \(pinning.connectionsBuilt) connection(s). A connection this \
            client has declared dead never works again, so reusing it makes every later call \
            fail for a reason that has nothing to do with the helper's current state.
            """)
    }

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

    // MARK: - Pinning

    /// A client that cannot verify the helper does not connect at all.
    ///
    /// Not "connects and hopes", and not "connects unpinned": the listener sees nothing,
    /// which is the assertion — a refusal that still opened a connection would be a client
    /// talking to whoever answered.
    ///
    /// **Mutation:** in `HelperClient.liveConnection()`, replace
    /// `try pinning.pinnedConnection(over: transport)` with `transport.makeConnection()`.
    /// Run: red — the snapshot succeeds and a session exists.
    @Test("A client that cannot pin the helper never opens a connection")
    func aClientThatCannotPinNeverConnects() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client(pinning: RefusingClientPinning())

        await #expect(
            throws: HelperClientError.clientCannotVerifyHelper(.runningProcessHasNoTeamIdentifier)
        ) {
            try await client.snapshot()
        }
        #expect(harness.sessions.isEmpty, "a refusal to pin still reached the listener")
        let health = await client.health
        #expect(
            health == .refused,
            """
            a client that refused to pin read as \(health). This is the ordinary \
            outcome of every `Monitor` build and every unsigned `fanctl` — the condition this \
            client diagnoses most confidently — and it used to read `.idle`, which says \
            nothing has been tried.
            """)
    }

    /// A peer that does not satisfy the requirement this client pinned is reported as that,
    /// not as an absent helper.
    ///
    /// **This case exists because it was measured, not because it is documented.**
    /// `NSXPCConnectionCodeSigningRequirementFailure` (4102) is documented from macOS 13 and
    /// ADR 0005 had only ever observed the indistinguishable 4099. Over an anonymous listener
    /// on `Mac16,5` / macOS 26.6.2, with a client-side requirement no peer can satisfy, the
    /// client's error handler receives 4102 — so the client can tell this one case apart
    /// after all, and does.
    ///
    /// **Mutation:** delete the `codeSigningRequirementFailure` arm from
    /// `HelperClient.translate(_:)`. Run: red — it becomes `helperUnreachable(code: 4102)`.
    @Test("A peer that fails the pinned requirement is named as such")
    func aPeerThatFailsTheRequirementIsNamedAsSuch() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client(pinning: ImpossibleClientPinning())

        await #expect(throws: HelperClientError.helperSignatureRejected) {
            try await client.snapshot()
        }
        #expect(await client.health == .refused)
    }

    // MARK: - The typed wrappers

    /// The lease verbs carry their DTOs across unchanged.
    ///
    /// `expiresAt` in particular: it is display-grade and enforced by nobody, and a client
    /// that quietly recomputed it from its own clock would be inventing the one field the UI
    /// renders as a countdown.
    @Test("The lease verbs return the helper's own DTOs unchanged")
    func theLeaseVerbsReturnTheHelpersDTOs() async throws {
        let lease = Lease(
            id: UUID(),
            holderDescription: "test client",
            expiresAt: Date(timeIntervalSince1970: 1_000_030),
            timeToLive: 30
        )
        let authority = LeaseGrantingAuthority(lease: lease)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client()

        let acquired = try await client.acquireLease(
            LeaseRequest(holderDescription: "test client", fanIndices: [0]))
        #expect(acquired == lease)
        #expect(try await client.renewLease(id: lease.id) == lease)

        let setting = FanSetting(fanIndex: 0, control: .fixed(rpm: 2_000))
        try await client.apply([setting], leaseID: lease.id)
        #expect(await authority.applied == [setting])

        try await client.releaseLease(id: lease.id)
        #expect(await authority.released == [lease.id])
    }

    /// A snapshot is returned as the helper built it, capture time included.
    ///
    /// No conversion, no reshaping, and above all no cached copy: there is nowhere in this
    /// client for a previous answer to live, which is how `CLAUDE.md` rule 6 is kept
    /// structural rather than remembered.
    @Test("A snapshot crosses unchanged, capture time included")
    func aSnapshotCrossesUnchanged() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client()

        #expect(try await client.snapshot() == .empty)
    }

    // MARK: - The health signal

    /// The health signal is readable and observable, and starts where a subscriber can act
    /// on it.
    ///
    /// ADR 0006 makes this the app's source switch, so a subscriber that had to combine a
    /// first read with a stream to know where it stood would have a window in which it knew
    /// neither.
    @Test("The health stream opens with the current value and follows the connection")
    func theHealthStreamFollowsTheConnection() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client()
        var updates = client.healthUpdates().makeAsyncIterator()

        let onSubscription = await updates.next()
        #expect(onSubscription == .idle)

        _ = try await client.snapshot()
        let afterHandshake = await updates.next()
        #expect(afterHandshake == .handshaken)

        harness.killHelperSideOfEveryConnection()
        let afterInterruption = await updates.next()
        #expect(afterInterruption == .interrupted)
    }
}
