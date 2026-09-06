import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Per-connection message ordering: the guarantee `AeolusXPCProtocol` now makes, the
/// mechanism that keeps it, and the source tripwire on that mechanism's call sites.
///
/// Three levels, because the defect in
/// [#90](https://github.com/blamechris/Aeolus/issues/90) lived between two of them. The
/// sequencer is tested on its own, where "the second operation has not started" is a
/// statement about two closures and can be made to fail on demand.
/// `HelperXPCService` is tested as libxpc drives it — synchronous calls, back to back, on
/// one thread — because the type's whole job is the crossing from that into `async` code.
/// And the wire test is the witness that the two are actually wired together.
@Suite("Per-connection message ordering", .timeLimit(.minutes(2)))
struct MessageOrderingTests {

    // MARK: - The sequencer on its own

    /// **The deterministic kill.** Everything else here observes ordering through something
    /// that would also be ordered by luck most of the time; this observes the one property
    /// that cannot be: an operation that has been handed over and *has not started* while
    /// the one before it is parked.
    ///
    /// The parked operation signals before it parks, so the assertion is never the vacuous
    /// one — "nothing has run yet" would pass on a sequencer that never ran anything at
    /// all. `settle()` is what gives the second operation a real chance to run before the
    /// expectation says it did not.
    ///
    /// **Mutation:** delete `await predecessor?.value` from `MessageSequencer.enqueue(_:)`.
    /// Run: red.
    @Test("A queued operation does not start until the one before it has returned")
    func theSecondOperationWaitsForTheFirstToReturn() async throws {
        let sequencer = MessageSequencer()
        let record = OrderRecord<Int>()
        let firstHasStarted = AsyncSignal()
        let gate = AsyncSignal()

        sequencer.enqueue {
            await firstHasStarted.signal()
            try? await gate.wait()
            record.append(1)
        }
        sequencer.enqueue {
            record.append(2)
        }

        try await firstHasStarted.wait()
        await MessageOrderingFixtures.settle()

        let ranWhileTheFirstWasParked = record.entries
        #expect(
            ranWhileTheFirstWasParked.isEmpty,
            """
            the second operation ran while the first was still parked: \
            \(ranWhileTheFirstWasParked). One connection's messages are handled one at a \
            time, in the order they arrived — that is the whole of #90.
            """)

