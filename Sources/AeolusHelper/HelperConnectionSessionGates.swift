import AeolusXPC

/// The two gates every message crosses, and the refusals they are answered with.
///
/// Split out of `HelperConnectionSession.swift` by
/// [#98](https://github.com/blamechris/Aeolus/issues/98). What moved is the code and the
/// documentation together: what each gate covers — and, for the teardown gate, exactly what
/// it does *not* — is the reason this file exists, so it is not something the reader has to
/// go and find in the file the functions used to be in.
///
/// Everything here reads this connection's state and writes none of it.
/// `handshakeState` and `isInvalidated` are the read-only accessors
/// `HelperConnectionSession.swift` exposes; the storage behind them stays private to that
/// file, which is what stops a gate being re-opened from anywhere but the message that
/// closed it.
extension HelperConnectionSession {

    // MARK: - The gate

    /// `nil` when this connection may proceed; the refusal when it may not.
    ///
    /// **This is the handshake gate.** Every message except `hello` and
    /// `restoreAllToAutomatic` calls it before doing anything else, and the authority
    /// never sees a message that did not get past it.
    func handshakeRefusal(message: String) -> PayloadReply? {
        guard handshakeState == nil else { return nil }
        return refuse(.handshakeRequired, message: message)
    }

    /// `nil` while this connection is alive; the refusal once it is not.
    ///
    /// **This is the teardown gate.** Every message except `restoreAllToAutomatic` calls it
    /// before doing anything else, so a message that *arrives* after
    /// `connectionDidInvalidate` never reaches the authority. One already **in flight** is
    /// not covered — a synchronous check before a suspension point, on a reentrant actor —
    /// so this is defence in depth, not a guarantee. See `HelperConnectionSession`'s
    /// documentation,
    /// [#95](https://github.com/blamechris/Aeolus/issues/95), and `restoreAllToAutomatic()`.
    func invalidationRefusal(message: String) -> PayloadReply? {
        guard isInvalidated else { return nil }
        return refuse(Self.connectionInvalidated, message: message)
    }

    /// The same gate for the acknowledgement-shaped messages, split for the same reason
    /// `handshakeAcknowledgementRefusal` is split from `handshakeRefusal`.
    func invalidationAcknowledgementRefusal(message: String) -> AcknowledgementReply? {
        guard isInvalidated else { return nil }
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
    ///
    /// Still `private`: both of its readers are the two functions above it, and `private` is
    /// file-scoped, so the split cost this nothing.
    private static let connectionInvalidated = AeolusXPCFault.helperFailed(
        detail: "the connection has been invalidated")

    /// The same gate for the acknowledgement-shaped messages. Two functions rather than
    /// one generic, because the two reply shapes are different contracts and a single
    /// helper returning "some refusal" would let one be delivered on the other's block.
    func handshakeAcknowledgementRefusal(message: String) -> AcknowledgementReply? {
        guard handshakeState == nil else { return nil }
        return acknowledgeRefusal(.handshakeRequired, message: message)
    }

    // MARK: - The refusal helpers

    func refuse(_ fault: AeolusXPCFault, message: String) -> PayloadReply {
        log.refusedMessage(id, message: message, fault: fault)
        return .refusal(fault)
    }

    func acknowledgeRefusal(
        _ fault: AeolusXPCFault, message: String
    ) -> AcknowledgementReply {
        log.refusedMessage(id, message: message, fault: fault)
        return .refusal(fault)
    }
}
