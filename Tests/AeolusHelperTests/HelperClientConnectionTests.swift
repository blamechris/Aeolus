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
        // The gated verb is deliberately long: it has to stay parked while the helper is
        // killed under it. The handshake is not asserted here and only has to succeed, so it
        // takes the shipping bound rather than a tighter invention — see #250.
        let client = harness.client(
            deadlines: HelperClientDeadlines(
                gatedVerb: .seconds(10),
                panicVerb: .seconds(10),
                handshakeVerb: HelperClientDeadlines.handshakeVerb))

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

        // And tearing the client down does not erase that diagnosis. There is no connection
        // to discard, so `disconnect()` does nothing — which is what its documentation says
        // and, until the guard was added, not what it did: it moved health to `.idle` and
        // threw away the one answer this client is sure of.
        //
        // **Mutation:** delete `guard connection != nil else { return }` from
        // `HelperClient.disconnect()`. Run: red here, `.idle` where `.refused` belongs.
        await client.disconnect()
        #expect(await client.health == .refused, "a teardown erased the refusal")
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