        await gate.signal()
        try await waitUntil("both operations finished") { record.entries.count == 2 }
        #expect(record.entries == [1, 2])
    }

    /// The tail is per sequencer, not global: two connections have no order between them
    /// and must not be able to block each other.
    ///
    /// The assertion is that the second sequencer's operation completes at all while the
    /// first's is parked. A shared tail would leave it waiting for a gate the test only
    /// releases afterwards, and the `waitUntil` would time out red.
    @Test("Two sequencers do not serialise against each other")
    func separateSequencersRunIndependently() async throws {
        let parked = MessageSequencer()
        let free = MessageSequencer()
        let record = OrderRecord<Int>()
        let gate = AsyncSignal()

        parked.enqueue {
            try? await gate.wait()
            record.append(1)
        }
        free.enqueue { record.append(2) }

        try await waitUntil("the unblocked sequencer ran") { record.entries == [2] }

        await gate.signal()
        try await waitUntil("the parked sequencer ran") { record.entries.count == 2 }
        #expect(record.entries == [2, 1])
    }

    // MARK: - The service, driven the way libxpc drives it

    /// A fast message sent after a slow one is answered after it — which is the ordering
    /// property stated in terms a client can observe.
    ///
    /// `snapshot` is the slow one, parked in the authority; `renewLease` is the fast one,
    /// refused by the lease core without touching hardware and so ready to finish the
    /// instant it is allowed to start. Both are gated, so the handshake is completed first
    /// — the gate this test is *not* about has to be open for either message to reach the
    /// authority at all.
    ///
    /// **The pair used to be `restoreAllToAutomatic` and `hello`**, which needed no
    /// handshake and kept the two messages adjacent. That stopped being a test of ordering
    /// when the panic path was exempted from the sequencer (D27): it is now the one message
    /// that is *allowed* to overtake, and `OrderingExemptionTests` asserts exactly that.
    ///
    /// Both calls are made synchronously from this test's thread, one after the other,
    /// which is exactly how libxpc invokes the exported object.
    ///
    /// **Mutation:** delete `await predecessor?.value` from `MessageSequencer.enqueue(_:)`.
    /// Run: red — the replies come back `["renewLease", "snapshot"]`.
    @Test("A fast message does not overtake the slow one sent before it")
    func aFastMessageIsAnsweredAfterTheSlowOneBeforeIt() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let service = HelperXPCService(session: MessageOrderingFixtures.session(over: authority))
        let replies = OrderRecord<String>()

        try await MessageOrderingFixtures.handshake(on: service)

        service.snapshot { _, _ in replies.append("snapshot") }
        service.renewLease(id: UUID().uuidString) { _, _ in replies.append("renewLease") }

        try await waitUntil("the slow message reached the authority") {
            await authority.hasBeenAsked
        }
        await MessageOrderingFixtures.settle()
        #expect(
            replies.entries.isEmpty,
            "a reply arrived while the message sent before it was still being handled")

        await gate.signal()
        try await waitUntil("both messages were answered") { replies.entries.count == 2 }
        #expect(replies.entries == ["snapshot", "renewLease"])
    }

    // MARK: - The wire

    /// The end-to-end witness: a client that pipelines `hello` and `snapshot` without
    /// awaiting the handshake's reply is never answered `handshakeRequired`.
    ///
    /// **Probabilistic, and named as such.** With the sequencer removed this fails because
    /// two tasks race, and a race can be won; one iteration would be a coin toss.
    /// `theSecondOperationWaitsForTheFirstToReturn` is the deterministic kill and this is
    /// the proof that the deterministic thing is wired to the wire. The iteration count is
    /// what turns "usually" into "never observed", and it is set from measurement rather
    /// than taste. With the sequencer removed, fifteen runs reddened every time, the first
    /// refusal landing anywhere between iteration 8 and iteration 498 — so a hundred would
    /// have been a coin toss, and this is three times the worst observed. The whole loop is
    /// a few tenths of a second against an in-process anonymous listener; the margin is free.
    ///
    /// A fresh harness per iteration, because a second `hello` on one connection is
    /// refused by design and the connection under test must be a new one each time.
    @Test("A pipelined hello and snapshot is never answered handshakeRequired")
    func pipeliningTheHandshakeIsNotRefused() async throws {
        for iteration in 0..<1_500 {
            let authority = RecordingFanAuthority()
            let harness = AnonymousListenerHarness(authority: authority)

            let request = try helloPayload()
            let (hello, snapshot) = await harness.pipelinedPayloadMessages(
                { proxy, reply in proxy.hello(request: request, reply: reply) },
                { proxy, reply in proxy.snapshot(reply: reply) }
            )

            #expect(hello.payload != nil, "the handshake itself failed on iteration \(iteration)")
            #expect(
                snapshot.fault != .handshakeRequired,
                """
                iteration \(iteration): a snapshot pipelined behind hello was refused as \
                un-handshaken. The client did what the contract allows; the helper lost \
                the order.
                """)
            #expect(snapshot.payload != nil, "iteration \(iteration): the snapshot carried nothing")
        }
    }

    // MARK: - The source tripwire

    /// `MessageSequencer.enqueue(_:)` is a second route around *"a synchronous function
    /// cannot `await`"*, and `WriteVerbAllowlistTests` cannot see it.
    ///
    /// That suite counts unstructured `Task` spawn sites, and after #90 six of the helper's
    /// seven XPC entry points reach `async` code through `enqueue` instead — a call the
    /// spawn scanner does not match. Left there, the sequencer would be a hole in the
    /// population exactly the size of the one the spawn count was watching. So the call
    /// sites are pinned here for the same reason and with the same discipline.
    ///
    /// **The count is not enough on its own, and this is the second thing it asserts.** The
    /// re-pin in `WriteVerbAllowlistTests` is justified by a containment argument — no spawn
    /// site writes in its own body; each hands off to a method that suite acknowledges — and
    /// `MessageSequencer.enqueue(_:)` awaits an opaque `@Sendable` closure that is in no
    /// allowlist and cannot be. A count alone leaves the argument unverifiable: rewriting one
    /// of the six closures to `sequencer.enqueue { await somethingThatWrites() }` keeps the
    /// count at six and keeps the spawn dictionary unchanged, and the containment the re-pin
    /// rested on is gone with nothing red. So each closure's **shape** is pinned too: a
    /// `[session] in` capture and a single `await` of a `HelperConnectionSession` method
    /// delivered to `reply`, and nothing else in the body.
    ///
    /// Six, not seven: `restoreAllToAutomatic` keeps its own `Task` (D27), and that spawn
    /// site is visible to `WriteVerbAllowlistTests` in the ordinary way.
    ///
    /// **Mutation:** add `sequencer.enqueue { }` to any file under `Sources/AeolusHelper`.
    /// Run: red, naming the file. **Second mutation:** change one existing closure's body to
    /// anything but the pinned shape. Run: red on the shape count with the count unchanged.
    @Test("The message sequencer is called only from the XPC entry points")
    func theSequencerIsCalledOnlyFromTheXPCEntryPoints() throws {
        var sites: [String] = []
        var shaped = 0
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            let count = code.components(separatedBy: ".enqueue").count - 1
            if count > 0 { sites.append("\(file.lastPathComponent) x\(count)") }
            shaped += Self.handoffShapedEnqueueSites(inSource: code)
        }

        #expect(
            sites == ["HelperXPCService.swift x6"],
            """
            the message sequencer's call sites changed: \(sites). Each existing one is a \
            single `await` of a `HelperConnectionSession` method — the same acknowledgement \
            `WriteVerbAllowlistTests` requires of an unstructured `Task`, which is what \
            `enqueue` replaced and what its spawn scanner can no longer see here.
            """)
        #expect(
            shaped == 6,
            """
            \(shaped) of the enqueued closures are a single `await session.<method>(…)\
            .deliver(to: reply)`; six are expected. A body that does anything else is work \
            running inside the one spawn site `WriteVerbAllowlistTests` cannot look into, \
            which is the containment its re-pin from nineteen to fourteen rests on.
            """)
    }

    /// Counts `sequencer.enqueue` call sites whose whole body is one hand-off to the
    /// session, over comment-stripped source with its whitespace collapsed.
    ///
    /// Collapsing first is what lets one pattern match both the one-line and the wrapped
    /// spellings in `HelperXPCService`, which `swift format` chooses between by line width
    /// rather than by anything meaningful. `[^{}]*` in the argument list is what keeps the
    /// match to a body containing no second closure.
    private static func handoffShapedEnqueueSites(inSource source: String) -> Int {
        let collapsed = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let pattern =
            #"sequencer\.enqueue \{ \[session\] in await session\.[A-Za-z]+\([^{}]*\)"#
            + #"\.deliver\(to: reply\) \}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return -1 }
        return regex.numberOfMatches(
            in: collapsed, range: NSRange(collapsed.startIndex..., in: collapsed))
    }

}

