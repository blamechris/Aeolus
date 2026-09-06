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
        await Self.settle()

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
    /// `restoreAllToAutomatic` is the slow one because it is the only message that reaches
    /// the authority without a handshake, so the gate this test is *not* about does not
    /// have to be opened first. `hello` is the fast one: it touches no authority and would
    /// finish immediately if it were allowed to start.
    ///
    /// Both calls are made synchronously from this test's thread, one after the other,
    /// which is exactly how libxpc invokes the exported object.
    ///
    /// **Mutation:** delete `await predecessor?.value` from `MessageSequencer.enqueue(_:)`.
    /// Run: red — the replies come back `["hello", "restoreAllToAutomatic"]`.
    @Test("A fast message does not overtake the slow one sent before it")
    func aFastMessageIsAnsweredAfterTheSlowOneBeforeIt() async throws {
        let gate = AsyncSignal()
        let authority = GatedPanicAuthority(gate: gate)
        let service = HelperXPCService(session: Self.session(over: authority))
        let replies = OrderRecord<String>()

        service.restoreAllToAutomatic { _ in replies.append("restoreAllToAutomatic") }
        service.hello(request: (try? helloPayload()) ?? Data()) { _, _ in
            replies.append("hello")
        }

        try await waitUntil("the slow message reached the authority") {
            await authority.hasBeenAsked
        }
        await Self.settle()
        #expect(
            replies.entries.isEmpty,
            "a reply arrived while the message sent before it was still being handled")

        await gate.signal()
        try await waitUntil("both messages were answered") { replies.entries.count == 2 }
        #expect(replies.entries == ["restoreAllToAutomatic", "hello"])
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

            let (hello, snapshot) = await harness.pipelinedPayloadMessages(
                { proxy, reply in
                    proxy.hello(request: (try? helloPayload()) ?? Data(), reply: reply)
                },
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
    /// That suite counts unstructured `Task` spawn sites, and after #90 the helper's seven
    /// XPC entry points reach `async` code through `enqueue` instead — a call the spawn
    /// scanner does not match. Left there, the sequencer would be a hole in the population
    /// exactly the size of the one the spawn count was watching. So the call sites are
    /// pinned here for the same reason and with the same discipline: each of the seven is a
    /// single `await` of a `HelperConnectionSession` method, and a new one somewhere else
    /// reddens this until its author has shown it is the same shape.
    ///
    /// **Mutation:** add `sequencer.enqueue { }` to any file under `Sources/AeolusHelper`.
    /// Run: red, naming the file.
    @Test("The message sequencer is called only from the XPC entry points")
    func theSequencerIsCalledOnlyFromTheXPCEntryPoints() throws {
        var sites: [String] = []
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            let count = code.components(separatedBy: ".enqueue").count - 1
            if count > 0 { sites.append("\(file.lastPathComponent) x\(count)") }
        }

        #expect(
            sites == ["HelperXPCService.swift x7"],
            """
            the message sequencer's call sites changed: \(sites). Each existing one is a \
            single `await` of a `HelperConnectionSession` method — the same acknowledgement \
            `WriteVerbAllowlistTests` requires of an unstructured `Task`, which is what \
            `enqueue` replaced and what its spawn scanner can no longer see here.
            """)
    }

    // MARK: - Fixtures

    private static func session(over authority: any FanAuthority) -> HelperConnectionSession {
        HelperConnectionSession(
            id: ConnectionID(),
            authority: authority,
            helperBuild: "test",
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Ordering")
        )
    }

    /// Gives anything that is ready to run a real chance to run.
    ///
    /// Every "it has *not* happened" assertion here needs one: without it the expectation
    /// is satisfied by the scheduler simply not having got round to the work yet, which is
    /// a test that passes for a reason nobody chose. The yields drain the cooperative
    /// pool's ready queues and the sleep covers a thread that had not been woken at all.
    private static func settle() async {
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
private final class OrderRecord<Entry: Sendable & Equatable>: @unchecked Sendable {

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

/// A `FanAuthority` whose panic path parks until a signal fires, and answers everything
/// else the way `ReadOnlyFanAuthority` does.
///
/// The panic path rather than `snapshot`, because it is the one message that reaches the
/// authority with no handshake behind it — so a test about ordering does not have to open
/// the handshake gate first and can keep its two messages adjacent.
private actor GatedPanicAuthority: FanAuthority {

    private let gate: AsyncSignal
    private(set) var hasBeenAsked = false

    init(gate: AsyncSignal) {
        self.gate = gate
    }

    func snapshot() async throws -> SystemSnapshot { .empty }

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
        hasBeenAsked = true
        try? await gate.wait()
    }

    func connectionDidInvalidate(_ connection: ConnectionID) async {}
}
