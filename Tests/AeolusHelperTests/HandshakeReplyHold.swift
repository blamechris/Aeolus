/// What a `hello` reply held by `ClientListenerHarness` waits for before it leaves the helper.
///
/// The reply is held, not the `hello`: the message reaches the real session, which records the
/// handshake, and only the answer waits. See `ClientListenerHarness.init`.
protocol HandshakeReplyHold: Sendable {

    /// Returns when the reply now ready may leave.
    func replyMayLeave() async
}

/// Every `hello` reply waits for the one signal, and once it has fired none waits. What
/// `holdingHandshakeReplies` was before it took any hold.
///
/// A cancelled wait lets the reply go, as it always did (`try?`).
extension AsyncSignal: HandshakeReplyHold {

    func replyMayLeave() async { try? await wait() }
}

/// Each `hello` reply held on a signal of its own: the first reply ready waits for the first
/// signal, the second for the second, and a reply past the last leaves at once
/// ([#582](https://github.com/blamechris/Aeolus/issues/582)).
///
/// One signal cannot hold the second `hello` once the first has been let go, and a test of what
/// happens after the helper dies needs both: the first answered, so a caller has handshaken with
/// the process that dies, and the second held, so the replacement's handshake is certainly
/// unanswered while the test looks.
///
/// **"In turn" is the order the replies are ready**, which is the order the `hello`s arrived only
/// while one is outstanding at a time. A test using this sends each `hello` after the one before it
/// was answered, or after the connection that carried it died.
actor HelloRepliesHeldInTurn: HandshakeReplyHold {

    private let signals: [AsyncSignal]
    private var turn = 0

    init(_ signals: AsyncSignal...) {
        self.signals = signals
    }

    func replyMayLeave() async {
        let mine = turn
        turn += 1
        guard mine < signals.count else { return }
        try? await signals[mine].wait()
    }
}

/// Holds the first call of one of `HelperClient`'s suite holds until `release` fires, lets every
/// later call through, and counts them all.
///
/// Run as `handshakeRelayHold`, it holds the first caller's relay, and `started` is how many
/// callers have joined a handshake or started one. Run as `receivedHelloReplyHold`, it holds the
/// first `hello`'s answer once the client has it, and `started` is how many answers have arrived.
/// Run as `handshakeStartHold`, it holds the first handshake before its `hello` goes, and `started`
/// is how many handshakes have started (#588).
actor FirstCallHeld {

    let release = AsyncSignal()
    private var count = 0

    /// How many calls have started.
    var started: Int { count }

    func hold() async {
        count += 1
        guard count == 1 else { return }
        try? await release.wait()
    }
}