/// Fixtures shared with `OrderingExemptionTests`, which asserts the other half of the
/// contract — what is *not* sequenced, and what one connection cannot do to another.
///
/// A namespace rather than free functions: `settle` and `handshake` are words this test
/// target would otherwise have two of, and Swift resolves a global by overload rather than
/// by file, so the only symptom of a collision is a warning somewhere else.
enum MessageOrderingFixtures {

    static func session(over authority: any FanAuthority) -> HelperConnectionSession {
        HelperConnectionSession(
            id: ConnectionID(),
            authority: authority,
            helperBuild: "test",
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Ordering")
        )
    }

    /// Opens the handshake gate, and does not return until the reply block has run.
    ///
    /// Every gated message needs this first, and the ordering assertions that follow it
    /// need the handshake to be *finished* rather than merely sent — a `hello` still in the
    /// queue is a message the later ones are ordered behind, which would make the property
    /// under test hold for the wrong reason.
    static func handshake(on service: HelperXPCService) async throws {
        let answered = OrderRecord<String>()
        service.hello(request: try helloPayload()) { _, _ in answered.append("hello") }
        try await waitUntil("the handshake was answered") { answered.entries == ["hello"] }
    }

    /// Gives anything that is ready to run a real chance to run.
    ///
    /// Every "it has *not* happened" assertion here needs one: without it the expectation
    /// is satisfied by the scheduler simply not having got round to the work yet, which is
    /// a test that passes for a reason nobody chose. The yields drain the cooperative
    /// pool's ready queues and the sleep covers a thread that had not been woken at all.
    static func settle() async {
        for _ in 0..<100 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))
    }
}

/// Records what ran, in the order it ran.
///
/// `@unchecked Sendable` over an `NSLock` rather than an actor, for the reason
/// `AnonymousListenerHarness.PendingReply` is one: an XPC reply block is a synchronous,
/// non-isolated context, and recording from it through an actor would need a `Task` — which
/// would put the two records back in whatever order the pool started them and make an
/// ordering assertion assert nothing. The state is one array behind one lock with no path
/// that touches it outside.
final class OrderRecord<Entry: Sendable & Equatable>: @unchecked Sendable {

    private let lock = NSLock()
    private var recorded: [Entry] = []

    func append(_ entry: Entry) {
        lock.lock()
        recorded.append(entry)
        lock.unlock()
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// A `FanAuthority` whose `snapshot` parks until a signal fires, and answers everything
/// else immediately.
///
/// `snapshot` rather than the panic path, which is where the gate used to be: since D27 the
/// panic path is dispatched outside the sequencer, so parking it would park nothing that
/// any later message waits for. It is the message these tests need to come back *while*
/// something else is stuck, so it must be the one that does not stick.
actor GatedSnapshotAuthority: FanAuthority {

    private let gate: AsyncSignal

    /// Set when `snapshot` has reached this authority — before it parks, so "the slow
    /// message has started" is observable rather than inferred from a sleep.
    private(set) var hasBeenAsked = false

    /// Set when the panic path has run to completion.
    private(set) var hasRestored = false

    init(gate: AsyncSignal) {
        self.gate = gate
    }

    func snapshot() async throws -> SystemSnapshot {
        hasBeenAsked = true
        try? await gate.wait()
        return .empty
    }

    func acquireLease(
        _ request: LeaseRequest, from connection: ConnectionID
    ) async throws -> Lease {
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease {
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func releaseLease(id: UUID, from connection: ConnectionID) async throws {
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func apply(
        _ settings: [FanSetting], leaseID: UUID, from connection: ConnectionID
    ) async throws {
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func restoreAllToAutomatic(from connection: ConnectionID) async throws {
        hasRestored = true
    }

    func connectionDidInvalidate(_ connection: ConnectionID) async {}
}
