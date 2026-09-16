import AeolusXPC
import Foundation

/// Everything that can go wrong on the client's side of the boundary, as distinct from
/// everything the helper can say no to.
///
/// **A refusal is not one of these.** `AeolusXPCFault` is thrown as itself — a client that
/// wrapped `leaseExpired` in a transport error would have flattened "the helper said no"
/// into "something went wrong", which is the distinction
/// `AeolusXPCFault.init?(nsError:)` returning `nil` exists to preserve. `versionMismatch`
/// in particular is deliberately **not** a case here: it carries both sides' ranges and
/// belongs to the vocabulary that can express them.
///
/// Every case below is a statement about the connection or about this client, never about
/// what the helper decided.
public enum HelperClientError: Error, Sendable, Hashable {

    /// This client cannot establish who it would be talking to, so it did not connect.
    ///
    /// The ordinary outcome of a `Monitor` build, a plain `swift build`, and `swift test`:
    /// an ad-hoc-signed process has no Team ID, and "the helper signed by whoever signed
    /// me" then names nobody. A client showing this to a user should say *unsigned build*,
    /// not *missing daemon* — they are different problems with different fixes, and this
    /// is the one case where the two can be told apart.
    case clientCannotVerifyHelper(HelperPinningRefusal)

    /// The connection went away without a message ever being delivered.
    ///
    /// **Two situations are indistinguishable here, and both must be named to the user.**
    /// The helper may not be installed or not yet approved; or the helper may have
    /// *refused this client* because its signature did not satisfy the requirement. ADR
    /// 0005 measured that directly: libxpc drops a requirement-refused peer and invalidates
    /// the connection with nothing delivered, which is what a client that connected to
    /// nothing also sees. Reporting either one alone would be a guess presented as a
    /// diagnosis.
    ///
    /// The app narrows it with `HelperInstallationState`, which knows what the bundle
    /// contains and what `SMAppService` says about it; `fanctl`, which has no such source,
    /// names both possibilities.
    ///
    /// `code` is the underlying `NSError` code, carried rather than asserted because the
    /// transport's vocabulary is not this project's and a code nobody anticipated must still
    /// reach a log line. **It is 4099 or 4097**, and that both codes land here is a
    /// measurement rather than a guess: on `Mac16,5` / macOS 26.6.2 a listener whose delegate
    /// refuses the connection is reported to the client as an *interruption*, exactly as a
    /// helper that died mid-call is. What separates the two is not the code but whether this
    /// connection ever completed a handshake — see `helperRestarted`.
    case helperUnreachable(code: Int)

    /// The helper process died and was replaced while this message was in flight.
    ///
    /// The connection object survives — libxpc reconnects it to the new instance — but
    /// nothing the old process was holding does. Any lease died with it, and this client
    /// does not re-acquire one.
    ///
    /// **Raised only on a connection that had already handshaken**, because 4097 alone does
    /// not mean a helper was ever there: a refused connection reports the same code. Saying
    /// "the helper restarted" about a peer this client never spoke to would be inventing
    /// one, so that case is `helperUnreachable` instead.
    case helperRestarted

    /// The peer did not satisfy the code-signing requirement this client pinned, and
    /// libxpc said so rather than merely invalidating the connection.
    ///
    /// Reached only when libxpc reports `NSXPCConnectionCodeSigningRequirementFailure`
    /// (4102). It is documented from macOS 13 and **was observed on this project's one
    /// machine** — see the spike recorded in #158 — which is why it is a case rather than
    /// folding into `helperUnreachable`.
    case helperSignatureRejected

    /// Neither the reply block nor the connection's error handler ran within the deadline.
    ///
    /// `NSXPCConnection` has no per-message timeout, so without this a helper that accepts
    /// a message and never answers holds its caller forever — which on the wedged
    /// `io_connect_t` of `docs/SAFETY.md` § 4 is the expected case rather than an exotic
    /// one. The deadline is a client-side invention and is **unmeasured**; see
    /// `HelperClientDeadlines`.
    case helperNeverAnswered(after: Duration)

    /// The helper's answer could not be delivered, and **the connection is still alive**.
    ///
    /// `NSXPCConnectionReplyInvalid` (4101) is the one transport code that is about a
    /// message rather than about the connection: the reply block could not be invoked —
    /// over-released, or carrying something that would not encode — while the connection
    /// itself is unaffected and still handshaken. It is a case of its own rather than an
    /// arm of `helperUnreachable` because the two call for opposite responses: the helper
    /// is reachable, this one answer is lost, and a client that tore the connection down
    /// over it would orphan the helper-side session and any lease bound to it until the
    /// TTL expired.
    ///
    /// Nothing can be said about whether the request took effect. The helper may well have
    /// done the work.
    case replyNotDelivered

    /// The helper answered in a shape the contract does not permit.
    ///
    /// `(nil, nil)` on a payload message is the one that matters: `AeolusXPCProtocol`
    /// calls it a protocol violation rather than an empty success, and a client that read
    /// it as one would render an invented answer as the state of the machine. A reply that
    /// does not decode lands here too — the helper said something this build cannot read,
    /// which is not the same as the helper saying no.
    case protocolViolation(detail: String)
}

extension HelperClientError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .clientCannotVerifyHelper(let refusal):
            return """
                Aeolus will not connect to its helper: \(refusal.description). This build \
                cannot be used to control fans; reads do not need the helper.
                """
        case .helperUnreachable:
            return """
                The Aeolus helper did not answer. Either it is not installed or not yet \
                approved, or it refused this copy of Aeolus because the signature did not \
                match. These possibilities cannot be told apart from here.
                """
        case .helperRestarted:
            return """
                The Aeolus helper restarted while this request was in flight. Any manual \
                control it was holding ended with it; ask for the fans again if you still \
                want them.
                """
        case .helperSignatureRejected:
            return """
                The process answering as the Aeolus helper did not match the signature \
                Aeolus requires, so nothing was sent to it.
                """
        case .helperNeverAnswered(let deadline):
            return """
                The Aeolus helper accepted this request and did not answer within \
                \(deadline). Nothing can be said about whether it took effect.
                """
        case .replyNotDelivered:
            return """
                The Aeolus helper's answer to this request could not be delivered. The \
                connection is still open; nothing can be said about whether the request \
                took effect.
                """
        case .protocolViolation(let detail):
            return "The Aeolus helper answered in a way this build cannot read: \(detail)."
        }
    }
}
