import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The starvation `docs/SAFETY.md` § 1 cannot tolerate: a live, healthy client losing manual
/// control because the helper queued its heartbeat behind its own reads.
///
/// [#229](https://github.com/blamechris/Aeolus/issues/229). § 1 grants a 30 s TTL with a 10 s
/// heartbeat *so that two consecutive missed beats are tolerated* — and that is a property of
/// the **client's sending**. A helper-side backlog defeats it without the client doing
/// anything wrong: § 3 has the app rendering the snapshot at 1 Hz on the same connection it
/// holds its lease on, a warm read costs ~0.56 s on this Mac16,5 and ~2.9 s cold, and
/// `MessageSequencer` runs one message at a time with no depth limit and no deadline. Once the
/// backlog is longer than the TTL, a `renewLease` sent exactly on schedule reaches
/// `LeaseAuthority` after the lease it was renewing has gone.
///
/// ## What these tests assert, and what they deliberately do not
///
/// Not a queue depth and not a timeout value. The issue is explicit that a test reading the
/// fix's own constant back is the can't-fail shape this repository keeps shipping, and it
/// would be: a depth ceiling asserted against itself is true of any number, including one
/// that is far past the TTL. So the scenario is built instead — a backlog of reads occupying
/// the queue, and a heartbeat that has to land while they are still in front of it — and the
/// deadline is the one the **lease contract** gives, not one invented here.
///
/// The head read parks and does not return, which is § 4's wedged `io_connect_t` rather than
/// a caricature: it makes the failure a deadline rather than a timing margin, so the red is
/// the same on a loaded machine as on a quiet one.
@Suite("The lease heartbeat is not queued behind a client's own reads", .timeLimit(.minutes(2)))
struct LeaseHeartbeatStarvationTests {

    /// The budget the lease contract gives one heartbeat.
    ///
    /// A beat sent on schedule has until the TTL runs out, and the TTL is counted from the
    /// last beat that *landed* — one interval ago. So `TTL - interval` is what one beat has,
    /// and it is the last honest moment: a beat later than this has already cost the client
    /// its lease. Read off `FanKit` rather than written down, because a test that restated
    /// either number would keep passing after the contract moved.
    ///
    /// The green path never waits for it — `waitUntil` returns the moment its condition
    /// holds — so the generous deadline costs the suite nothing and only the red run pays it.
    private static let heartbeatBudget = Duration.seconds(
        Lease.defaultTimeToLive - Lease.defaultHeartbeatInterval)

    /// How many reads a lease-holding client has already sent by the time its next beat is
    /// due: § 3's snapshot rendering is 1 Hz, and § 1's beat is every
    /// `Lease.defaultHeartbeatInterval` seconds.
    ///
    /// Derived rather than picked, so that "the backlog is a realistic one" is checkable
    /// against the two documents it comes from instead of being a number's say-so.
    private static let readsBetweenHeartbeats = Int(Lease.defaultHeartbeatInterval)

    // MARK: - The heartbeat

