import AeolusXPC
import Foundation

/// The object `NSXPCConnection` vends to one client: seven methods, each of which does
/// nothing except hand the message to that connection's `HelperConnectionSession` and
/// deliver whatever comes back — four of them in the order libxpc delivered them.
///
/// ## Three methods are not sequenced, and each exemption is the same argument
///
/// Four methods go through the sequencer: `hello`, `snapshot`, `acquireLease` and `apply`.
/// Three keep their own unstructured `Task`, exactly as every method had before
/// [#90](https://github.com/blamechris/Aeolus/issues/90). Ordering is a *precondition* —
/// "every message sent earlier on this connection has returned" — and
/// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) says the panic path carries the
/// fewest preconditions of anything in this protocol. It is already exempt from the
/// handshake gate and from the teardown gate; a queue behind a `snapshot` that costs
/// 0.9–2.9 s on this machine's own measurements — and never returns at all on the wedged
/// `io_connect_t` of `docs/SAFETY.md` § 4 — is a third precondition, and the one that
/// matters most in the state the user reaches for it in.
///
/// **`renewLease` and `releaseLease` joined it in
/// [#229](https://github.com/blamechris/Aeolus/issues/229), on that argument and not on a
/// new one.** A heartbeat is the message that proves the client is still alive, and
/// `docs/SAFETY.md` § 1 grants a 30 s TTL with a 10 s beat *so that two consecutive missed
/// beats are tolerated* — a property of the client's sending, which a helper-side backlog
/// defeats without the client doing anything wrong. § 3 has the app rendering the snapshot at
/// 1 Hz on the connection it also holds its lease on, and one message at a time is one
/// message at a time: once the backlog is longer than the TTL, a `renewLease` sent exactly on
/// schedule reaches `LeaseAuthority` after the lease it was renewing has gone. The direction
/// was fail-safe — the fans go back to automatic — and it was still a live, healthy client
/// losing manual control for a reason it could neither see nor avoid. `releaseLease` is the
/// same message pointing the other way: every read in front of it is time the fans stay in
/// manual after the client has already asked for them back.
///
/// The alternative was a depth ceiling or a per-message deadline on the sequencer. It was
/// costed and not taken: it would have added a *new refusal* at the privilege boundary — a
/// verb answered `helperFailed` for a backlog it did not create — where this adds none, and a
/// bound generous enough not to refuse a legitimate pipeline is a bound wider than the TTL,
/// which is the thing being protected.
///
/// #90's requirement is unaffected, and that is a causal argument rather than a hope: what it
/// asks for is that a verb pipelined ahead of the handshake's reply is not refused
/// `handshakeRequired` for overtaking it. A `renewLease` or `releaseLease` carries a lease ID,
/// a lease ID comes only from `acquireLease`'s reply, and `acquireLease` is still sequenced
/// behind `hello` — so holding one is proof the handshake already completed, and neither verb
/// can be in the overtaking role. The verbs that *can* be pipelined ahead of the reply —
/// `snapshot`, `acquireLease`, `apply` — are all still in the queue, and the gate itself is
/// untouched: it is checked inside the message, on `HelperConnectionSession`, so where a
/// message was dispatched from cannot reach it.
///
/// `OrderingExemptionTests.thePanicPathIsNotDelayedByAParkedMessage` guards the panic path;
/// `LeaseHeartbeatStarvationTests` guards the other two, including that leaving the queue took
/// the handshake gate with it nowhere.
///
/// **The hazard the exemptions create is the panic path's, restated.** A message sent before
/// an unsequenced verb may still be executing when it runs, so a `releaseLease` can take
/// effect before an `apply` that was sent ahead of it and the fan is left in the state the
/// earlier message asked for. A client that needs a release to be the last thing that happens
/// awaits its earlier replies first; the exemption buys promptness, not ordering.
///
/// ## Deliberately empty of judgement
///
/// It holds exactly one piece of state, and that state is a `MessageSequencer`. There is
/// still no validation here and no branch that could refuse or admit anything — the panic
/// path's exemption above is a fixed property of one method's body, not a runtime decision:
/// nothing is consulted, no message is inspected, and there is no input that changes which
/// route a verb takes. Every method has the same three lines, and that uniformity is the
/// point (the seventh differs in one word): this is the one type in the
/// helper that libxpc calls directly, on threads it owns, and a decision taken here would be
/// a decision taken outside the actor that serialises this connection's state. Anything that
/// looks like policy appearing in this file is a bug in the layering, not a shortcut.
///
/// **The sequencer is not a decision and cannot become one.** It has nothing to consult and
/// no way to drop, reorder or inspect what it is given — it cannot tell a `hello` from an
/// `apply` — so what it adds is a property of the *dispatch* and not of the message. Before
/// [#90](https://github.com/blamechris/Aeolus/issues/90) each method spawned its own
/// unstructured `Task`, which is what put a client's `snapshot` in front of the `hello` it
/// was sent after; that hop is state this type kept in the runtime's scheduler instead of in
/// a field, and having no field for it did not make it absent. See `MessageSequencer`.
///
/// `Sendable` with only immutable, `Sendable` stored properties — permitted for a `final`
/// class whose superclass is `NSObject` — rather than an unchecked conformance, which
/// `CLAUDE.md` rule 10 and this repository's own SwiftLint rule both treat as a claim
/// requiring review. The sequencer keeps that true: its own state is behind
/// `OSAllocatedUnfairLock`, so there is still nothing here to race on.
///
/// ## Every reply block is called exactly once
///
/// `PayloadReply` and `AcknowledgementReply` are what make that structural: each has one
/// `deliver(to:)`, each `deliver(to:)` calls the block once on every path, and no method
/// here can reach a `return` without going through one. `AeolusXPCProtocol` calls
/// `(nil, nil)` a protocol violation rather than an empty success, and this is where that
/// is enforced rather than remembered.
final class HelperXPCService: NSObject, AeolusXPCProtocol, Sendable {

    private let session: HelperConnectionSession
    private let sequencer = MessageSequencer()

    init(session: HelperConnectionSession) {
        self.session = session
    }

    func hello(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        sequencer.enqueue { [session] in await session.hello(payload: request).deliver(to: reply) }
    }

    func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void) {
        sequencer.enqueue { [session] in await session.snapshot().deliver(to: reply) }
    }

    func acquireLease(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        sequencer.enqueue { [session] in
            await session.acquireLease(payload: request).deliver(to: reply)
        }
    }

    /// Dispatched immediately, on its own task, never through the sequencer. See the type
    /// doc: a heartbeat may not wait on a backlog of the client's own reads (#229).
    func renewLease(id: String, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task { [session] in await session.renewLease(id: id).deliver(to: reply) }
    }

    /// Dispatched immediately, on its own task, never through the sequencer. See the type
    /// doc: the verb that hands the fans back may not wait either (#229).
    func releaseLease(id: String, reply: @escaping @Sendable (Error?) -> Void) {
        Task { [session] in await session.releaseLease(id: id).deliver(to: reply) }
    }

    func apply(settings: Data, leaseID: String, reply: @escaping @Sendable (Error?) -> Void) {
        sequencer.enqueue { [session] in
            await session.apply(settings: settings, leaseID: leaseID).deliver(to: reply)
        }
    }

    /// Dispatched immediately, on its own task, never through the sequencer. See the type
    /// doc: the panic path may not wait on a message sent before it.
    func restoreAllToAutomatic(reply: @escaping @Sendable (Error?) -> Void) {
        Task { [session] in await session.restoreAllToAutomatic().deliver(to: reply) }
    }
}
