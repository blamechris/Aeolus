import AeolusXPC
import FanKit
import Foundation

/// What a client said about itself when its handshake succeeded.
///
/// **Self-described, never verified.** The description has been through
/// `AeolusXPCValidation.validateClientDescription(_:)` — bounded in characters and in
/// bytes, no control characters, no bidirectional overrides — so it is safe to put in a
/// log line. That is a different claim from knowing who the client is. What authorises a
/// client is the code-signing requirement libxpc enforces, and that never yields a name to
/// this layer.
struct NegotiatedClient: Sendable, Hashable {
    let protocolVersion: Int
    let clientDescription: String

    var logDescription: String { "\"\(clientDescription)\" (v\(protocolVersion))" }
}

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
actor HelperConnectionSession {

    let id: ConnectionID

    private let authority: any FanAuthority
    private let helperRange: ProtocolVersionRange
    private let helperBuild: String
    private let capabilities: [String]
    private let log: HelperLog

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
    func hello(payload: Data) async -> PayloadReply {
        deliveredMessages += 1
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

    // MARK: - Gated messages

    func snapshot() async -> PayloadReply {
        deliveredMessages += 1
        if let refusal = invalidationRefusal(message: "snapshot") { return refusal }
        if let refusal = handshakeRefusal(message: "snapshot") { return refusal }

        do {
            return PayloadReply.encoding(try await authority.snapshot())
        } catch {
            return refuse(AeolusXPCFault.crossing(error), message: "snapshot")
        }
    }

    /// Decodes and pre-checks a lease request, then asks the authority.
    ///
    /// `validateFanIndices` is **not** run here. It needs the set of fans this machine
    /// actually enumerated, which is hardware state the authority owns; see `FanAuthority`
    /// for why shipping that set up to this layer would be both chatty and a
    /// time-of-check/time-of-use gap on the one input deciding which fans a lease covers.
    func acquireLease(payload: Data) async -> PayloadReply {
        deliveredMessages += 1
        if let refusal = invalidationRefusal(message: "acquireLease") { return refusal }
        if let refusal = handshakeRefusal(message: "acquireLease") { return refusal }

        let request: LeaseRequest
        do {
            request = try AeolusXPCValidation.decodeLeaseRequest(from: payload)
            try AeolusXPCValidation.validateHolderDescription(request.holderDescription)
            try AeolusXPCValidation.validateTimeToLive(request.timeToLive)
        } catch {
            return refuse(AeolusXPCFault.crossing(error), message: "acquireLease")
        }

        do {
            return PayloadReply.encoding(
                try await authority.acquireLease(request, from: id))
        } catch {
            return refuse(AeolusXPCFault.crossing(error), message: "acquireLease")
        }
    }

    func renewLease(id rawLeaseID: String) async -> PayloadReply {
        deliveredMessages += 1
        if let refusal = invalidationRefusal(message: "renewLease") { return refusal }
        if let refusal = handshakeRefusal(message: "renewLease") { return refusal }

        let leaseID: UUID
        do {
            leaseID = try Self.leaseID(from: rawLeaseID)
        } catch {
            return refuse(AeolusXPCFault.crossing(error), message: "renewLease")
        }

        do {
            return PayloadReply.encoding(try await authority.renewLease(id: leaseID, from: id))
        } catch {
            return refuse(AeolusXPCFault.crossing(error), message: "renewLease")
        }
    }

    func releaseLease(id rawLeaseID: String) async -> AcknowledgementReply {
        deliveredMessages += 1
        if let refusal = invalidationAcknowledgementRefusal(message: "releaseLease") {
            return refusal
        }
        if let refusal = handshakeAcknowledgementRefusal(message: "releaseLease") {
            return refusal
        }

        do {
            let leaseID = try Self.leaseID(from: rawLeaseID)
            try await authority.releaseLease(id: leaseID, from: id)
            return .success
        } catch {
            return acknowledgeRefusal(
                AeolusXPCFault.crossing(error), message: "releaseLease")
        }
    }

    func apply(settings payload: Data, leaseID rawLeaseID: String) async -> AcknowledgementReply {
        deliveredMessages += 1
        if let refusal = invalidationAcknowledgementRefusal(message: "apply") { return refusal }
        if let refusal = handshakeAcknowledgementRefusal(message: "apply") { return refusal }

        do {
            // The lease ID is narrowed before the settings are decoded: it is the cheaper
            // check and the one that decides whether this client is even talking about
            // something the helper could have issued.
            let leaseID = try Self.leaseID(from: rawLeaseID)
            let settings = try AeolusXPCValidation.decodeFanSettings(from: payload)
            try await authority.apply(settings, leaseID: leaseID, from: id)
            return .success
        } catch {
            return acknowledgeRefusal(AeolusXPCFault.crossing(error), message: "apply")
        }
    }

    // MARK: - The panic path

    /// Exempt from the handshake gate, from the teardown gate, and — in `HelperXPCService`,
    /// which routes it outside the sequencer — from this connection's message ordering.
    /// Never from the authorisation gate. A message pipelined ahead of it may therefore
    /// still complete after it.
    ///
    /// Its only expressible effect is the safe state, so a version fence that stopped a
    /// panicked user's older `fanctl` from restoring automatic control would be a safety
    /// mechanism defeating safety. The message still arrives only on a connection libxpc
    /// admitted against the code-signing requirement: the exemption is from *versioning*.
    ///
    /// ## Why the teardown gate exempts it too, deliberately
    ///
    /// Every other message is refused once `invalidate()` has run, because a message that
    /// lost the race to a dying connection must not reach the authority and be attributed
    /// to a `ConnectionID` whose teardown has already happened. This one is let through
    /// anyway, and the asymmetry is a decision rather than an oversight.
    ///
    /// It restores the safe state and can express nothing else. Refusing to return fans to
    /// automatic control *because the connection is dying* would be the same defect the
    /// version exemption exists to prevent, arriving through a different door — and the
    /// dying connection is precisely the case where the fans most need putting back. ADR
    /// 0005 requires the panic path to carry the fewest preconditions of anything in the
    /// protocol; "the connection is still alive" is a precondition. The exemption holds only
    /// while this message's contract stays **global** — every fan automatic, every lease
    /// dropped — which makes `connection` attribution alone and both post-invalidation
    /// orderings converge on the safe state; if E5 ever has it consult per-`ConnectionID`
    /// state, it needs revisiting, per [#95](https://github.com/blamechris/Aeolus/issues/95).
    ///
    /// The reply may well be undeliverable by the time this returns, because the port it
    /// would travel on is what died; what matters is the **effect**, not the reply.
    func restoreAllToAutomatic() async -> AcknowledgementReply {
        deliveredMessages += 1
        do {
            try await authority.restoreAllToAutomatic(from: id)
            return .success
        } catch {
            return acknowledgeRefusal(
                AeolusXPCFault.crossing(error), message: "restoreAllToAutomatic")
        }
    }

    // MARK: - Teardown

    /// The connection died. Crosses the seam so the authority can release anything this
    /// connection was holding — see `FanAuthority.connectionDidInvalidate(_:)`.
    ///
    /// Idempotent. `NSXPCConnection` is not documented to fire its invalidation handler
    /// more than once, but a teardown that a double call would run twice is not one a root
    /// daemon should depend on being called exactly once.
    func invalidate() async {
        guard !hasInvalidated else { return }
        hasInvalidated = true
        log.connectionInvalidated(
            id, handshake: negotiated, messagesDelivered: deliveredMessages)
        await authority.connectionDidInvalidate(id)
    }

    // MARK: - State, for tests and diagnostics

    var handshakeState: NegotiatedClient? { negotiated }
    var messageCount: Int { deliveredMessages }

    // MARK: - The gate

    /// `nil` when this connection may proceed; the refusal when it may not.
    ///
    /// **This is the handshake gate.** Every message except `hello` and
    /// `restoreAllToAutomatic` calls it before doing anything else, and the authority
    /// never sees a message that did not get past it.
    private func handshakeRefusal(message: String) -> PayloadReply? {
        guard negotiated == nil else { return nil }
        return refuse(.handshakeRequired, message: message)
    }

    /// `nil` while this connection is alive; the refusal once it is not.
    ///
    /// **This is the teardown gate.** Every message except `restoreAllToAutomatic` calls it
    /// before doing anything else, so a message that *arrives* after
    /// `connectionDidInvalidate` never reaches the authority. One already **in flight** is
    /// not covered — a synchronous check before a suspension point, on a reentrant actor —
    /// so this is defence in depth, not a guarantee. See this type's documentation,
    /// [#95](https://github.com/blamechris/Aeolus/issues/95), and `restoreAllToAutomatic()`.
    private func invalidationRefusal(message: String) -> PayloadReply? {
        guard hasInvalidated else { return nil }
        return refuse(Self.connectionInvalidated, message: message)
    }

    /// The same gate for the acknowledgement-shaped messages, split for the same reason
    /// `handshakeAcknowledgementRefusal` is split from `handshakeRefusal`.
    private func invalidationAcknowledgementRefusal(message: String) -> AcknowledgementReply? {
        guard hasInvalidated else { return nil }
        return acknowledgeRefusal(Self.connectionInvalidated, message: message)
    }

    /// What a message that lost the race to its own connection's death is answered with.
    ///
    /// `.helperFailed` is the vocabulary's stated home for "the helper could not carry out
    /// the request, for a reason no other code here names", and no other code names this
    /// one. Each alternative asserts something false: `handshakeRequired` would tell a
    /// client that had handshaken that it had not, `malformedPayload` and
    /// `invalidParameter` blame a client whose payload was fine, and `.unknown` renders as
    /// "the helper is probably newer than this client".
    ///
    /// No new case was added for it, though the bump policy would allow one. The reply
    /// travels on a port that has already gone, so in practice nothing decodes this and the
    /// precision would buy a client nothing; the value of naming it at all is the log line
    /// `refuse` writes on the way past.
    ///
    /// The detail is fixed text and describes the connection, never anything a client sent.
    private static let connectionInvalidated = AeolusXPCFault.helperFailed(
        detail: "the connection has been invalidated")

    /// The same gate for the acknowledgement-shaped messages. Two functions rather than
    /// one generic, because the two reply shapes are different contracts and a single
    /// helper returning "some refusal" would let one be delivered on the other's block.
    private func handshakeAcknowledgementRefusal(message: String) -> AcknowledgementReply? {
        guard negotiated == nil else { return nil }
        return acknowledgeRefusal(.handshakeRequired, message: message)
    }

    private func refuse(_ fault: AeolusXPCFault, message: String) -> PayloadReply {
        log.refusedMessage(id, message: message, fault: fault)
        return .refusal(fault)
    }

    private func acknowledgeRefusal(
        _ fault: AeolusXPCFault, message: String
    ) -> AcknowledgementReply {
        log.refusedMessage(id, message: message, fault: fault)
        return .refusal(fault)
    }

    /// Narrows the `@objc` `String` back to a `UUID` before it reaches a lookup or a log
    /// line.
    ///
    /// `AeolusXPCValidation.validateLeaseID(_:)` is the control — it is what refuses a
    /// 36-byte string that is not a UUID, one carrying a trailing NUL, and one long enough
    /// to be a denial of service against whoever reads the log. The `guard` below is not a
    /// second check: `UUID(uuidString:)` returns an `Optional`, a root daemon does not
    /// force-unwrap, and the branch is unreachable given the line above it.
    private static func leaseID(from raw: String) throws -> UUID {
        try AeolusXPCValidation.validateLeaseID(raw)
        guard let parsed = UUID(uuidString: raw) else {
            throw AeolusXPCFault.invalidParameter(
                name: "leaseID", detail: "is not a UUID")
        }
        return parsed
    }
}
