/// The seven messages of `AeolusXPCProtocol`, as this client names the one it is sending.
///
/// Each raw value is the protocol's own method name, so a name here can be read against the
/// helper's dispatch of the same message without a translation table between them.
///
/// Every send names its message at its gate — `withHandshakenProxy(.snapshot) { … }` — because
/// the message decides when its deadline starts (`InFlightMessages`), and the gate cannot tell a
/// `snapshot` from a heartbeat by looking at the closure it was handed.
/// `HelperClientSequencingCensusTests` holds each tag to the message its closure actually sends.
enum HelperMessage: String, CaseIterable, Sendable {
    case hello
    case snapshot
    case acquireLease
    case renewLease
    case releaseLease
    case apply
    case restoreAllToAutomatic

    /// The messages the helper answers **in the order they were sent** on one connection: D25,
    /// the four `HelperXPCService` hands to its `MessageSequencer`.
    ///
    /// This is a copy, and the helper's membership is the original. The client cannot link the
    /// daemon to read it, so `HelperClientSequencingCensusTests` imports both and fails the moment
    /// this list and the helper's routes disagree, the way
    /// `HelperClientDeadlineTests.theApplyDeadlineIsDerivedFromTheHelpersOwnBounds` holds
    /// `HelperClientDeadlines.applyPerFan` to the helper's bounds.
    ///
    /// What being on it changes is when the message's deadline starts. A sequenced message waits
    /// at the helper for every sequenced message sent before it on its connection, so its deadline
    /// starts when those have settled, not at its send. The other three — the panic path and the
    /// two lease verbs ([#229](https://github.com/blamechris/Aeolus/issues/229)) — are dispatched
    /// the moment they arrive, so theirs starts at their send.
    ///
    /// **The two wrong directions cost different things.** A sequenced message missing from this
    /// list starts its deadline at its send again, which is
    /// [#413](https://github.com/blamechris/Aeolus/issues/413): cut off behind a lawful `apply`,
    /// with the connection and its lease ending for a helper that was inside its contract. An
    /// unsequenced message added to it waits for messages it does not wait for at the helper, so
    /// a heartbeat behind a wedged `apply` is not cut off until that `apply`'s deadline has run
    /// as well, and `CLAUDE.md` rule 6's "control lost" arrives late.
    static let sequenced: Set<HelperMessage> = [.hello, .snapshot, .acquireLease, .apply]

    /// Whether the helper answers this message in the order it was sent. See `sequenced`.
    var isSequenced: Bool { Self.sequenced.contains(self) }
}