    /// A `renewLease` sent behind a connection's own reads is answered inside the budget the
    /// lease contract gives it.
    ///
    /// The reads are sent first and the head one parks in the authority, so every later read
    /// is in the sequencer with nothing draining it — `readsStarted == 1` against
    /// `readsBetweenHeartbeats` sent is that queue, measured rather than assumed. The
    /// heartbeat goes out after them, which is exactly what a client on § 3's 1 Hz render
    /// does, and it is the *only* reply the test permits to have arrived: a snapshot answering
    /// first would mean the backlog had drained and the scenario had not been built.
    ///
    /// **Red against the code this test was written for**, where all six gated verbs shared one
    /// queue: the heartbeat is never answered at all, so it fails on the deadline rather than on
    /// a margin. Observed first against `origin/main` at f7eed06, then reproduced as a mutation
    /// of the fix — `sequencer.enqueue` in place of `Task` in `HelperXPCService.renewLease`:
    ///
    /// ```
    /// LeaseHeartbeatStarvationTests.swift:99:28: timed out after 20.0 seconds waiting for:
    ///   the heartbeat reached the lease core inside the budget § 1 gives it
    /// LeaseHeartbeatStarvationTests.swift:106:9: Expectation failed:
    ///   (replies.entries → []) == ["renewLease"]
    /// ```
    ///
    /// The empty `replies` is the second half of the evidence: nothing at all had been answered
    /// in twenty seconds, which is the client's whole connection stalled behind one read.
    @Test("A heartbeat is answered while the connection's own reads are still queued")
    func theHeartbeatIsNotQueuedBehindTheConnectionsReads() async throws {
        let gate = AsyncSignal()
        let authority = BackloggedReadAuthority(gate: gate)
        let service = HelperXPCService(session: MessageOrderingFixtures.session(over: authority))
        let replies = OrderRecord<String>()

        try await MessageOrderingFixtures.handshake(on: service)

        for index in 0..<Self.readsBetweenHeartbeats {
            service.snapshot { _, _ in replies.append("snapshot\(index)") }
        }
        try await waitUntil("the first read reached the authority") {
            await authority.readsStarted == 1
        }

        service.renewLease(id: UUID().uuidString) { _, _ in replies.append("renewLease") }

        try await waitUntil(
            "the heartbeat reached the lease core inside the budget § 1 gives it",
            timeout: Self.heartbeatBudget
        ) {
            await authority.heartbeats == 1
        }

        #expect(
            replies.entries == ["renewLease"],
            """
            replies so far: \(replies.entries). The heartbeat had to be answered with the \
            connection's own reads still in front of it — a snapshot answering first would \
            mean the backlog drained and this test built no backlog at all.
            """)
        let pastTheSequencer = await authority.readsStarted
        #expect(
            pastTheSequencer == 1,
            """
            \(pastTheSequencer) of \(Self.readsBetweenHeartbeats) reads reached the \
            authority. One is the parked head; the rest are the queue this test exists to put \
            the heartbeat behind, so any other number means there was no queue.
            """)

        await gate.signal()
        try await waitUntil("the backlog drained too") {
            replies.entries.count == Self.readsBetweenHeartbeats + 1
        }
    }

    // MARK: - The release

    /// `releaseLease` is answered while the connection's own reads are still queued, for the
    /// same reason and in the opposite direction.
    ///
    /// A late heartbeat surrenders control the client wanted; a late release *keeps* control
    /// the client has already given up, so the fans stay in manual for the length of the
    /// backlog with nothing renewing the lease and nothing wanting it. That is the direction
    /// `CLAUDE.md` rule 2 and ADR 0005 care about most: the queue is a precondition on the
    /// verb that hands the fans back.
    ///
    /// **Red against `origin/main` at f7eed06, and against the fix mutated back:**
    ///
    /// ```
    /// LeaseHeartbeatStarvationTests.swift:165:28: timed out after 20.0 seconds waiting for:
    ///   the release reached the lease core rather than waiting for the reads
    /// LeaseHeartbeatStarvationTests.swift:172:9: Expectation failed:
    ///   (replies.entries → []) == ["releaseLease"]
    /// ```
    @Test("A release is answered while the connection's own reads are still queued")
    func theReleaseIsNotQueuedBehindTheConnectionsReads() async throws {
        let gate = AsyncSignal()
        let authority = BackloggedReadAuthority(gate: gate)
        let service = HelperXPCService(session: MessageOrderingFixtures.session(over: authority))
        let replies = OrderRecord<String>()

        try await MessageOrderingFixtures.handshake(on: service)

        for index in 0..<Self.readsBetweenHeartbeats {
            service.snapshot { _, _ in replies.append("snapshot\(index)") }
        }
        try await waitUntil("the first read reached the authority") {
            await authority.readsStarted == 1
        }

        service.releaseLease(id: UUID().uuidString) { _ in replies.append("releaseLease") }

        try await waitUntil(
            "the release reached the lease core rather than waiting for the reads",
            timeout: Self.heartbeatBudget
        ) {
            await authority.releases == 1
        }

        #expect(
            replies.entries == ["releaseLease"],
            """
            replies so far: \(replies.entries). A client that has asked for its fans back is \
            waiting on this verb, and every read in front of it is time the fans stay in \
            manual with nothing holding the lease honest.
            """)

        await gate.signal()
        try await waitUntil("the backlog drained too") {
            replies.entries.count == Self.readsBetweenHeartbeats + 1
        }
    }

    // MARK: - What leaving the queue must not take with it

    /// The two exempted verbs are exempt from **ordering** and from nothing else: an
    /// un-handshaken connection is still refused `handshakeRequired`.
    ///
    /// This is the half that would make the fix a privilege-boundary defect rather than a
    /// scheduling one. Dispatching a verb on its own task moves it out of the sequencer, which
    /// is a property of `HelperXPCService`; the gates live on `HelperConnectionSession` and are
    /// checked inside the message, so nothing about the dispatch can reach them. Asserted
    /// rather than argued, because "the gate is somewhere else" is exactly the kind of claim
    /// that survives the edit that falsifies it.
    ///
    /// `HandshakeGateTests` asserts the same refusal of `HelperConnectionSession` **directly**,
    /// and that is the difference worth having twice: it drives the actor, so it would stay
    /// green if the exemption had been implemented by routing these two verbs around the
    /// session. This one goes through `HelperXPCService`, which is the route the fix changed.
    ///
    /// **Mutation:** delete the `handshakeRefusal(message: "renewLease")` line from
    /// `HelperConnectionSessionMessages.swift`. Run: red at
    /// `LeaseHeartbeatStarvationTests.swift:215:9`, answering
    /// `manualControlUnavailable(reason: .writePathNotBuilt)` where the gate should have
    /// refused, and at `:223:9` because the un-handshaken verb reached the authority.
    @Test("The exemption is from ordering, never from the handshake gate")
    func theExemptedVerbsAreStillHandshakeGated() async throws {
        let authority = BackloggedReadAuthority(gate: AsyncSignal())
        let service = HelperXPCService(session: MessageOrderingFixtures.session(over: authority))
        let faults = OrderRecord<String>()

        service.renewLease(id: UUID().uuidString) { _, error in
            faults.append(Self.name(of: error) ?? "renewLease was not refused")
        }
        service.releaseLease(id: UUID().uuidString) { error in
            faults.append(Self.name(of: error) ?? "releaseLease was not refused")
        }

        try await waitUntil("both verbs were answered") { faults.entries.count == 2 }

        #expect(
            faults.entries == ["handshakeRequired", "handshakeRequired"],
            """
            the un-handshaken connection was answered \(faults.entries). Leaving the \
            sequencer is an exemption from ordering; the handshake gate is checked inside the \
            message and must be untouched by where the message was dispatched from.
            """)
        let reached = await (authority.heartbeats, authority.releases)
        #expect(
            reached == (0, 0),
            "a refused verb reached the authority anyway: \(reached)")
    }

    // MARK: - Which route each verb takes

    /// **Which** verbs are sequenced, not merely how many.
    ///
    /// `MessageOrderingTests.theSequencerIsCalledOnlyFromTheXPCEntryPoints` pins the *count* at
    /// four, and any four satisfy it. #229 is what makes that gap matter: moving a verb between
    /// `HelperXPCService`'s two dispatch routes is now something this repository does on
    /// purpose, and the hazard is doing it to the wrong verb. Taking `acquireLease` or
    /// `snapshot` off the queue reopens #90 — those are the ones a client pipelines ahead of
    /// the handshake's reply, and `handshakeRequired` for overtaking `hello` is the refusal #90
    /// exists to prevent. Putting `renewLease` back on it reopens this file. **Both mutations
    /// leave the count at four**, which is why the membership is asserted separately rather
    /// than trusted to it.
    ///
    /// Read off the source rather than driven through the wire, because it is a claim about the
    /// *route*, and both routes reach the same method behind the same gates: nothing a client
    /// can observe distinguishes them except timing, which the tests above assert one verb at a
    /// time. This is the exhaustive statement over all seven.
    ///
    /// **Mutation, chosen to leave both counts green:** in `HelperXPCService`, move `snapshot`
    /// to `Task { … }` and `renewLease` to `sequencer.enqueue { … }`. Four enqueues and three
    /// spawns either way, so `theSequencerIsCalledOnlyFromTheXPCEntryPoints` and
    /// `everyUnstructuredTaskHandsOffToThePopulation` both still pass — and this fails:
    ///
    /// ```
    /// LeaseHeartbeatStarvationTests.swift:261:9: Expectation failed:
    ///   (sequenced → ["acquireLease", "apply", "hello", "renewLease"])
    ///     == ["acquireLease", "apply", "hello", "snapshot"]
    /// LeaseHeartbeatStarvationTests.swift:269:9: Expectation failed:
    ///   (dispatched → ["releaseLease", "restoreAllToAutomatic", "snapshot"])
    ///     == ["releaseLease", "renewLease", "restoreAllToAutomatic"]
    /// ```
    @Test("Exactly the four pipelineable verbs are sequenced, and the three unlocks are not")
    func theSequencedVerbsAreTheOnesAClientPipelines() throws {
        let file = try #require(
            try SeamScanner.swiftFiles(under: "AeolusHelper")
                .first { $0.lastPathComponent == "HelperXPCService.swift" },
            "HelperXPCService.swift is not in the tree — the routes it declares are this test")
        let collapsed = SeamScanner.collapsingWhitespace(
            SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8)))

        let sequenced = Self.dispatchedVerbs(in: collapsed, through: #"sequencer\.enqueue"#)
        let dispatched = Self.dispatchedVerbs(in: collapsed, through: #"Task"#)

        #expect(
            sequenced == ["acquireLease", "apply", "hello", "snapshot"],
            """
            the sequenced verbs are \(sequenced). These are the four a client can pipeline \
            ahead of a reply it has not received, which is the only place ordering buys \
            anything and the whole of #90; taking one off the queue is a `handshakeRequired` \
            a compliant client cannot avoid.
            """)
        #expect(
            dispatched == ["releaseLease", "renewLease", "restoreAllToAutomatic"],
            """
            the unsequenced verbs are \(dispatched). These are the three unlocks — restore the \
            safe state, prove the client is alive, hand the fans back — and a queue in front \
            of any of them is time the fans stay held by something nobody is checking (D27, \
            #229). Adding a fourth is a safety review; removing one reopens its issue.
            """)
    }

    /// The `HelperConnectionSession` methods awaited inside a `route { [session] in … }` body,
    /// sorted, over collapsed and comment-stripped source.
    ///
    /// Sorted rather than in declaration order: the assertion is about membership of the two
    /// routes, and making it fail when `swift format` or a reviewer moves a method would be a
    /// tripwire on the wrong thing.
    private static func dispatchedVerbs(in collapsed: String, through route: String) -> [String] {
        let pattern = route + #" \{ \[session\] in await session\.([A-Za-z]+)\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["<no regex>"] }
        let range = NSRange(collapsed.startIndex..., in: collapsed)
        return regex.matches(in: collapsed, range: range).compactMap { match in
            Range(match.range(at: 1), in: collapsed).map { String(collapsed[$0]) }
        }.sorted()
    }

    /// The fault case's name, or `nil` when the error is not one of this boundary's faults.
    private static func name(of error: Error?) -> String? {
        guard let error, let fault = AeolusXPCFault(nsError: error as NSError) else { return nil }
        if case .handshakeRequired = fault { return "handshakeRequired" }
        return "\(fault)"
    }
}

