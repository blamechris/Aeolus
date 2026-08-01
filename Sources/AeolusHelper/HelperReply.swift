import AeolusXPC
import Foundation

/// The answer to a message whose reply block is `(Data?, Error?) -> Void`.
///
/// `AeolusXPCProtocol` states the invariant in prose: **exactly one of the two is
/// non-nil**, `(nil, nil)` is a protocol violation rather than an empty success, and a
/// client that reads it as one has invented an answer the helper never gave. This type is
/// that sentence made unrepresentable-otherwise. Every message handler returns one of
/// these and `deliver(to:)` is the only thing that calls a reply block, so the invariant
/// holds by construction rather than by every handler remembering it.
///
/// The direction of the risk is what makes it worth a type. A handler that returned `(nil,
/// nil)` would look, on a client, exactly like a helper that had nothing to say — and the
/// client would render an empty snapshot as the state of the machine.
enum PayloadReply: Sendable {
    case payload(Data)
    case refusal(AeolusXPCFault)

    /// Answers the client, exactly once, with exactly one of the two.
    func deliver(to reply: @Sendable (Data?, Error?) -> Void) {
        switch self {
        case .payload(let data):
            reply(data, nil)
        case .refusal(let fault):
            // asNSError() is what survives the NSXPCConnection round trip with the fault
            // vocabulary intact; a bare Swift error arrives flattened, with its associated
            // values gone.
            reply(nil, fault.asNSError())
        }
    }

    /// Encodes a value as the payload, or turns the encoding failure into a refusal.
    ///
    /// A helper that cannot encode its own answer has to say so. Returning success with an
    /// empty payload would be the `(nil, nil)` defect wearing a different shape, and
    /// throwing past the reply block would leave the client waiting on an answer that
    /// never comes.
    ///
    /// `.helperFailed` and not `.malformedPayload`, because the two name different
    /// culprits. `malformedPayload` is documented as "a payload did not decode, or was
    /// missing a required field" — a statement about what the *client* sent, and
    /// `snapshot(reply:)` carries no payload at all. The value that failed to encode was
    /// built here, out of what this machine's firmware reported, so the client is the one
    /// party to the exchange that cannot be at fault. A user told their request was
    /// malformed would file a bug against the wrong half of the system, which is the same
    /// mistake in the other direction as the `.unknown` this vocabulary already rejected
    /// for making a hardware fault look like version skew.
    static func encoding(_ value: some Encodable) -> PayloadReply {
        do {
            return .payload(try AeolusXPCCoding.encoder().encode(value))
        } catch {
            // The detail names the failure, never the value: this text reaches a log line.
            // A fixed string rather than the underlying `EncodingError`, whose description
            // quotes the offending value and the coding path that reached it.
            return .refusal(
                .helperFailed(detail: "the helper could not encode its own reply"))
        }
    }
}

/// The answer to a message whose reply block is `(Error?) -> Void`: `nil` means it
/// succeeded, non-nil is the refusal.
///
/// Separate from `PayloadReply` rather than a generic over an optional payload, because
/// the two reply shapes are different contracts and collapsing them would let a handler
/// for one be wired to the other.
enum AcknowledgementReply: Sendable {
    case success
    case refusal(AeolusXPCFault)

    func deliver(to reply: @Sendable (Error?) -> Void) {
        switch self {
        case .success:
            reply(nil)
        case .refusal(let fault):
            reply(fault.asNSError())
        }
    }
}

extension AeolusXPCFault {

    /// Renders any error thrown on the helper's side as a fault a client can act on.
    ///
    /// Anything the boundary's own validation or the authority raised is already an
    /// `AeolusXPCFault` and passes through **unchanged** — which is the important half:
    /// this must never flatten a precise refusal into a generic one. Anything else came
    /// from a layer with its own vocabulary, in practice `SMCCore`, and becomes
    /// `.helperFailed` carrying that layer's description.
    ///
    /// Quoting it is safe here and nowhere else in this vocabulary: the text is authored
    /// by the helper's own dependencies, not by a client, so there is no client-chosen
    /// string steering a log line. `FaultText.displayable` still sanitises it at render.
    ///
    /// Never "success". A path that cannot say what went wrong still has to say that
    /// something did.
    static func crossing(_ error: Error) -> AeolusXPCFault {
        if let fault = error as? AeolusXPCFault { return fault }
        return .helperFailed(detail: String(describing: error))
    }
}
