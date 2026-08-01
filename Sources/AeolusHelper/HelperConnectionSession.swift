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
/// its own event threads with no ordering promise between messages on one connection.
/// Under strict concurrency that state needs somewhere safe to live.
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
/// Every gated message does: count the message, check the handshake, validate the payload,
/// then dispatch. The handshake check comes before validation deliberately — a client that
/// has not introduced itself gets one answer, `handshakeRequired`, and learns nothing about
/// how the helper parses payloads until it has.
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

    /// Exempt from the handshake gate, and never from the authorisation gate.
    ///
    /// Its only expressible effect is the safe state, so a version fence that stopped a
    /// panicked user's older `fanctl` from restoring automatic control would be a safety
    /// mechanism defeating safety. The message still arrives only on a connection libxpc
    /// admitted against the code-signing requirement — the exemption is from *versioning*,
    /// not from *authorisation*, and those are different gates in different layers.
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
