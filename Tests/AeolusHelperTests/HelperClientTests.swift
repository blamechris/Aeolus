import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// The real `HelperClient` against the real helper session, over a real XPC connection.
///
/// Nothing here is a double of the thing under test: an anonymous `NSXPCListener` in this
/// process, `HelperConnectionSession` behind it, and the shipping client in front — with no
/// mach service, no privilege and no signing identity, so it runs unchanged on CI.
///
/// **What a green run of this file does not say.** Every connection here is pinned by a
/// policy declared in the test target that applies no requirement at all, exactly as
/// `AnonymousListenerTests` is admitted by one that enforces none. Whether the production
/// requirement admits the installed helper and refuses everything else needs a Developer ID
/// signature and is a manual `Mac16,5` checklist item — see
/// `docs/ADR/0005-xpc-authorisation.md`.
///
/// `.timeLimit` for the reason `AnonymousListenerTests` carries one: the failure mode of a
/// deleted client-side deadline is a test that waits forever, and a safety suite that hangs
/// is worse than one that fails.
@Suite("The XPC client against the real helper session", .timeLimit(.minutes(1)))
struct HelperClientTests {

    // MARK: - The handshake

    /// One `hello` per connection object, however many verbs go over it.
    ///
    /// Read at the session, not inferred from the client's own state: `messageCount` counts
    /// what actually reached the helper, so a client that re-handshook before every verb
    /// would show four messages here and a green client shows three.
    ///
    /// **Mutation:** in `HelperClient.handshakenConnection()`, delete the
    /// `if negotiatedReply != nil { return connection }` short circuit. Run: red — the second
    /// `hello` is refused with `invalidParameter`, and the snapshot never happens.
    @Test("hello runs once per connection object, whatever else is sent")
    func helloRunsOncePerConnection() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client()

        _ = try await client.snapshot()
        _ = try await client.snapshot()

