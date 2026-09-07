import Foundation

/// How long this client waits for one message before it gives up on it.
///
/// **Both numbers are unmeasured.** They are named constants rather than literals at the
/// call sites so that the guess is in one place and is visible as a guess; nothing here
/// was derived from a measurement, and the only timing this project has measured on its
/// own hardware is a snapshot's 0.9–2.9 s, which is what the gated figure is loosely
/// scaled against. [#229](https://github.com/blamechris/Aeolus/issues/229) is the
/// helper-side deadline; this is the client's, and the two are independent.
///
/// The deadline exists because `NSXPCConnection` has none. A reply block may never be
/// invoked at all, and the error handler only fires when the *connection* fails — so a
/// helper that accepts a message and never answers it holds its caller forever. On the
/// wedged `io_connect_t` of `docs/SAFETY.md` § 4 that is the expected behaviour rather
/// than an exotic one, which is why a client that renders "no answer" as a failure needs
/// something to render it *from*.
///
/// Injectable at `HelperClient.init` so the suite can assert the specific error rather
/// than waiting five seconds for it.
public struct HelperClientDeadlines: Sendable, Hashable {

    /// Every message behind the handshake gate.
    public static let gatedVerb: Duration = .seconds(5)

    /// The panic path, which restores every fan and drops every lease before it answers,
    /// and is therefore allowed longer than a read.
    public static let panicVerb: Duration = .seconds(10)

    public let gatedVerb: Duration
    public let panicVerb: Duration

    public init(gatedVerb: Duration, panicVerb: Duration) {
        self.gatedVerb = gatedVerb
        self.panicVerb = panicVerb
    }

    /// The shipping pair.
    public static let `default` = HelperClientDeadlines(
        gatedVerb: HelperClientDeadlines.gatedVerb,
        panicVerb: HelperClientDeadlines.panicVerb
    )
}
