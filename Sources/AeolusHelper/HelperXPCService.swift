import AeolusXPC
import Foundation

/// The object `NSXPCConnection` vends to one client: seven methods, each of which does
/// nothing except hand the message to that connection's `HelperConnectionSession` and
/// deliver whatever comes back — the six gated ones in the order libxpc delivered them.
///
/// ## `restoreAllToAutomatic` is not sequenced, and that is deliberate
///
/// Six methods go through the sequencer. The panic path does not: it keeps its own
/// unstructured `Task`, exactly as every method had before
/// [#90](https://github.com/blamechris/Aeolus/issues/90). Ordering is a *precondition* —
/// "every message sent earlier on this connection has returned" — and
/// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) says the panic path carries the
/// fewest preconditions of anything in this protocol. It is already exempt from the
/// handshake gate and from the teardown gate; a queue behind a `snapshot` that costs
/// 0.9–2.9 s on this machine's own measurements — and never returns at all on the wedged
/// `io_connect_t` of `docs/SAFETY.md` § 4 — is a third precondition, and the one that
/// matters most in the state the user reaches for it in.
///
/// #90's requirement is unaffected: what it asks for is that a pipelined `snapshot` is not
/// refused for overtaking the `hello` it was sent behind, and the panic verb is in neither
/// role. `MessageOrderingTests.thePanicPathIsNotDelayedByAParkedMessage` is the guard.
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

    func renewLease(id: String, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        sequencer.enqueue { [session] in await session.renewLease(id: id).deliver(to: reply) }
    }

    func releaseLease(id: String, reply: @escaping @Sendable (Error?) -> Void) {
        sequencer.enqueue { [session] in await session.releaseLease(id: id).deliver(to: reply) }
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