        #expect(harness.sessions.count == 1)
        let session = try #require(harness.sessions.first)
        #expect(await session.messageCount == 3, "one hello and two snapshots")
        #expect(await session.handshakeState?.clientDescription == "test client")
        #expect(await client.negotiated?.helperProtocolRange == AeolusXPCVersion.supportedRange)
        #expect(await client.health == .handshaken)
    }

    /// The client waits for `hello`'s reply before it sends anything else, and this is where
    /// that is observable at all.
    ///
    /// `ArrivalRecordingService` sits upstream of the helper's message sequencer, so what it
    /// records is the order the client's messages *arrived*, before anything on the helper's
    /// side could reorder them. The reply marker is what makes it an assertion: `hello` and
    /// `snapshot` arrive in that order whether or not the client pipelined, and what differs
    /// is whether `hello`'s reply had already gone out when the `snapshot` turned up.
    ///
    /// **This is instrumentation, not an outcome.** Since D25 the helper answers a
    /// connection's messages in the order they were sent, so a pipelining client would get
    /// the same results and no caller could tell. What it protects is the reasoning in
    /// `HelperClient`'s documentation — the ordering guarantee is helper behaviour at an
    /// unchanged `AeolusXPCVersion`, so a client that relied on it would be relying on
    /// something it cannot check against a helper it has not yet spoken to.
    ///
    /// **Mutation:** in `HelperClient.handshakenConnection()`, delete
    /// `_ = try await task.value` — the handshake is still sent, and the verb no longer
    /// waits for its reply, which is exactly what pipelining is. Run: red, and *not* on the
    /// arrivals: the verb reaches the helper before the `hello` its task had not yet run,
    /// so it is refused with `handshakeRequired` and this test fails on the thrown error
    /// before it compares anything. That is the D25 fallback the contract names, arriving
    /// as a caller-visible failure — which is the outcome this client's rule exists to
    /// avoid having to handle.
    @Test("The client never pipelines a verb behind an unanswered hello")
    func theClientNeverPipelinesTheHandshake() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client()

        _ = try await client.snapshot()

        #expect(
            harness.arrivals == ["hello", "hello→replied", "snapshot", "snapshot→replied"],
            "the arrivals were \(harness.arrivals)")
    }

    /// Two verbs racing on a cold connection produce **one** `hello` between them.
    ///
    /// The second `hello` on a connection is refused by the helper — a connection has one
    /// negotiated identity — so "whoever gets there second loses" would be a race a correct
    /// caller could not avoid. The client coalesces by sharing one handshake `Task`.
    ///
    /// **The interleaving is constructed, not raced, and that is the whole design of this
    /// test.** The existing `helloRunsOncePerConnection` sends its two snapshots one after
    /// the other, so the second short-circuits on `negotiatedReply != nil` long before the
    /// coalescing line — which is why M3 survived against it. A bare `async let` pair is only
    /// better by luck: if the first handshake happens to complete before the second verb
    /// enters the actor, it short-circuits too, every expectation still holds, and the
    /// mutant survives that run. The same coin flip this suite refuses to accept for
    /// cancellation in `PendingReplyTests`.
    ///
    /// So the `hello` reply is **withheld** by the harness. While it is held,
    /// `negotiatedReply` is `nil` for certain, so the second verb cannot short-circuit —
    /// it must reach the coalescing line. The reply is released only after that verb's task
    /// has started, and releasing it costs a full IPC round trip while the verb's actor job
    /// is already enqueued and serial with it. There is no ordering left for luck to pick.
    ///
    /// **Mutation:** in `HelperClient.handshakenConnection()`, replace
    /// `handshake ?? Task { … }` with `Task { … }` — M3. Run: red, and the *thrown* error is
    /// worth writing down because it is not the obvious one. Two `hello`s go out on one
    /// connection and the helper refuses the second with `invalidParameter`; that refusal is
    /// a failed handshake, so this client's own rule takes the connection down with it, and
    /// the verb still in flight surfaces as `helperUnreachable(code: 4099)`. The message
    /// count is the backstop assertion at 4 rather than 3.
    @Test("Two verbs racing on a cold connection send one hello between them")
    func racingVerbsShareOneHandshake() async throws {
        let releaseHandshake = AsyncSignal()
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(), holdingHandshakeReplies: releaseHandshake)
        let client = harness.client(
            deadlines: HelperClientDeadlines(
                gatedVerb: .seconds(30), panicVerb: .seconds(30), handshakeVerb: .seconds(30)))

        let first = Task { try await client.snapshot() }
        try await waitUntil("the handshake reached the helper and is being held") {
            harness.arrivals == ["hello"]
        }

        // Started only now, so it meets a handshake that is certainly unanswered.
        let secondStarted = AsyncSignal()
        let second = Task { () -> SystemSnapshot in
            await secondStarted.signal()
            return try await client.snapshot()
        }
        try await secondStarted.wait()

        await releaseHandshake.signal()
        _ = try await (first.value, second.value)

        #expect(harness.sessions.count == 1)
        let session = try #require(harness.sessions.first)
        let delivered = await session.messageCount
        #expect(
            delivered == 3,
            """
            the session saw \(delivered) messages. Three is one hello and two snapshots; \
            four is two verbs that each sent their own hello, and the second of those is \
            refused for the life of the connection.
            """)
        #expect(
            harness.arrivals.filter { $0 == "hello" } == ["hello"],
            "the arrivals were \(harness.arrivals)")
        #expect(await client.health == .handshaken)
    }

    /// The handshake is sent within **its own** deadline, not a gated verb's.
    ///
    /// `hello` is the first message on a cold connection, so it queues behind launchd's
    /// spawn, the authorisation file I/O and the whole of startup reconciliation —
    /// `HelperComposition.bringUp()` resumes its listener as its last statement, precisely
    /// so no client is answered over unreconciled fans. Sharing `gatedVerb` with it meant
    /// the client allowed the entire cold start exactly what the helper budgets for
    /// reconciliation alone.
    ///
    /// Asserted by making `handshakeVerb` impossibly small and `gatedVerb` generous, which
    /// is the only arrangement in which the two are distinguishable without a peer that can
    /// be made slow: the handshake must be what fails.
    ///
    /// **Mutation:** in `HelperClient.performHandshake(generation:)`, send within
    /// `deadlines.gatedVerb` again. Run: red — `hello` and the snapshot both fit inside the
    /// generous deadline, so `snapshot()` returns `.empty` and nothing is thrown.
    @Test("The handshake is sent within its own deadline, not a gated verb's")
    func theHandshakeIsSentWithinItsOwnDeadline() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let handshakeDeadline = Duration.nanoseconds(1)
        let client = harness.client(
            deadlines: HelperClientDeadlines(
                gatedVerb: .seconds(5),
                panicVerb: .seconds(5),
                handshakeVerb: handshakeDeadline))

        await #expect(throws: HelperClientError.helperNeverAnswered(after: handshakeDeadline)) {
            try await client.snapshot()
        }
    }

    /// Refuse, never degrade — and name both sides' ranges, in both directions.
    ///
    /// A helper too new for this client and a helper too old for it are the same refusal
    /// with the numbers the other way round, and the client must carry both rather than
    /// reporting "the helper said no".
    ///
    /// **Mutation:** in `HelperClient.translate(_:)`, drop the
    /// `AeolusXPCFault(nsError:)` arm so every refusal becomes a transport error. Run: red in
    /// both directions.
    @Test(
        "A version mismatch is thrown as itself, carrying both ranges",
        arguments: [
            ProtocolVersionRange(minimumSupported: 0, current: 0),
            ProtocolVersionRange(minimumSupported: 2, current: 3),
        ])
    func versionMismatchCarriesBothRanges(helperRange: ProtocolVersionRange) async throws {
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(), helperRange: helperRange)
        let client = harness.client()

        await #expect(
            throws: AeolusXPCFault.versionMismatch(
                clientVersion: AeolusXPCVersion.current, helperRange: helperRange)
        ) {
            try await client.snapshot()
        }
        #expect(await client.negotiated == nil)
        let health = await client.health
        #expect(
            health == .versionMismatched,
            """
            a version-refused helper read as \(health). It used to read `.idle` \
            — indistinguishable from "nothing has been tried yet" — which is the state ADR \
            0006's switch has to tell apart from a helper it cannot talk to, because the \
            remedy is exact and belongs in front of the user.
            """)
    }

    // MARK: - The refusal vocabulary

    /// Every way the helper can say no survives the round trip **as itself**.
    ///
    /// Including a code this build has never heard of: forward tolerance is the property
    /// that lets a newer helper refuse for a reason an older client can still render, and a
    /// client that flattened it into a transport error would have thrown that away at the
    /// last step.
    ///
    /// **Mutation:** delete the `AeolusXPCFault(nsError:)` arm from
    /// `HelperClient.translate(_:)`, so every refusal becomes a transport error. Run: red on
    /// every case.
    @Test(
        "Every fault round-trips through the client as an equal value",
        arguments: [
            AeolusXPCFault.handshakeRequired,
            .malformedPayload(detail: "not JSON"),
            .invalidParameter(name: "fanIndices", detail: "is empty"),
            .manualControlUnavailable(reason: .writePathNotBuilt),
            .leaseExpired,
            .leaseUnknown,
            .leaseNotHeldByThisConnection,
            .thermalEmergencyActive,
            .reclaimedBySystem,
            .boundsImplausible(fanIndex: 1, detail: "minimum exceeds maximum"),
            .helperFailed(detail: "the SMC refused"),
            .unknown(code: "aReasonThisBuildHasNeverHeardOf", detail: "from a newer helper"),
        ])
    func everyFaultRoundTripsThroughTheClient(fault: AeolusXPCFault) async throws {
        let harness = ClientListenerHarness(authority: FaultThrowingAuthority(throwing: fault))
        let client = harness.client()

        await #expect(throws: fault) { try await client.snapshot() }
    }

    /// A payload verb answered with neither a payload nor a refusal is a protocol violation,
    /// never an empty success.
    ///
    /// The helper cannot produce this — `PayloadReply` makes `(nil, nil)` unrepresentable on
    /// that side — so the peer here is a rogue exported object rather than the real session.
    /// That is the honest shape of the assertion: the contract permits a peer this project
    /// does not control, and "our helper cannot do this" is not "no peer can". A client that
    /// read the empty reply as a success would render an answer the helper never gave as the
    /// state of the machine.
    ///
    /// **Mutation:** in `HelperClientPayload.outcome(_:_:)`, return `.success(data ?? Data())`.
    /// Run: red — and on the *detail*, which is the point: the empty answer then fails at
    /// the decode instead, which is the same case with a different cause and would let the
    /// defect through a test that only checked the error's shape.
    @Test("A reply carrying neither payload nor error is a protocol violation")
    func emptyReplyIsAProtocolViolation() async throws {
        let harness = EmptyReplyListenerHarness()
        let client = harness.client()

        let error = await #expect(throws: HelperClientError.self) { try await client.snapshot() }

        guard case .protocolViolation(let detail) = try #require(error) else {
            Issue.record("an empty reply became \(String(describing: error))")
            return
        }
        #expect(
            detail.contains("neither a payload nor a refusal"),
            """
            the violation was reported as "\(detail)". The detail is the assertion: a client \
            that took the empty reply as a payload fails at the decode instead, which is the \
            same case with a different cause and would let the defect through.
            """)
    }

    // MARK: - The panic path

    /// `restoreAllToAutomatic` reaches the helper with no handshake behind it, and sends no
    /// `hello` of its own.
    ///
    /// The helper exempts it from the gate; this asserts the client actually uses that
    /// exemption rather than paying for a handshake first. The distinction matters in the
    /// state a user reaches for it in: a `hello` in front of the panic path is one more round
    /// trip that can fail.
    ///
    /// **Mutation:** route `restoreAllToAutomatic` through `withHandshakenProxy`. Run: red —
    /// the session sees two messages and a completed handshake.
    @Test("The panic path is sent with no handshake and no hello")
    func thePanicPathNeedsNoHandshake() async throws {
        let authority = RecordingFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client()

        try await client.restoreAllToAutomatic()

        let session = try #require(harness.sessions.first)
        #expect(await session.messageCount == 1, "only the panic path was sent")
        #expect(await session.handshakeState == nil, "no hello was sent")
        #expect(
            harness.arrivals == ["restoreAllToAutomatic", "restoreAllToAutomatic→replied"],
            "the arrivals were \(harness.arrivals)")
        #expect(await authority.calls.count == 1)
    }

    // MARK: - When nothing comes back

    /// A helper that accepts a message and never answers is a failure with a name.
    ///
    /// The assertion is the specific error, not the suite's time limit: a test that only
    /// checked "this returned eventually" would pass on a client whose deadline had been
    /// deleted, because the enclosing `.timeLimit` would eventually record something either
    /// way and the two are not the same failure.
    ///
    /// **Mutation:** in `HelperClient.exchange(on:within:_:)`, replace
    /// `pending.answer(within: deadline)` with `pending.answer(within: .seconds(600))`. Run:
    /// red on the suite's time limit rather than on this expectation, which is the weaker
    /// kill and is why the expectation is on the error value.
    @Test("A message nobody answers becomes helperNeverAnswered")
    func aMessageNobodyAnswersHasItsOwnError() async throws {
        let gate = AsyncSignal()
        let harness = ClientListenerHarness(authority: GatedSnapshotAuthority(gate: gate))
        let deadline = Duration.milliseconds(250)
        // The gated verb's bound is the assertion, so it is short and explicit. The
        // handshake's is not asserted by anything here and must simply succeed, so it is the
        // shipping one — a `hello` that lost a race with a contended runner would fail this
        // on `helperNeverAnswered(after: 5 seconds)`, which is #250 in miniature.
        let client = harness.client(
            deadlines: HelperClientDeadlines(
                gatedVerb: deadline,
                panicVerb: deadline,
                handshakeVerb: HelperClientDeadlines.handshakeVerb))

        await #expect(throws: HelperClientError.helperNeverAnswered(after: deadline)) {
            try await client.snapshot()
        }

        // The wedge, as ADR 0006 has to be able to read it. The connection handshook and
        // then stopped answering, so `.handshaken` — the one state that licenses rendering a
        // helper snapshot as current — would be a licence granted in exactly the situation
        // `docs/SAFETY.md` § 4 calls expected.
        //
        // **Mutation:** in `HelperClient.translate(_:on:)`, delete the
        // `case .helperNeverAnswered` arm. Run: red here — the health stays `.handshaken`
        // and the wedged connection is kept.
        let health = await client.health
        #expect(health == .unresponsive, "a wedged connection read as \(health)")

        // Released so the parked helper task can finish rather than outliving the test.
        await gate.signal()
    }
}