/// A `FanAuthority` whose reads park until a signal fires, and which counts what reached it.
///
/// `GatedSnapshotAuthority` parks the same way but records only that a read arrived, which
/// cannot distinguish "the heartbeat was queued" from "the heartbeat was answered without
/// reaching the lease core". These tests need both halves: how much of the backlog got past
/// the sequencer, and whether the exempted verb actually arrived.
///
/// An actor, and reentrant at every `await`, which is what makes the backlog measurable: the
/// parked read suspends inside `gate.wait()` and releases this actor, so a read that is still
/// counted at one while ten were sent is a statement about `MessageSequencer` and not about
/// this double serialising them itself.
actor BackloggedReadAuthority: FanAuthority {

    private let gate: AsyncSignal

    /// Incremented before the read parks, so it counts reads that *started* rather than reads
    /// that finished — none of them do until the gate fires.
    private(set) var readsStarted = 0

    private(set) var heartbeats = 0
    private(set) var releases = 0

    init(gate: AsyncSignal) {
        self.gate = gate
    }

    func snapshot() async throws -> SystemSnapshot {
        readsStarted += 1
        try? await gate.wait()
        return .empty
    }

    func acquireLease(
        _ request: LeaseRequest, from connection: ConnectionID
    ) async throws -> Lease {
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease {
        heartbeats += 1
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func releaseLease(id: UUID, from connection: ConnectionID) async throws {
        releases += 1
    }

    func apply(
        _ settings: [FanSetting], leaseID: UUID, from connection: ConnectionID
    ) async throws {
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func restoreAllToAutomatic(from connection: ConnectionID) async throws {}

    func connectionDidInvalidate(_ connection: ConnectionID) async {}
}
