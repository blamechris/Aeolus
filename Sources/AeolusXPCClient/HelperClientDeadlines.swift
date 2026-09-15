import Foundation

/// How long this client waits for one message before it gives up on it.
///
/// **`gatedVerb` and `panicVerb` are unmeasured.** They are named constants rather than
/// literals at the call sites so that the guess is in one place and is visible as a guess;
/// neither was derived from a measurement, and the only timing this project has measured on
/// its own hardware is a snapshot's 0.9–2.9 s, which is what the gated figure is loosely
/// scaled against. `handshakeVerb` is the exception: it is *derived*, from the helper's own
/// startup budget plus a stated spawn allowance, and the arithmetic is written out below
/// where a reviewer can disagree with a term rather than with a number.
/// [#229](https://github.com/blamechris/Aeolus/issues/229) is the helper-side deadline;
/// this is the client's, and the two are independent.
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

    /// The helper's own startup reconciliation budget, restated.
    ///
    /// `ReconciliationLimits.budget` lives in `AeolusHelper` and this target must not link
    /// the root daemon to read it, so the number is copied here — and a copy with nothing
    /// checking it is exactly the drift this repository keeps paying for. What makes it a
    /// derivation rather than a second constant is
    /// `HelperClientDeadlineTests.theHandshakeDeadlineIsDerivedFromTheHelpersOwnBudget`,
    /// which imports both modules and fails the moment the two stop agreeing.
    public static let reconciliationBudget: Duration = .seconds(5)

    /// What launchd's spawn, `ClientAuthorisation.resolveForRunningProcess()`'s file I/O
    /// and SMC enumeration are allowed **between them** before the helper's listener is
    /// resumed.
    ///
    /// A stated allowance rather than a measurement, and it is stated so that the handshake
    /// deadline has one thing in it that can be argued with. The only figure this project
    /// has measured for the whole of that window is `2.428 s`, warm, on `Mac16,5` with an
    /// uncontended SMC — so five seconds is that figure with room for a cold machine, not a
    /// number chosen to look generous.
    public static let spawnAllowance: Duration = .seconds(5)

    /// `hello` on a cold connection, which is not the same wait as a verb on an established
    /// one.
    ///
    /// The handshake queues behind everything the helper does before it serves anybody.
    /// `HelperComposition.bringUp()` resumes its listener as its **last** statement,
    /// deliberately, so that no client can be answered over unreconciled fans — which means
    /// libxpc holds the client's `hello` for the whole of composition. Sharing `gatedVerb`
    /// with it was the defect: five seconds is `ReconciliationLimits.budget` *alone*, with
    /// nothing left for the spawn, the authorisation file I/O or the enumeration in front
    /// of it, so the ordinary cold-start path could time out on a helper that was working.
    ///
    ///     handshakeVerb = reconciliationBudget + spawnAllowance + gatedVerb
    ///                   = 5 s                  + 5 s            + 5 s        = 15 s
    ///
    /// The last term is the round trip itself, once the helper is actually serving.
    public static let handshakeVerb: Duration =
        HelperClientDeadlines.reconciliationBudget
        + HelperClientDeadlines.spawnAllowance
        + HelperClientDeadlines.gatedVerb

    public let gatedVerb: Duration
    public let panicVerb: Duration
    public let handshakeVerb: Duration

    public init(gatedVerb: Duration, panicVerb: Duration, handshakeVerb: Duration) {
        self.gatedVerb = gatedVerb
        self.panicVerb = panicVerb
        self.handshakeVerb = handshakeVerb
    }

    /// The shipping trio.
    public static let `default` = HelperClientDeadlines(
        gatedVerb: HelperClientDeadlines.gatedVerb,
        panicVerb: HelperClientDeadlines.panicVerb,
        handshakeVerb: HelperClientDeadlines.handshakeVerb
    )
}
