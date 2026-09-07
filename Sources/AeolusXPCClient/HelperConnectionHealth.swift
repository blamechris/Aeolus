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
/// It says nothing about fans, leases, or whether manual control is possible. Those are
/// `FanState.manualControlAvailability` and the snapshot's own contents, and conflating
/// the two is how a UI ends up reporting a capability nobody is honouring.
public enum HelperConnectionHealth: Sendable, Hashable {

    /// Nothing has been negotiated. Either no connection has been made yet, or one exists
    /// and has not completed its handshake.
    case idle

    /// A connection is open and `hello` succeeded on it. The only state in which a helper
    /// snapshot may be rendered as current.
    case handshaken

    /// The helper process went away and libxpc will reconnect the connection object to its
    /// replacement.
    ///
    /// **Everything the old process was holding is gone**, leases included, and this client
    /// does not re-acquire one. The next message re-runs the handshake; a client that still
    /// wants the fans asks for them again, deliberately.
    case interrupted

    /// The connection is dead and will not come back. The next message builds a new one.
    ///
    /// Consistent with the helper being absent, not yet approved, or refusing this client
    /// — those cannot be told apart here. See `HelperClientError.helperUnreachable`.
    case invalidated
}
