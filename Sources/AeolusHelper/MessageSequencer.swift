import os

/// Runs the operations handed to it **one at a time, in the order they were handed over**.
///
/// ## The defect this closes
///
/// libxpc invokes an exported object synchronously, on its own event threads, once per
/// message and in the order it delivered them. Everything below `HelperXPCService` is
/// `async`, so each method has to cross from that synchronous call into asynchronous code —
/// and the obvious crossing, an unstructured `Task { … }` per message, throws the order
/// away: the tasks reach `HelperConnectionSession` in whatever order the cooperative pool
/// starts them, not in the order libxpc handed the messages over.
///
/// A client that pipelines `hello` and `snapshot` without awaiting the handshake's reply
/// could therefore have its `snapshot` reach the actor first and be answered
/// `handshakeRequired` for doing exactly what the contract allows. It failed *closed* — the
/// client was refused and nothing reached the authority that should not — which is why
/// [#90](https://github.com/blamechris/Aeolus/issues/90) was filed rather than treated as a
/// safety defect. It is still a defect: a refusal a compliant client cannot avoid is one it
/// cannot act on either.
///
/// **libxpc was never the cause.** The doc comment this replaces said there was "no ordering
/// promise between messages on one connection", and a reader deciding whether ordering could
/// be restored would have concluded from that sentence that it could not. The `Task` hop is
/// what removed the order, and it would have removed it however strictly libxpc delivered.
/// Restoring it is therefore the helper's to do — `CLAUDE.md` rule 7: the client-side rule
/// would have been a courtesy, and this is the control.
///
/// ## The mechanism
///
/// One task per operation, each awaiting the value of the task before it. The tail — the
/// most recently created task — is the only state, read and replaced under one lock, so the
/// task that will await it is published before any later caller can see the tail at all.
/// Operation N+1 therefore starts only after operation N has *returned*, and each operation
/// here is a `deliver(to:)`, so message N's reply block has been called before message N+1
/// begins.
///
/// ## It carries no judgement, and that is a property rather than a convention
///
/// There is nothing here to configure, nothing to consult and nothing that can refuse: the
/// operation is run, exactly once, in its turn. No path drops one, reorders one, or looks at
/// what one contains — this type cannot tell a `hello` from an `apply`. That is what lets
/// `HelperXPCService` hold one and stay the type with no policy in it.
///
/// ## Why a lock and not an actor
///
/// `enqueue(_:)` is called from a synchronous, non-isolated context that cannot `await`,
/// which is the entire reason this type exists; an actor's methods could not be reached from
/// there without the very hop being fixed. `OSAllocatedUnfairLock` rather than a hand-written
/// box, for the same reason `ConnectionHealth` uses one: it is `Sendable` for a `Sendable`
/// state, so this class conforms without the `@unchecked` that `CLAUDE.md` rule 10 and this
/// repository's SwiftLint rule both treat as a claim requiring review. `Mutex` would say the
/// same thing in the standard library and needs macOS 15; this target deploys to 13.
///
/// ## What it retains
///
/// A task holds its predecessor only until that predecessor's value is read, so a burst of N
/// messages retains a chain at most N long and each link is released as the one before it
/// finishes. Once the queue drains, the lock holds one completed task and nothing else.
///
/// ## What it does not do
///
/// It does not carry `restoreAllToAutomatic`. `HelperXPCService` dispatches the panic path
/// on its own task: an operation queued here waits for everything handed over before it, and
/// waiting is a precondition ADR 0005 forbids that one message to have. Nothing in this type
/// knows that — the exemption is one method's body upstairs, because a sequencer that could
/// tell a `hello` from a panic would be the judgement this type is defined by not having.
///
/// It does not order a message against `connectionDidInvalidate`, which is not a message at
/// all: `invalidationHandler` spawns its own detached task and can interleave anywhere. That
/// race is closed by the teardown gate on `HelperConnectionSession`, which is a different
/// mechanism for a different thing, and #90 puts it explicitly out of scope. It also orders
/// nothing between connections — each one has its own sequencer, because two clients have no
/// order between them and must not be able to block each other.
final class MessageSequencer: Sendable {

    private let tail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Runs `operation` after everything already handed over, and before everything handed
    /// over after it. Returns immediately.
    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        tail.withLock { tail in
            let predecessor = tail
            tail = Task {
                await predecessor?.value
                await operation()
            }
        }
    }
}
