import Foundation

/// What a `HelperClient` can truthfully say about its connection right now.
///
/// [ADR 0006](../../docs/ADR/0006-single-smc-reader.md) makes this the app's switch: the
/// app renders from helper snapshots **only** while a handshaken connection is healthy, and
/// falls back to its own direct SMC reads otherwise. So the value below decides which of
/// two sources a fan row is allowed to come from, and a state that overstated the
/// connection would put a control claim on screen with nothing behind it — `CLAUDE.md`
/// rule 6.
///
/// ## Every case a client can end up in has a name here
///
/// The first version of this type had four cases and could not express three of the
/// conditions ADR 0006 has to switch on. Two of them were **indistinguishable from "nothing
/// has been tried yet"** — a helper that refused this client, and a helper this client does
/// not share a protocol version with — and the third was worse than that: a connection that
/// handshook and then stopped answering still read `.handshaken`, which is the one value
/// that licenses rendering a helper snapshot as current. `docs/SAFETY.md` § 4 calls that
/// wedge the *expected* case, not an exotic one, so the signal spent its most important
/// state on the situation it was most likely to be wrong about.
///
/// It says nothing about fans, leases, or whether manual control is possible. Those are
/// `FanState.manualControlAvailability` and the snapshot's own contents, and conflating
/// the two is how a UI ends up reporting a capability nobody is honouring.
public enum HelperConnectionHealth: Sendable, Hashable {

    /// Nothing has been negotiated and nothing has refused. Either no connection has been
    /// made yet, one exists and has not completed its handshake, or a caller has
    /// deliberately disconnected.
    ///
    /// Reaching this state is not evidence of anything. It is the absence of an attempt,
    /// and it is deliberately no longer where a refusal or a version mismatch lands.
    case idle

    /// A connection is open and `hello` succeeded on it. **The only state in which a helper
    /// snapshot may be rendered as current**, and the licence is now true rather than
    /// aspirational: a helper that accepts a message and never answers moves this client to
    /// `unresponsive` instead of leaving it here.
    case handshaken

    /// The helper accepted a message and did not answer it within the message's deadline.
    ///
    /// The wedged `io_connect_t` of `docs/SAFETY.md` § 4 arriving as a connection state.
    /// A snapshot from before the wedge is **not** current and must not be rendered as
    /// though it were; what this state licenses is saying that the helper has stopped
    /// answering, which is a different sentence from "there is no helper".
    ///
    /// The connection has been dropped, so the next message builds a new one — once, when
    /// a caller asks. Nothing here retries.
    case unresponsive

    /// The helper process went away and libxpc will reconnect the connection object to its
    /// replacement.
    ///
    /// **Everything the old process was holding is gone**, leases included, and this client
    /// does not re-acquire one. The next message re-runs the handshake; a client that still
    /// wants the fans asks for them again, deliberately.
    case interrupted

    /// The connection is dead and will not come back. The next message builds a new one.
    ///
    /// Consistent with the helper being absent, not yet approved, or having silently
    /// refused this client over a code-signing mismatch — ADR 0005 measured that libxpc
    /// drops that last one with nothing delivered, indistinguishable from the first two at
    /// this layer, so this state must not be read as naming only two of the three. The
    /// *explicit* signature refusal (`NSXPCConnectionCodeSigningRequirementFailure`) is
    /// `.refused` instead; this is the other one, where the drop is silent. See
    /// `HelperClientError.helperUnreachable`.
    case invalidated

    /// The two ends would not agree to talk at all.
    ///
    /// Three situations, all of them a refusal rather than a failure: this client cannot
    /// establish who it would be talking to and so did not connect
    /// (`HelperClientError.clientCannotVerifyHelper`, the ordinary outcome of every
    /// `Monitor` build and every unsigned `fanctl`); the peer did not satisfy the
    /// requirement this client pinned (`helperSignatureRejected`); or the helper refused
    /// the handshake itself.
    ///
    /// Distinguished from `invalidated` because the fix is different and a UI should say so:
    /// nothing here is repaired by waiting or by retrying.
    case refused

    /// This client and the helper do not share a protocol version.
    ///
    /// Its own case rather than part of `refused` because it is the one refusal whose remedy
    /// is exact — update one side — and because ADR 0006 names it: an app that fell back to
    /// its own SMC reads without saying *why* would present a version fence as a missing
    /// daemon. The ranges both sides offered are carried by the thrown
    /// `AeolusXPCFault.versionMismatch`, which is where they belong.
    case versionMismatched
}
