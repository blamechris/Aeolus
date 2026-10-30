import AeolusXPC
import Foundation

/// What a failed message means, for the client that sent it: the one place that decides which of
/// the transport's failures costs a connection and which costs only the message.
///
/// Moved out of `HelperClient.swift` by
/// [#600](https://github.com/blamechris/Aeolus/issues/600), when that file stood ten lines under
/// SwiftLint's 1000-line `file_length` error. It is a move and nothing else: the function below
/// is the same code it was there. What it needed from the actor, and so what that file widened
/// for it, is `HelperClient.swift`'s account of where the split stops.
///
/// It could leave that file for the price of two getters and one function because it reads
/// `hasEverHandshaken` and `interruptions` and writes neither, and their setters stay `private`
/// to the declaring file. Everything it changes it changes through the two functions that own
/// that change, `connectionWasInterrupted(_:)` and `discardConnection(_:as:answering:)`, which
/// stay where the storage is.
extension HelperClient {

    // MARK: - What the transport's failures mean

    /// Turns whatever came back into something a caller can act on.
    ///
    /// A refusal the helper authored is thrown **as itself**: `AeolusXPCFault` carries its
    /// own vocabulary, `versionMismatch` carries both sides' ranges, and wrapping either
    /// would flatten "the helper said no" into "something went wrong". Everything else is a
    /// statement about the connection, and this is the one place that decides which.
    ///
    /// `generation` is the connection the failed message was sent on, threaded in from
    /// `exchange` rather than read off the actor. By the time a failure is being explained,
    /// a later connection may already be live and handshaken — that is precisely the
    /// interleaving the field exists for — and reading `self.generation` here would make
    /// every guard below compare a value with itself.
    ///
    /// `notices` is how many death notices had been counted when the message was sent, threaded in
    /// from `exchange` for the same reason; only the 4097 arm reads it (#588).
    ///
    /// Reachable from the suite for the same reason the two handlers in `HelperClient.swift`
    /// (`connectionWasInterrupted(_:)` and `connectionWasInvalidated(_:)`) are: one arm of
    /// this switch — `NSXPCConnectionReplyInvalid` — cannot be provoked over a real
    /// connection at all, and an arm that decides whether a live connection survives is not
    /// one this project is willing to ship untested.
    func translate(_ error: Error, on generation: UInt64, sentAfter notices: UInt64) -> Error {
        // **Cancellation is not a teardown, and this is the line that keeps it from
        // becoming one.** It is a statement about the caller — a view that navigated away,
        // a `fanctl` that was interrupted — and none about the helper, which may be healthy
        // and about to answer. Acting on it would invalidate the connection, and the helper
        // releases a connection's leases when it dies: the fans would hand back to automatic
        // because somebody changed tabs. It is thrown as itself, the way every other
        // cancelled `async` call in Swift reports.
        //
        // The message stays at the head of the helper's queue and that is deliberate. Its
        // deadline outlives its caller (`InFlightMessages`), so the next sequenced verb waits
        // for it to settle: answered, or cut off by that deadline, which with nobody waiting
        // discards nothing. The next verb then hits its **own** deadline and discards — one
        // extra deadline on a genuinely wedged helper for each cancelled message ahead of it,
        // which is the price of never tearing down a healthy one. Several orphans add up; #419
        // is the design note the app's control UI settles before it pipelines.
        if error is CancellationError { return error }
        if let clientError = error as? HelperClientError {
            if case .helperNeverAnswered = clientError {
                // The helper accepted this message and never answered it, which on the
                // wedged `io_connect_t` of `docs/SAFETY.md` § 4 is the expected case rather
                // than an exotic one. The message is still at the head of this connection's
                // queue with nothing able to discard it, and since D25 the helper answers a
                // connection's messages in the order they were sent — so every later gated
                // verb would queue behind it and time out too, permanently. The connection
                // goes; the next call builds another, once, when the caller asks again.
                //
                // Everything else in flight on it goes too, and is told so: the client's own
                // `invalidate()` would reach each of them as 4099, which reads as a helper
                // that was never there (#413).
                discardConnection(generation, as: .unresponsive, answering: .connectionAbandoned)
            }
            // `connectionAbandoned` passes through here untouched, which is why a message a
            // discard answered never counts as a second timeout: it moves no generation and
            // publishes no health.
            return clientError
        }
        if let fault = AeolusXPCFault(nsError: error as NSError) { return fault }

        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else {
            return HelperClientError.helperUnreachable(code: nsError.code)
        }
        switch nsError.code {
        case XPCTransportCode.interrupted:
            // 4097 does not by itself mean a helper died: measured on `Mac16,5` /
            // macOS 26.6.2, a listener whose delegate **refuses** the connection is reported
            // to the client as an interruption too, not as an invalidation. So the code
            // alone cannot tell "the helper restarted under me" from "nothing ever answered",
            // and claiming the former about a peer this connection never handshook with
            // would be inventing a helper. What settles it is whether this connection object
            // ever completed a handshake.
            //
            // It is a death notice only on a message sent after every notice counted so far
            // (#588). One death is several notices, the interruption handler's and a 4097 for each
            // message in flight to it, reaching this actor in no set order. A message sent before
            // the last notice counted went out before a death was heard of, so this is a second
            // notice of a death already counted, or one whose handler's notice is still to come.
            // Counted again, it cleared a handshake recorded since with the replacement, and the
            // next verb's `hello` was refused and took the connection. No death goes uncounted,
            // on this premise: each fires the interruption handler, with messages in flight or
            // without. "With messages in flight or without" is this code's own reading. Apple's
            // part is the header's description of the handler, "A block that is called if the
            // remote process exits or crashes." (Foundation.framework/Headers/NSXPCConnection.h).
            // The same header disclaims any guarantee of ordering between that handler and the
            // replies and other handlers on its queue, which is the "no set order" above. The
            // suite bears the premise out only as far as a harness can: its
            // `killHelperSideOfEveryConnection` invalidates the listener-side connection inside
            // the test process, and no helper process exits. The cost is narrower: a message that
            // reached a replacement before an earlier death was counted, a handshake recorded
            // with it, and the replacement dying too. Until its handler's notice, a gated verb
            // then reaches the next process with no `hello`, and is refused without a teardown.
            let hadSpokenToAHelper = hasEverHandshaken
            if notices == interruptions { connectionWasInterrupted(generation) }
            return hadSpokenToAHelper
                ? HelperClientError.helperRestarted
                : HelperClientError.helperUnreachable(code: nsError.code)
        case XPCTransportCode.replyInvalid:
            // 4101 is the one code here that is **about the message, not the connection**:
            // the reply could not be delivered, and the connection is still alive and still
            // handshaken. Letting it fall into the arm below would drop a live connection's
            // only reference — orphaning the helper-side session, and any lease bound to
            // it, until the 120 s TTL expired. That would collapse the two teardown paths
            // `AeolusXPCProtocol` requires to be independent into one, on a failure that
            // cost nothing but a single answer.
            return HelperClientError.replyNotDelivered
        case XPCTransportCode.codeSigningRequirementFailure:
            discardConnection(generation, as: .refused, answering: .helperSignatureRejected)
            return HelperClientError.helperSignatureRejected
        default:
            // Every other transport code, 4099 included: the connection failed and no
            // message was delivered. The code is carried rather than mapped, because a
            // reason this build has not heard of must still reach a log line.
            //
            // The 4099 the client's **own** `invalidate()` produces does not arrive here. The
            // discard answered every message on that connection first (`InFlightMessages`),
            // so each latch already held its answer when the 4099 reached it (#413). What
            // arrives is the transport's own report, and the messages still in flight beside
            // the one that carried it are given the same answer.
            let unreachable = HelperClientError.helperUnreachable(code: nsError.code)
            discardConnection(generation, as: .invalidated, answering: unreachable)
            return unreachable
        }
    }
}
