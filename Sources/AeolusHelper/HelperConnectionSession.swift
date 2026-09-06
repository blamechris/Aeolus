import AeolusXPC
import Foundation

/// One connection's half of the boundary: the handshake gate, the decode-and-validate of
/// every payload, and the dispatch onto `FanAuthority`.
///
/// ## Why an actor
///
/// The state this holds — has this connection handshaken, how many messages has it
/// delivered — is per connection and mutable, and libxpc invokes the exported object from
/// its own event threads. Under strict concurrency that state needs somewhere safe to live.
/// Ordering is separate: the `Task` hop lost it, `MessageSequencer` restores it (#90).
///
/// An actor rather than a lock, and rather than an unchecked `Sendable` conformance over a
/// mutable class: `CLAUDE.md` rule 10 makes the latter a claim requiring review, and this
/// claim would be exactly the one a data race falsifies. The actor makes the gate's read-then-act
/// atomic — a `hello` racing a `snapshot` on the same connection cannot interleave into
/// "the gate said no, then the gate said yes, then the snapshot went through anyway"
/// — and it costs nothing, because a single connection's messages have no reason to
/// execute concurrently with each other.
///
/// One instance per connection. Nothing here is shared between connections, which is what
/// makes "the gate is per connection" a structural property rather than a convention.
///
/// ## The order of checks, and why it is this order
///
/// Every gated message does: count the message, check that the connection is still alive,
/// check the handshake, validate the payload, then dispatch. The handshake check comes
/// before validation deliberately — a client that has not introduced itself gets one
/// answer, `handshakeRequired`, and learns nothing about how the helper parses payloads
/// until it has. The liveness check comes before *both*, because a dead connection's
/// message has no business being judged on its merits at all.
///
/// ## Why a dead connection is a gate and not bookkeeping
///
/// `MessageSequencer` orders one connection's *messages*, and `connectionDidInvalidate` is
/// not one: `invalidationHandler` spawns its own detached task, so it and a message still
/// enqueue on this actor in unspecified order. That is a real interleaving, not a
/// theoretical one: libxpc can deliver a message it already had in hand and then the kernel
/// tears the port down because the client was `SIGKILL`ed.
///
/// The outcome it exists to prevent: E5's authority releases everything held by this
/// `ConnectionID` — nothing, yet — and is *then* handed an `acquireLease` bound to that
/// same, already-dead `ConnectionID`, whose connection-death teardown has already run and
/// will never run again, leaving the TTL alone to recover the fans.
/// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) requires the two teardown paths to
/// share no code path and both to fail before the fans stay pinned; one being silently
/// pre-empted is that guarantee quietly becoming one path.
///
/// **The gate covers arrival, not flight**, and is defence in depth rather than a guarantee.
/// A message that has not started when `invalidate()` runs is refused; one already past that
/// check is not, because this type is an `actor` and so reentrant across `await` —
/// `acquireLease` reads `hasInvalidated`, suspends, `invalidate()` runs during that suspension,
/// and the message resumes and registers its lease anyway. Observed, not theorised. Closing it
/// belongs to the authority, which must record invalidated `ConnectionID`s and re-check
/// liveness after its last suspension point: [#95](https://github.com/blamechris/Aeolus/issues/95).
///
/// The gate lives here, in E2's listener code, for the same reason
/// `connectionDidInvalidate` is wired here in E2: so that E5 does not have to edit this
/// file to implement half of a safety mechanism.
///
/// ## Where the rest of it is written
///
/// The type is one actor written across three files, split by
/// [#98](https://github.com/blamechris/Aeolus/issues/98) when this one reached swiftlint's
/// 400-line limit with the next explanation still unwritten. `HelperConnectionSessionGates.swift`
/// holds the two gates and the refusal helpers, with the documentation that says what each
/// gate covers; `HelperConnectionSessionMessages.swift` holds the per-message dispatch and
/// the panic path. This file keeps the handshake, the teardown, and every stored property;
/// the comment on `negotiated` below says why the split stops exactly there, and
/// `HelperConnectionSessionAccessTests` is what holds it to that.
actor HelperConnectionSession {

    let id: ConnectionID

    /// Where a message goes once it is past both gates.
    ///
    /// `internal` so `HelperConnectionSessionMessages.swift` can dispatch onto it: a Swift
    /// extension in a sibling file cannot see a `private` member. Reaching it from elsewhere
    /// in `AeolusHelper` buys nothing, because it is the same `FanAuthority` that file's
    /// composition already holds — what would be a defect is a *gated* message reaching it,
    /// and the gates are what decide that, not this reference's access level.
    let authority: any FanAuthority

    private let helperRange: ProtocolVersionRange
    private let helperBuild: String
    private let capabilities: [String]

    /// `internal` for `refuse`/`acknowledgeRefusal`, which live beside the gates whose
    /// refusals they write. A log is not a decision.
    let log: HelperLog

    // MARK: - This connection's state, and where the split stops

    /// All three stay `private`, so this file is the only one that can write them: `hello`
    /// sets `negotiated`, `invalidate` sets `hasInvalidated`, and `countDeliveredMessage()`
    /// is the single increment of `deliveredMessages`. The sibling files read them through
    /// the accessors below and cannot reach the storage.
    ///
    /// That asymmetry is the whole design of the split. Widening a stored property instead
    /// would make the gates' own inputs *settable* from every file in `AeolusHelper` —
    /// `hasInvalidated = false` after a teardown, or a second `negotiated`, are each a way to
    /// re-open a gate without touching a gate — and a per-connection gate whose inputs are
    /// module-wide state is no longer per connection.
    private var negotiated: NegotiatedClient?
    private var deliveredMessages = 0
    private var hasInvalidated = false

    init(
        id: ConnectionID,
        authority: any FanAuthority,
        helperRange: ProtocolVersionRange = AeolusXPCVersion.supportedRange,
        helperBuild: String,
        capabilities: [String] = [],
        log: HelperLog
    ) {
        self.id = id
        self.authority = authority
        self.helperRange = helperRange
        self.helperBuild = helperBuild
        self.capabilities = capabilities
        self.log = log
    }

    // MARK: - Handshake

    /// The first message on every connection. Not itself gated — it is the gate.
    ///
    /// A second `hello` on a connection that has already handshaken is **refused**, not
    /// honoured and not silently ignored. A connection has one negotiated identity and one
    /// negotiated version; letting a client replace either mid-life would mean the
    /// handshake line already in the log describes a client that no longer exists. Refuse,
    /// never repair, applied to the connection's own state rather than to a field.
    ///
    /// Written here rather than with the other messages because it is the one that *writes*
    /// `negotiated`.
    func hello(payload: Data) async -> PayloadReply {
        countDeliveredMessage()
        if let refusal = invalidationRefusal(message: "hello") { return refusal }

        guard negotiated == nil else {
            return refuse(
                .invalidParameter(
                    name: "hello",
                    detail: "the handshake has already completed on this connection"),
                message: "hello")
        }

        let request: HelloRequest
        do {
            request = try AeolusXPCValidation.helloRequest(
                from: payload, helperRange: helperRange)
        } catch {
            return refuse(AeolusXPCFault.crossing(error), message: "hello")
        }

        let client = NegotiatedClient(
            protocolVersion: request.clientProtocolVersion,
            clientDescription: request.clientDescription
        )
        negotiated = client
        log.handshakeCompleted(id, client: client)

        return PayloadReply.encoding(
            HelloReply(
                helperProtocolRange: helperRange,
                helperBuild: helperBuild,
                capabilities: capabilities
            )
        )
    }

    // MARK: - Teardown

    /// The connection died. Crosses the seam so the authority can release anything this
    /// connection was holding — see `FanAuthority.connectionDidInvalidate(_:)`.
    ///
    /// Idempotent. `NSXPCConnection` is not documented to fire its invalidation handler
    /// more than once, but a teardown that a double call would run twice is not one a root
    /// daemon should depend on being called exactly once.
    ///
    /// Written here rather than with the gates because it is the one that *writes*
    /// `hasInvalidated`; `invalidationRefusal(message:)`, which reads it, is the gate.
    func invalidate() async {
        guard !hasInvalidated else { return }
        hasInvalidated = true
        log.connectionInvalidated(
            id, handshake: negotiated, messagesDelivered: deliveredMessages)
        await authority.connectionDidInvalidate(id)
    }

    // MARK: - State, for the gates, the tests and diagnostics

    /// The handshake gate's input, and what the tests read to see what was negotiated.
    var handshakeState: NegotiatedClient? { negotiated }

    var messageCount: Int { deliveredMessages }

    /// The teardown gate's input. Read-only on purpose: `invalidate()` is the only way for
    /// this to become `true`, and there is no way for it to become `false` again.
    var isInvalidated: Bool { hasInvalidated }

    /// The `deliveredMessages += 1` every message performs, as a method rather than as a
    /// widened property.
    ///
    /// It is the one mutation of this actor's state a sibling file needs, and giving it a
    /// name bounds what that file can do with it: increment by one, from a message, and
    /// nothing else. `var deliveredMessages` would have handed the same callers an
    /// assignment.
    func countDeliveredMessage() {
        deliveredMessages += 1
    }
}
