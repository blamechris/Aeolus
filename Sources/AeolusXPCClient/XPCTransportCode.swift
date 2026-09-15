import Foundation

/// The `NSCocoaErrorDomain` codes `NSXPCConnection` reports a *transport* failure with, as
/// distinct from a refusal the helper authored.
///
/// Named here rather than written as literals at the one place that switches over them,
/// because the numbers are the whole vocabulary: 4099 and 4097 mean entirely different
/// things about whether a lease survived, and a bare `case 4097:` is a line no reviewer can
/// check without leaving the file.
///
/// `CocoaError.Code` is the source for the three it names. It does not name 4102 in this
/// SDK, so that one is written out with the constant from `NSXPCConnection.h` it
/// corresponds to — `NSXPCConnectionCodeSigningRequirementFailure`, documented from
/// macOS 13.
enum XPCTransportCode {

    /// `NSXPCConnectionInterrupted`. The peer process died; the connection object survives
    /// and libxpc will reconnect it to the replacement.
    static let interrupted = CocoaError.Code.xpcConnectionInterrupted.rawValue

    /// `NSXPCConnectionInvalid`. The connection is dead and will not come back — no such
    /// service, or the peer will never be reachable again.
    static let invalid = CocoaError.Code.xpcConnectionInvalid.rawValue

    /// `NSXPCConnectionReplyInvalid`. The reply could not be delivered.
    static let replyInvalid = CocoaError.Code.xpcConnectionReplyInvalid.rawValue

    /// `NSXPCConnectionCodeSigningRequirementFailure`. The peer did not satisfy the
    /// requirement this side pinned.
    ///
    /// Observed on `Mac16,5` / macOS 26.6.2 over an anonymous listener with a deliberately
    /// unsatisfiable requirement — see the spike in
    /// [#158](https://github.com/blamechris/Aeolus/issues/158). Without that measurement
    /// this would be a documented constant nothing had ever raised.
    static let codeSigningRequirementFailure = 4102
}
