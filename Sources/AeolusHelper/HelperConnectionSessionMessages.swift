import AeolusXPC
import FanKit
import Foundation

/// The per-message dispatch: everything a client can ask for once it is past the gates,
/// plus the one message that is exempt from them.
///
/// Split out of `HelperConnectionSession.swift` by
/// [#98](https://github.com/blamechris/Aeolus/issues/98). Every function here follows the
/// order `HelperConnectionSession` documents — count the message, check liveness, check the
/// handshake, validate the payload, dispatch — and none of them writes this connection's
/// state; `countDeliveredMessage()` is the only mutation any of them can express.
extension HelperConnectionSession {

    // MARK: - Gated messages

    func snapshot() async -> PayloadReply {
        countDeliveredMessage()
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
        countDeliveredMessage()
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
        countDeliveredMessage()
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
        countDeliveredMessage()
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
        countDeliveredMessage()
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
        countDeliveredMessage()
        do {
            try await authority.restoreAllToAutomatic(from: id)
            return .success
        } catch {
            return acknowledgeRefusal(
                AeolusXPCFault.crossing(error), message: "restoreAllToAutomatic")
        }
    }

    // MARK: - Narrowing what arrived

    /// Narrows the `@objc` `String` back to a `UUID` before it reaches a lookup or a log
    /// line.
    ///
    /// `AeolusXPCValidation.validateLeaseID(_:)` is the control — it is what refuses a
    /// 36-byte string that is not a UUID, one carrying a trailing NUL, and one long enough
    /// to be a denial of service against whoever reads the log. The `guard` below is not a
    /// second check: `UUID(uuidString:)` returns an `Optional`, a root daemon does not
    /// force-unwrap, and the branch is unreachable given the line above it.
    ///
    /// Still `private`, and here rather than with the gates, because all three of its
    /// callers are in this file. It is a decode step, not a gate: it refuses a string that
    /// is not a UUID, never a client that may not ask.
    private static func leaseID(from raw: String) throws -> UUID {
        try AeolusXPCValidation.validateLeaseID(raw)
        guard let parsed = UUID(uuidString: raw) else {
            throw AeolusXPCFault.invalidParameter(
                name: "leaseID", detail: "is not a UUID")
        }
        return parsed
    }
}
