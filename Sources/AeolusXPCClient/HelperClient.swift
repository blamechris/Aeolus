import AeolusXPC
import FanKit
import Foundation

/// The client half of the privilege boundary: one connection to the helper, and typed
/// wrappers for every message that crosses it.
///
/// ## One connection, made when it is first needed
///
/// The connection is constructed lazily and there is at most one at a time. State is
/// therefore two things — the connection object, and the `HelloReply` negotiated on it —
/// and an actor owns both, because libxpc delivers its handlers on its own threads and
/// "has this connection handshaken" is read-then-acted-on by every message.
///
/// **One connect attempt per call, and no internal retry loop anywhere.** A client that
/// retried on its own would be hammering a mach name that launchd may be restarting a
/// daemon behind: a boot loop amplifier, where the thing making the helper slow to come up
/// is the client's own reconnect storm. Retrying is the caller's decision, at the caller's
/// cadence, with the caller's user watching.
///
/// ## It holds no fan state, and never re-acquires a lease
///
/// There is no cached snapshot here and no property that could serve one. `CLAUDE.md` rule
/// 6 forbids claiming control that nothing is honouring, and the way this client obeys it is
/// by having nothing stale to serve: an answer to `snapshot()` is a fresh round trip or it
/// is an error. Stale state is unrepresentable, not forbidden.
///
/// Reconnecting restores the **connection** and nothing else. A lease died with the process
/// that granted it, and `docs/ARCHITECTURE.md`'s wake section and
/// [ADR 0007](../../docs/ADR/0007-safety-composition.md) both rule that manual control is
/// never silently re-asserted: an unbidden write racing the firmware for control that was
/// just released is the "claims control it does not have" failure wearing a fix's clothes.
/// A client that still wants the fans asks again, deliberately, through the ordinary grant
/// path.
///
/// ## Interruption and invalidation are different events
///
/// **Interruption (4097)** means the helper process died and libxpc will reconnect this
/// same connection object to its replacement. The connection is kept and the `HelloReply`
/// is **discarded**: the peer is a new process, it has negotiated nothing with this client,
/// and anything the old one was holding is gone. The next message re-runs `hello`. The answer to
/// a `hello` sent before the interruption, and not yet recorded when it is handled, is never
/// recorded at all (#585, `performHandshake`). A handshake whose `hello` has not gone is kept
/// (#588). A 4097 on a message sent before the last notice counted is not counted either: the
/// counter counts notices, not interruptions, and that 4097 is a second notice of a death already
/// counted, or a notice of a later one whose interruption handler is still to come
/// (`translate(_:on:sentAfter:)`).
///
/// **Invalidation (4099)** means the connection will never work again. It is dropped, and
/// the next message builds a new one — once.
///
/// **`NSXPCConnectionReplyInvalid` (4101) is neither.** It is a failure of one *message* —
/// the reply could not be delivered — on a connection that is still alive and still
/// handshaken, and it is the one transport code here that does not cost the connection.
///
/// ## A connection this client gives up on is invalidated, never merely dropped
///
/// Every exit from a connection goes through one function, and that function calls
/// `invalidate()`. The helper releases a connection's leases from its listener's
/// invalidation handler, which fires only if somebody invalidates — so a client that just
/// dropped its reference would leave a root daemon holding manual control of the fans on
/// behalf of a caller that has gone, until a TTL `AeolusXPCProtocol` requires to be an
/// *independent* backstop rather than the mechanism. `disconnect()` is the same teardown
/// made available to a caller that is finished.
///
/// The connection is given up in **four** situations, and in none of them is anything
/// retried: libxpc reported it dead; the peer failed the code-signing requirement this
/// client pinned; a handshake did not produce a `HelloReply`; or the helper accepted a
/// message and did not answer within its deadline. `disconnect()` is a fifth, asked for
/// rather than forced. The deadline one is the wedged `io_connect_t` of `docs/SAFETY.md`
/// § 4, where leaving the connection in place would park every later gated verb behind a
/// message nothing can discard.
///
/// **Cancelling a caller is not one of them**, and the list is written out partly to make
/// that absence visible. A cancelled task says nothing about the helper, so it is reported
/// as a `CancellationError` and the connection — with every lease bound to it — is left
/// exactly as it was.
///
/// ## `hello` is never pipelined, and no client can negotiate that it may be
///
/// `AeolusXPCProtocol` permits a client to pipeline `hello` and `snapshot` on one
/// connection, because the helper answers a connection's messages in the order they were
/// sent (D25). This client does not use it, and the reason is worth stating so nobody
/// "fixes" it: the guarantee is **helper behaviour at an unchanged `AeolusXPCVersion`**, so
/// there is no version to check it against, and `HelloReply.capabilities` cannot license it
/// either — the capability string arrives *in the reply to the message that would have been
/// pipelined*, which is the round trip pipelining exists to skip. A capability is feature
/// discovery, never authorisation. So the only correct client-side rule is the one that is
/// safe against every helper: send `hello`, wait for it, then send everything else.
///
/// That holds across a restart too. An interruption keeps the generation, so the `hello` a caller
/// waited for may have been answered by the process that died while the replacement's is still
/// unanswered, and that caller sends nothing (#582, `handshakenConnection()`).
///
/// ## Why this file is still long, and where the split stops
///
/// This file is over SwiftLint's 400-line `file_length` warning and stays that way on
/// purpose: most of it is the reasoning around the code, and the rule counts comment lines.
/// Neither warning is suppressed — no `swiftlint:disable`, no `file_length` or
/// `type_body_length` override in `.swiftlint.yml` — because a file, or a body, that grew by
/// two hundred lines of *logic* should draw exactly the attention this one drew.
///
/// It drew it at 990 lines ([#600](https://github.com/blamechris/Aeolus/issues/600)): ten
/// under the 1000-line `file_length` error, which fails CI, with the actor's body at 246 of the
/// 250-line `type_body_length` warning, after #584, #587 and #599 had each moved code out only
/// to fit. [#242](https://github.com/blamechris/Aeolus/issues/242) had refused a split at the
/// 400-line warning, and [#237](https://github.com/blamechris/Aeolus/issues/237) before it:
/// Swift `private` is file-scoped, so every seam needs a member of this actor reachable from a
/// sibling file, and D36 is that stored state stays `private` and is mutated only from its
/// declaring file. Trading that for a warning's line count was the wrong side of the trade. An
/// error that fails CI is a different one, and #600 took the smallest split that clears it.
///
/// - **The verbs** left first, and that was the seam worth having. `HelperClientVerbs.swift`
///   holds all six, written over `withHandshakenProxy` and `withProxy`, and no verb touches this
///   client's state.
/// - **`translate(_:on:sentAfter:)`** moved to `HelperClient+Translation.swift`, as a move and
///   nothing else. It reads `hasEverHandshaken` and `interruptions` and writes neither, and
///   changes the connection only through `connectionWasInterrupted(_:)` and `discardConnection`.
///   So it cost three widenings: the two properties are `private(set)`, readable from a sibling
///   file and still written only here, and `discardConnection` — the single function that
///   invalidates the connection and moves the generation — is `internal`, with that file its one
///   caller outside this one.
/// - **The health signal** was the one slice that could own its state outright in a type of its
///   own, so it widened nothing. `HealthSignal` owns the value and the observers under a lock
///   (#541); `healthSignal` and `healthStreams` are `private`, the signal's publishing half is
///   not `Sendable`, so only this actor publishes, and `publish(_:)` stays here as the one way
///   the health changes, which `health` reads.
/// - **The connection's own lifecycle cannot leave this file**, and the compiler's ruling is part
///   of why. `exchange`, `liveConnection` and `handshakenConnection` each take or return
///   `ConnectionGeneration`, which is `private` and nested; widening one without widening that
///   type is *"method must be declared private because its parameter uses a private type"*. The
///   other part is D36's. The handshake (`handshakenConnection`, `performHandshake`) writes
///   `negotiatedReply`, `handshake` and `hasEverHandshaken`, and a sibling file that could write
///   them could mark a connection handshaken that negotiated nothing. Moving it would make three
///   of the nine properties `HelperClientAccessTests` holds writable from every file in
///   `AeolusXPCClient`, and that is a decision for a safety review, not a line count. It would
///   take about 190 lines with it.
///
/// **`HelperClientAccessTests` is what makes the decision keepable.** The lesson D36 exists
/// because of is #128's — a paragraph is not enforcement — and the paragraph above is held by
/// that suite: seven of the properties are `private`, two are `private(set)`, and the two
/// exhaustive halves beside them report a member that stops being private whether or not
/// anybody thought to list it, in every file the actor is written in.
public actor HelperClient {

    private let transport: HelperClientTransport
    private let pinning: any HelperConnectionPinning
    private let clientDescription: String
    private let deadlines: HelperClientDeadlines

    /// What each caller's handshake relay runs before it waits for the handshake: `nil`, so
    /// nothing, everywhere but the suite ([#582](https://github.com/blamechris/Aeolus/issues/582)).
    ///
    /// When a caller resumes from the handshake is the runtime's choice, and #582's two defects
    /// live in the schedules where it resumes late: after the helper that answered has died and
    /// another caller has started the next handshake. A test cannot ask the runtime for that
    /// schedule, so it holds one caller's relay here instead. The relay hands the handshake's
    /// outcome over only once this has returned, so holding it holds that one caller and nothing
    /// else: not the handshake, its deadline, or any other caller. It runs once the caller has
    /// joined the handshake in the slot or started one, so its running also tells a test that the
    /// caller has made that choice.
    private let handshakeRelayHold: (@Sendable () async -> Void)?

    /// What `exchange` runs once a `hello` has been answered, and before anything acts on the
    /// answer: `nil`, so nothing, everywhere but the suite
    /// ([#585](https://github.com/blamechris/Aeolus/issues/585)).
    ///
    /// A reply and the interruption that follows its helper's death are both queued on this actor,
    /// and which of them runs first is the executor's choice. #585's defect is the order in which
    /// the interruption runs first, and a test cannot ask the executor for it, so it holds the
    /// reply here while the helper dies. Holding it holds that one handshake and nothing else: the
    /// `hello` has been answered, so its deadline has ended, and the actor is free for the
    /// interruption.
    ///
    /// It holds a failure too, before `translate(_:on:sentAfter:)` reads it (#588): a 4097 there is
    /// a death notice as well as an answer, and #588's late notice is one of those.
    private let receivedHelloReplyHold: (@Sendable () async -> Void)?

    /// What a handshake runs before anything else, its guard included: `nil`, so nothing,
    /// everywhere but the suite ([#588](https://github.com/blamechris/Aeolus/issues/588)).
    ///
    /// A handshake's task runs once its caller has suspended, so a notice already queued on this
    /// actor can be handled before its `hello` goes. A test cannot ask the executor for that order,
    /// so it holds the task here. That holds one handshake whose `hello` has not gone, so no
    /// deadline runs for it, and leaves the actor free.
    private let handshakeStartHold: (@Sendable () async -> Void)?

    /// Every message in flight, and when each one's deadline starts: at its send, or for a
    /// message the helper sequences, when the sequenced messages sent before it have settled
    /// (#413). See `InFlightMessages`.
    private let inFlight: InFlightMessages

    private var connection: NSXPCConnection?
    private var negotiatedReply: HelloReply?

    /// The connection's handshake, which every caller that needs one shares, and whether its
    /// `hello` has gone.
    ///
    /// An interruption empties the slot only of a handshake whose `hello` has gone (#588). One that
    /// has not sent it sends it after the interruption, to a process that outlived the death, so
    /// the next caller joins it. Emptied, it let the next caller start a second handshake, which
    /// negotiated the session; the first `hello`, refused there, then took the connection with it.
    private var handshake: (task: Task<HelloReply, Error>, hasSent: Bool)?

    /// Whether a `hello` has ever succeeded on the **current connection object**, as
    /// distinct from whether one is in force now.
    ///
    /// It is what separates "the helper restarted" from "no helper ever answered", and it
    /// has to be separate from `negotiatedReply` because that is cleared by the very event
    /// being classified — libxpc fires the interruption handler on its own thread, so by the
    /// time a failed message is being explained, the reply may already be gone.
    ///
    /// `private(set)` since [#600](https://github.com/blamechris/Aeolus/issues/600):
    /// `translate(_:on:sentAfter:)`, in `HelperClient+Translation.swift`, decides on it, so its
    /// getter is readable there. Only this file writes it.
    private(set) var hasEverHandshaken = false

    /// How many death notices this actor has counted. It moves in `connectionWasInterrupted`, and
    /// nowhere else.
    ///
    /// Notices, not deaths: one death is the interruption handler's notice and a 4097 for each
    /// message in flight to it, and a 4097 on a message sent before the last notice counted is not
    /// counted (`translate(_:on:sentAfter:)`, #588). `exchange` reads this at every send for that.
    ///
    /// An interruption keeps the generation, so the generation cannot say whether the process that
    /// answered a `hello` is still the one on the other end. `performHandshake` reads this before
    /// it sends `hello`, and records the reply only if it has not moved since (#585).
    ///
    /// `private(set)` for `hasEverHandshaken`'s reason: `translate(_:on:sentAfter:)` reads it.
    private(set) var interruptions: UInt64 = 0

    /// The connection's health, and its observers, under a lock of their own (#541). Published to
    /// only by `publish(_:)`, on this actor. See `HealthSignal`.
    private let healthSignal: HealthSignal
    /// The half of `healthSignal` that only subscribes, which `healthUpdates()` reaches.
    private let healthStreams: HealthSignal.Streams

    /// Which connection object a handler is talking about.
    ///
    /// libxpc fires a dead connection's handlers on its own schedule, so one can arrive
    /// after this client has already given up on that connection and built another. Without
    /// this the late handler would tear down the live connection — a bug that only appears
    /// under the timing it is hardest to reproduce.
    ///
    /// It moves when a connection is built **and** when one is discarded, so that the
    /// handlers of a connection this client has abandoned — including the invalidation
    /// handler `discardConnection` fires itself — already name a past generation.
    private var generation: UInt64 = 0

    /// A connection, and **which** connection it is.
    ///
    /// The generation travels with the connection rather than being read back off the actor
    /// at the point of use, because what it identifies is exactly the thing that may have
    /// been replaced by the time it is read. `translate(_:on:sentAfter:)` is the case that made
    /// this a type: it runs when a message has *already* failed, which is precisely when a later
    /// connection may already be live and handshaken, and a bare `self.generation` there
    /// reduces `guard generation == self.generation` to `guard x == x` — a guard that reads
    /// as protection and holds nothing.
    private struct ConnectionGeneration {
        let connection: NSXPCConnection
        let generation: UInt64
    }

    /// - Parameters:
    ///   - transport: Where to look for the helper. `.machService` in production.
    ///   - pinning: How the connection acquires the requirement it pins on the helper. The
    ///     default is the only production policy there is; the suite substitutes its own,
    ///     which is why this is injected rather than reached for.
    ///   - clientDescription: What this client calls itself in the helper's log —
    ///     `Aeolus.app 0.3.0`, `fanctl`. Validated by the helper, which refuses rather than
    ///     repairs.
    ///   - deadlines: How long to wait for one message. Two of them are guesses and two are
    ///     derived from the helper's own bounds; see `HelperClientDeadlines`.
    public init(
        transport: HelperClientTransport = .machService,
        pinning: any HelperConnectionPinning = SignedHelperPinning(),
        clientDescription: String,
        deadlines: HelperClientDeadlines = .default
    ) {
        self.init(
            transport: transport,
            pinning: pinning,
            clientDescription: clientDescription,
            deadlines: deadlines,
            clock: ContinuousClock())
    }

    /// The same client, with the clock its deadlines are measured on named.
    ///
    /// `internal`, for the suite alone. A deadline is run out, or shown not to have run out, by
    /// moving a clock the test holds rather than by waiting for it: `apply`'s runs to nearly two
    /// minutes for two fans, and a deadline measured on the wall clock is one a stalled runner
    /// can run out for a client that did nothing wrong. Production has one clock and no way to
    /// name another.
    ///
    /// `holdingHandshakeRelays`, `holdingReceivedHelloReplies` and `holdingHandshakeStarts` are
    /// the suite's for the same reason, and production has no way to name any of them: the public
    /// initialiser leaves all three `nil` (`handshakeRelayHold`, `receivedHelloReplyHold`,
    /// `handshakeStartHold`).
    init(
        transport: HelperClientTransport,
        pinning: any HelperConnectionPinning,
        clientDescription: String,
        deadlines: HelperClientDeadlines,
        clock: any Clock<Duration>,
        holdingHandshakeRelays relayHold: (@Sendable () async -> Void)? = nil,
        holdingReceivedHelloReplies replyHold: (@Sendable () async -> Void)? = nil,
        holdingHandshakeStarts startHold: (@Sendable () async -> Void)? = nil
    ) {
        self.transport = transport
        self.pinning = pinning
        self.clientDescription = clientDescription
        self.deadlines = deadlines
        self.handshakeRelayHold = relayHold
        self.receivedHelloReplyHold = replyHold
        self.handshakeStartHold = startHold
        self.inFlight = InFlightMessages(clock: clock)
        let healthSignal = HealthSignal(startingWith: .idle)
        self.healthSignal = healthSignal
        self.healthStreams = healthSignal.streams
    }

    // MARK: - What a caller may ask about the connection

    /// The helper's answer to the handshake currently in force, or `nil` when nothing has
    /// been negotiated.
    ///
    /// Cleared by interruption as well as by invalidation: after the helper is replaced,
    /// the build string and the capabilities in hand describe a process that no longer
    /// exists.
    public var negotiated: HelloReply? { negotiatedReply }

    /// The connection's health right now. See `HelperConnectionHealth` — this is ADR 0006's
    /// switch for the app.
    public var health: HelperConnectionHealth { healthSignal.current }

    /// Which connection this client is on, for a suite that has to name one.
    ///
    /// `internal`, like `translate(_:on:sentAfter:)` and the two handlers, and for the same reason:
    /// the generation is the parameter every one of those guards turns on, so a test that
    /// could not name it could only assert them by accident. Nothing outside this module
    /// can see it and nothing inside it reads it except the guards themselves.
    var currentGeneration: UInt64 { generation }

    /// How many messages have a deadline running, for a suite that moves a hand-wound clock.
    ///
    /// `internal`, like `currentGeneration`, and for the suite alone. A deadline's instant is read
    /// when its timer first runs (`InFlightMessages`), so a test may move the clock only once every
    /// running deadline has parked on it, and only this count says how many that is. It also
    /// states the claim the sequenced deadlines turn on directly: behind a held `apply`, one
    /// deadline is running, not two.
    var deadlinesRunning: Int { inFlight.running }

    /// The same signal as a stream, for a client that renders it rather than polls it.
    ///
    /// Yields the current value immediately on subscription, so a subscriber never has to
    /// combine a first read with a stream to know where it stands. Buffers unboundedly by
    /// default and the values are seven cases, so a slow consumer costs nothing that matters.
    ///
    /// **A stream that ends leaves**, whether it ends at once or after a long read. The
    /// observer is registered in the step that makes the stream and removed in the step that ends
    /// it, both under `HealthSignal`'s lock, with no task between (#541). `LeaseDriver`
    /// subscribes once per lease and ends the subscription with the lease, so an observer left
    /// behind would be one per short lease.
    ///
    /// Before #541 the registration and the removal were each a task, because this function is
    /// `nonisolated` and the observers were the actor's. Two tasks reach the actor in no set
    /// order, so a stream that ended before its registration ran left an observer that nothing
    /// would take away (#532), and #533 made the removal wait for the registration. Now there is
    /// no task, and no order to keep.
    ///
    /// Nothing a stream holds reaches this client: its termination handler holds the observers
    /// weakly, and nothing else. A strong reference to this client there would be a retain cycle
    /// that kept a connection-owning actor alive for as long as anyone forgot to end the stream.
    /// `HelperClientHealthStreamTests` frees a client whose health stream is still open.
    nonisolated public func healthUpdates() -> AsyncStream<HelperConnectionHealth> {
        healthStreams.updates()
    }

    // MARK: - The two gates

    /// Runs one message on a connection whose `hello` has succeeded, handshaking first if
    /// this connection object has not.
    ///
    /// **Every gated verb goes through here, and there is exactly one of these.** A verb
    /// that reached the proxy another way would be refused with `handshakeRequired` on a
    /// fresh connection and would look, from the outside, like the helper misbehaving.
    ///
    /// The handshake is a shared `Task` rather than a plain flag, so that two verbs racing
    /// on a cold connection produce **one** `hello` and both wait for it. The second `hello`
    /// on a connection is refused by the helper — a connection has one negotiated identity —
    /// so "whoever gets there second loses" would be a race a correct caller could not avoid.
    /// Each waits through a latch of its own, so a caller that is cancelled leaves at once and
    /// the handshake carries on for the rest (#576; `handshakenConnection()`).
    ///
    /// `deadline` picks the message's bound out of this client's deadlines, which stay private
    /// to this file: a verb says which bound it needs and never holds the deadlines itself.
    /// Every verb but `apply` takes `gatedVerb`; `apply` takes its own, which grows with the
    /// fans it names (`HelperClientDeadlines.applyDeadline(naming:)`).
    ///
    /// `message` is the message `send` sends, and it decides when that bound starts to run: at
    /// the send, or for a message the helper sequences, once the sequenced messages sent before
    /// it have settled (`HelperMessage.sequenced`, #413).
    func withHandshakenProxy<Answer: Sendable>(
        _ message: HelperMessage,
        within deadline: (HelperClientDeadlines) -> Duration = { $0.gatedVerb },
        _ send: (any AeolusXPCProtocol, @escaping @Sendable (Result<Answer, Error>) -> Void) -> Void
    ) async throws -> Answer {
        let live = try await handshakenConnection()
        return try await exchange(message, on: live, within: deadline(deadlines), send)
    }

    /// Runs one message on a live connection **without** a handshake.
    ///
    /// `restoreAllToAutomatic` is the only caller, permanently, and
    /// `HelperClientSeamTests.theUnhandshakenProxyHasExactlyOneCaller` is what keeps that
    /// true: it counts the occurrences of this function's name in this target's sources and
    /// requires exactly two — this declaration and that one call. A second caller would be a
    /// verb quietly exempting itself from the gate on the client's side of a boundary whose
    /// whole design is that gates are not optional.
    ///
    /// `message` is named for the reason the other gate's is, and it is always
    /// `.restoreAllToAutomatic`, which the helper never sequences: the panic path's deadline
    /// starts at its send and waits for nothing sent before it.
    func withProxy(
        _ message: HelperMessage,
        _ send: (any AeolusXPCProtocol, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void
    ) async throws {
        let live = try liveConnection()
        try await exchange(message, on: live, within: deadlines.panicVerb, send)
    }

    // MARK: - The connection

    /// The current connection, or a new one — constructed, pinned, wired and resumed.
    ///
    /// The order is the helper delegate's order and for the same reason: the requirement is
    /// applied before the connection is resumed, and both handlers are attached before it
    /// too, so a connection that dies between being configured and being resumed still has
    /// somewhere to report it.
    private func liveConnection() throws -> ConnectionGeneration {
        if let connection {
            return ConnectionGeneration(connection: connection, generation: generation)
        }

        // Pinning first: it throws before a connection object exists, so a client that
        // cannot verify the helper has nothing to resume by accident.
        //
        // The refusal is published as well as thrown. `clientCannotVerifyHelper` is the
        // ordinary outcome of every `Monitor` build and every unsigned `fanctl`, so it is
        // the condition this client can diagnose most confidently — and leaving the signal
        // at `.idle` would render the case it is surest about as "nothing has been tried".
        let connection: NSXPCConnection
        do {
            connection = try pinning.pinnedConnection(over: transport)
        } catch {
            publish(.refused)
            throw error
        }
        connection.remoteObjectInterface = NSXPCInterface(with: AeolusXPCProtocol.self)

        generation &+= 1
        let generation = self.generation
        connection.interruptionHandler = { [weak self] in
            Task { await self?.connectionWasInterrupted(generation) }
        }
        connection.invalidationHandler = { [weak self] in
            Task { await self?.connectionWasInvalidated(generation) }
        }

        connection.resume()
        self.connection = connection
        hasEverHandshaken = false
        publish(.idle)
        return ConnectionGeneration(connection: connection, generation: generation)
    }

    /// The current connection, with `hello` completed on it.
    ///
    /// ## A caller waits for the handshake; it does not own it
    ///
    /// The handshake is the connection's, and a caller only waits for it. Each caller waits
    /// through a `PendingReply` of its own, which the handshake's outcome is relayed into, so a
    /// cancelled caller is answered at once with `CancellationError` and nothing else moves: the
    /// handshake runs on, `handshake` still names it, and a caller that arrives next joins it.
    /// Awaiting the shared task's `value` directly, as this did until
    /// [#576](https://github.com/blamechris/Aeolus/issues/576), is a wait cancellation cannot
    /// reach, because the task is nobody's child: a cancelled caller stayed parked until the
    /// `hello` was answered or ran out its `handshakeVerb` deadline.
    ///
    /// **A cancelled caller leaves `handshake` in place**, because the `hello` it names may still
    /// be in flight. Clearing it would let the next caller send a second `hello` on this
    /// connection, which the helper refuses, and a refused handshake takes its connection with it
    /// (`performHandshake`): a teardown caused by a caller going away, which
    /// `translate(_:on:sentAfter:)` refuses to allow for every other message. Only a caller handed
    /// the handshake's own outcome clears it, and only while the slot still names that handshake
    /// (below).
    ///
    /// **When the last waiter goes, the handshake still runs**, to its answer or to its own
    /// deadline, as if someone were waiting. Cancelling it instead would end it without a
    /// `HelloReply` on a connection whose peer may have recorded the `hello`, which costs the
    /// connection: the same teardown by another door. So a handshake nobody waits for any more
    /// leaves the connection handshaken for the next caller, or fails and takes it, exactly as it
    /// would have with a caller there. Each relay ends when the handshake does, and the handshake
    /// is bounded by its `hello`'s own deadline (`handshakeVerb`, counted from the `hello`'s turn,
    /// `InFlightMessages`), so no relay outlives that deadline.
    ///
    /// ## A caller that resumes after its helper died
    ///
    /// An interruption keeps the connection and its generation and empties the slot of a
    /// handshake whose `hello` has gone, so the next caller starts a second handshake on the same
    /// connection, for the process that replaced the one that died. A handshake whose `hello` has
    /// not gone stays in the slot, and the next caller joins it (`handshake`,
    /// [#588](https://github.com/blamechris/Aeolus/issues/588)). A caller of the first handshake
    /// can resume after the second has started, because when a caller resumes is the runtime's
    /// choice. Two rules hold for it ([#582](https://github.com/blamechris/Aeolus/issues/582)).
    ///
    /// **It clears the slot only of its own handshake**, compared by identity (`Task` is
    /// `Equatable` on the task, not on its result). Comparing generations, as this did before,
    /// cleared the second handshake, which shares the first one's generation, and the next caller
    /// then sent a third `hello` on the connection: refused, so the connection went with it, and
    /// every caller of the second handshake was told `connectionAbandoned`.
    ///
    /// **It sends nothing, and is told `helperRestarted`.** Its handshake succeeded, on the
    /// process that died, and nothing is negotiated with the new one until the second handshake
    /// is answered. Sending now would put its verb behind a `hello` that is not answered yet,
    /// which is the pipelining this client never does. Nor does it wait for the second handshake:
    /// that would be a second attempt at the handshake this call has already had, and nothing on
    /// the send path makes one (`HelperClientSendPathSeamTests`); whether to ask again is the
    /// caller's. So it is answered as a message in flight across the same restart is answered, and
    /// for the same reason: the helper it reached is gone. A caller that resumes once the second
    /// handshake has been answered finds it in force and sends on it, like any caller after a
    /// restart. The check is at this handshake's generation only; a connection given up in the
    /// meantime is `exchange`'s to report, as `connectionAbandoned`.
    private func handshakenConnection() async throws -> ConnectionGeneration {
        let live = try liveConnection()
        if negotiatedReply != nil { return live }

        let generation = live.generation
        let task =
            handshake?.task ?? Task { try await self.performHandshake(generation: generation) }
        if handshake == nil { handshake = (task, hasSent: false) }
        // `nil` is this caller's cancellation: the latch has no deadline, the handshake has.
        let waiter = PendingReply<Result<HelloReply, Error>?>(ifNothingArrives: nil)
        Task.detached(priority: Task.currentPriority) { [hold = handshakeRelayHold] in
            await hold?()
            waiter.deliver(await task.result)
        }
        guard let outcome = await waiter.waitForAnswer() else { throw CancellationError() }
        if handshake?.task == task { handshake = nil }
        _ = try outcome.get()
        // The helper that answered died before this caller resumed: see above.
        if self.generation == generation, negotiatedReply == nil {
            throw HelperClientError.helperRestarted
        }

        // The connection this handshake ran on, not whatever is current now. If this client
        // gave it up in between — a `disconnect()`, or another message's cut-off, both of which
        // can run while this one waits to resume — `exchange` refuses to send on it and says
        // so. There is no second attempt here.
        return live
    }

    /// Sends `hello` and records what came back, or leaves no connection behind.
    ///
    /// ## A handshake that produced no `HelloReply` takes its connection with it
    ///
    /// `HelperConnectionSession` refuses a **second** `hello` on a connection for that
    /// connection's whole life — a connection has one negotiated identity — so a handshake
    /// that failed after the helper had already answered leaves an object on which no later
    /// gated verb can ever succeed: each one finds `negotiatedReply == nil`, sends `hello`
    /// again, and is refused with `invalidParameter` forever. `releaseLease` is gated, so a
    /// client in that state cannot even hand a lease back, and the TTL — which ADR 0005
    /// requires to be an *independent* backstop — becomes the only thing that ends it.
    ///
    /// So the rule is unconditional: no `HelloReply`, no reusable connection. It is
    /// **teardown, not a retry** — nothing here sends a second `hello` and nothing here
    /// reconnects. The caller still has to ask again, at its own cadence, and the reason
    /// that stays true is the one `HelperClient`'s own documentation gives: a client that
    /// retried into a mach name launchd is restarting a daemon behind is a boot-loop
    /// amplifier.
    ///
    /// It applies to an **interrupted** handshake too, which narrows the general rule that
    /// 4097 keeps its connection object. That rule is about a connection libxpc will
    /// reconnect to a replacement peer, and it still holds for every gated verb; a `hello`
    /// is the one message whose failure this client cannot classify from the outside —
    /// whether the peer recorded it is the peer's state, not the transport's — so the
    /// handshake path spends one extra connection setup rather than reasoning about it.
    ///
    /// ## Unless a newer handshake has been recorded on it since
    ///
    /// An interruption empties the slot of a handshake whose `hello` has gone, so a second one can
    /// be recorded, with the replacement, while the first waits for its answer (#588). The first
    /// then fails against the process that died, when the late 4097 for its `hello` arrives, and
    /// taking the connection then took a live, handshaken one, with any lease the helper held on
    /// it. So a reply recorded at its generation keeps the connection. It is necessarily a newer
    /// handshake's: one starts only with none recorded, and one cleared from the slot by an
    /// interruption cannot record its own, because the interruption moved `interruptions`.
    ///
    /// ## A reply from a process that died before it was recorded is not recorded
    ///
    /// If the helper answers `hello` and then dies, its reply and the interruption are both queued
    /// on this actor, and the executor picks which runs first. When the interruption runs first it
    /// clears a reply that has not been recorded yet. Recording it afterwards claimed a handshake
    /// with a process that is gone: `.handshaken` published, `negotiated` naming the dead process,
    /// and every gated verb after it sent to the replacement with no `hello` and refused
    /// `handshakeRequired`. A refusal tears nothing down, so nothing ended that
    /// ([#585](https://github.com/blamechris/Aeolus/issues/585)).
    ///
    /// So the reply is recorded only if no interruption has been handled since the `hello` was
    /// sent (`interruptions`). It is read in the same synchronous stretch as the send, so an
    /// interruption handled before the send does not count. Otherwise the callers are told
    /// `helperRestarted` (`handshakenConnection()`), and the next caller handshakes with the
    /// replacement on the same connection. `hasEverHandshaken` is set either way, because a helper
    /// did answer: a 4097 on this connection is then a restart, as it is when the reply was
    /// recorded before the death.
    ///
    /// **That costs a failure of its own, which #585 introduced.** The count cannot tell a notice
    /// of a death after the send from a late first notice of one before it, which reached this
    /// actor after the `hello` had gone to the replacement. That reply is dropped too, where
    /// before #585 it was recorded. The first caller is told `helperRestarted`. The next caller's
    /// `hello` is refused by the replacement, which negotiated the first, and the refusal takes
    /// the connection (above). The call after that is served on a new one. That is two failed
    /// calls and one reconnect, and no lease lost, because nothing was negotiated for one to be
    /// acquired over. The trade is right: this window cannot be told from #585's, and recording
    /// in #585's is the wedge above, which nothing ends. `HelperClientStaleHandshakeTests` runs the
    /// recovery. Since #588, a second notice of a death already counted no longer reaches this
    /// window (`translate(_:on:sentAfter:)`). A late first notice still does.
    private func performHandshake(generation: UInt64) async throws -> HelloReply {
        await handshakeStartHold?()
        guard generation == self.generation, let connection else {
            throw HelperClientError.helperUnreachable(code: XPCTransportCode.invalid)
        }
        let live = ConnectionGeneration(connection: connection, generation: generation)
        let request = try HelperClientPayload.hello(describing: clientDescription)
        // The slot names this handshake: it was stored as it was made, and only a discard, which
        // the guard rules out, empties it of one whose `hello` has not gone. The send is next.
        handshake?.hasSent = true
        let interruptions = self.interruptions
        do {
            let data: Data = try await exchange(
                .hello, on: live, within: deadlines.handshakeVerb
            ) { proxy, resolve in
                proxy.hello(request: request) { data, error in
                    resolve(HelperClientPayload.outcome(data, error))
                }
            }
            let reply = try HelperClientPayload.decode(HelloReply.self, from: data)

            // Discarded rather than stored if the connection was replaced while this was in
            // flight: a `HelloReply` describes one process, and attaching it to a connection
            // that did not negotiate it would be a claim about a peer nobody spoke to.
            guard generation == self.generation else { return reply }
            hasEverHandshaken = true
            // Nor if the process that answered may have died since: see above.
            guard interruptions == self.interruptions else { return reply }
            negotiatedReply = reply
            publish(.handshaken)
            return reply
        } catch {
            // Still held at this generation means nothing above tore it down — the peer
            // answered `hello`, or refused it, on a session that may now have recorded the
            // handshake. See this function's own documentation for why that is fatal to the
            // connection rather than to the message, and why a newer reply recorded is not.
            if generation == self.generation, self.connection != nil, negotiatedReply == nil {
                let health = HelperConnectionHealth.afterFailedHandshake(for: error)
                discardConnection(generation, as: health, answering: .connectionAbandoned)
            }
            throw error
        }
    }

    /// Sends one message, and answers with whichever of the reply block, the connection's
    /// error handler and the deadline arrives first.
    ///
    /// `remoteObjectProxyWithErrorHandler(_:)` and never bare `remoteObjectProxy`: when the
    /// connection itself fails, the block passed with the message is simply dropped and only
    /// this handler runs, so a client whose failure path lives only in the reply block has no
    /// failure path for the case that matters most.
    ///
    /// **Nothing is sent on a connection this client has already given up.** `live` is read
    /// before a caller's last suspension, and a handshake waiter resumes after one: a discard can
    /// land in between. Sent anyway, the message would reach a connection the client invalidated,
    /// and its 4099 would read as a helper that is not installed. The check and the send are one
    /// synchronous stretch on this actor, so nothing can move the generation between them.
    ///
    /// **The deadline belongs to the message, not to this wait.** `inFlight` starts it when the
    /// message's turn comes and ends it when the message settles, which `sent.settle` does from
    /// both blocks below.
    /// A caller cancelled here leaves the message in flight with its deadline still running,
    /// because the messages behind it are waiting for it to settle; see `InFlightMessages`.
    ///
    /// **The notices counted before the send travel with the message** (#588), read in the same
    /// synchronous stretch as the send, as the generation is: see `translate(_:on:sentAfter:)`.
    private func exchange<Answer: Sendable>(
        _ message: HelperMessage,
        on live: ConnectionGeneration,
        within deadline: Duration,
        _ send: (any AeolusXPCProtocol, @escaping @Sendable (Result<Answer, Error>) -> Void) ->
            Void
    ) async throws -> Answer {
        guard live.generation == generation else { throw HelperClientError.connectionAbandoned }
        // The latch it is answered through, with its two fallbacks, is the message's too.
        let sent = inFlight.admit(
            message, on: live.generation, within: deadline, answering: Answer.self)
        let notices = interruptions
        let proxy = live.connection.remoteObjectProxyWithErrorHandler { sent.settle(.failure($0)) }
        guard let typed = proxy as? any AeolusXPCProtocol else {
            throw sent.failing(
                with: HelperClientError.protocolViolation(
                    detail: "the connection vended a proxy that does not speak this protocol"))
        }
        send(typed, sent.settle)

        let outcome = await sent.answer()
        if message == .hello { await receivedHelloReplyHold?() }
        switch outcome {
        case .success(let answer):
            return answer
        case .failure(let error):
            throw translate(error, on: live.generation, sentAfter: notices)
        }
    }

    // MARK: - Giving up on a connection

    /// The helper process was replaced. Keep the connection, drop what the old one said.
    ///
    /// It is counted too, so that the reply to a `hello` sent before it, which the old process may
    /// have sent, is not recorded after it (`interruptions`, #585).
    ///
    /// It empties the slot only of a handshake whose `hello` has gone (`handshake`, #588).
    ///
    /// Reachable from the suite rather than `private`, because this and
    /// `connectionWasInvalidated` are **libxpc's entry points into this actor** and the
    /// interleaving `generation` exists to survive — a dead connection's handler arriving
    /// after its replacement is already live and handshaken — is not one a test can provoke
    /// on demand over a real connection. `HelperClientConnectionTests` plays libxpc instead.
    func connectionWasInterrupted(_ generation: UInt64) {
        guard generation == self.generation else { return }
        interruptions &+= 1
        negotiatedReply = nil
        if handshake?.hasSent == true { handshake = nil }
        publish(.interrupted)
    }

    /// The connection is dead. The next message builds another one — once.
    ///
    /// Anything still in flight on it is answered `helperUnreachable(code: 4099)`, which is what
    /// libxpc reports for a dead connection's messages, and is usually what each has been told
    /// already by its own error handler. Usually, not always: the order in which libxpc runs a
    /// connection's error handlers and its invalidation handler is libxpc's, and after a 4102
    /// signing failure the first answer to reach a message is the one it keeps.
    /// `HelperClientConnectionTests.aPeerThatFailsTheRequirementIsNamedAsSuch` is what holds the
    /// 4102 case to `helperSignatureRejected` in practice.
    func connectionWasInvalidated(_ generation: UInt64) {
        let invalid = HelperClientError.helperUnreachable(code: XPCTransportCode.invalid)
        discardConnection(generation, as: .invalidated, answering: invalid)
    }

    /// Tears this client's connection down, and forgets everything negotiated on it.
    ///
    /// The teardown a client owes the helper when it is finished with it. A connection
    /// going away is the **primary** way a lease ends — `AeolusXPCProtocol` makes the 120 s
    /// TTL an independent backstop rather than the mechanism — and a client that merely
    /// stopped calling would hold the helper's session, and any lease on it, for the whole
    /// of that TTL.
    ///
    /// It acquires nothing and releases nothing of its own. A lease this client still holds
    /// dies with the connection, exactly as it does when the helper restarts, and is never
    /// re-acquired: `docs/ARCHITECTURE.md`'s wake section and ADR 0007 both rule that manual
    /// control is not silently re-asserted. The next call builds a new connection and
    /// handshakes it, as it would from cold; calling this with no connection open does
    /// nothing.
    ///
    /// The guard is what makes that last clause true, and it is load-bearing rather than an
    /// optimisation: without it, tearing down a client that had **refused to pin** — the
    /// ordinary outcome for an unsigned `fanctl` — moved its health from `.refused` to
    /// `.idle` and threw away the one diagnosis this client can give with confidence. That
    /// is the same erasure `liveConnection()` publishes `.refused` to prevent.
    ///
    /// A message still in flight when this is called is answered `connectionAbandoned`: the
    /// client gave the connection up before the helper answered, and nothing else is known.
    public func disconnect() {
        guard connection != nil else { return }
        discardConnection(generation, as: .idle, answering: .connectionAbandoned)
    }

    /// Gives up on a connection: **invalidates** it, drops it, and forgets what it
    /// negotiated.
    ///
    /// The invalidation is the load-bearing half and it is why this is one function rather
    /// than a line repeated at each exit. The helper releases a connection's leases from its
    /// listener's invalidation handler, which fires only if somebody invalidates; a client
    /// that dropped its reference and left the object alive would leave a root daemon
    /// holding manual control of the fans for a caller that has gone, until a TTL that is
    /// supposed to be the backstop rather than the mechanism.
    ///
    /// The generation moves here as well as at construction. That is what makes the dying
    /// connection's own handlers — including the invalidation handler this call is about to
    /// fire — name a generation that is already past, so they are ignored instead of
    /// tearing down whatever has been built since.
    ///
    /// **Every message still in flight on it is answered `verdict` first** (#413). The
    /// `invalidate()` below reaches each of them as 4099, and `translate(_:on:sentAfter:)` reads a
    /// 4099 as a helper that is not installed or not yet approved — so a message this client killed
    /// itself, answered by its own invalidation, would be misdiagnosed. Each caller says what
    /// is true instead: `connectionAbandoned` when the client chose to give up, and the
    /// transport's own verdict when the transport ended the connection. Answering them settles
    /// them too, so no message stays waiting for a turn on a connection that is gone.
    ///
    /// `internal` since [#600](https://github.com/blamechris/Aeolus/issues/600), for
    /// `translate(_:on:sentAfter:)` in `HelperClient+Translation.swift`, which is its one caller
    /// outside this file.
    func discardConnection(
        _ generation: UInt64, as health: HelperConnectionHealth,
        answering verdict: HelperClientError
    ) {
        guard generation == self.generation else { return }
        let dying = connection
        self.generation &+= 1
        connection = nil
        negotiatedReply = nil
        handshake = nil
        hasEverHandshaken = false
        publish(health)
        inFlight.abandonAll(on: generation, answering: verdict)
        dying?.invalidate()
    }

    // MARK: - The health signal

    /// The one way this client's health changes, and only ever on this actor.
    private func publish(_ health: HelperConnectionHealth) {
        healthSignal.publish(health)
    }

}
