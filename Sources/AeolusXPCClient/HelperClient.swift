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
/// and anything the old one was holding is gone. The next message re-runs `hello`.
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
/// ## Why this is one long file, and where the split stops
///
/// This file is over SwiftLint's 400-line `file_length` warning and stays that way on
/// purpose. **242 of its lines are code**; the rest is the reasoning around them, and the
/// rule counts comment lines. Seventeen were added after this section was written: the clock the
/// deadlines are measured on, the `internal` initialiser that names it, and the gate's choice of
/// deadline (#325). Nine more are the message each send names, the answer a discard gives what
/// was still in flight, the refusal to send on a connection already given up, and the suite's
/// count of running deadlines (#413); the bookkeeping behind them is `InFlightMessages`, which
/// owns its state outright and so widens nothing here. Three more made a health stream's
/// removal wait for its registration (#532), and put the actor's body at 253 lines, three over
/// SwiftLint's 250-line `type_body_length` warning. That took the file to 258 code lines. #541
/// then gave the health signal's state a type of its own (`HealthSignal`, below), which took the
/// file to 239 and the actor's body to 234. Three more are the latch a caller waiting on the
/// handshake is cancelled out of (#576), which took them to 242 and 237. The count of code
/// lines in the file, 229 when this section was written, did not move when the section was
/// added — the file grew by fifty-odd lines and by none of the thing the threshold is worth
/// measuring, which is the whole argument in one measurement. Neither warning is suppressed,
/// deliberately — no `swiftlint:disable`, no `file_length` or `type_body_length` override in
/// `.swiftlint.yml` — because a file, or a body, that grew by two hundred lines of *logic*
/// should draw exactly the attention this one drew.
///
/// The split was evaluated on [#242](https://github.com/blamechris/Aeolus/issues/242) and
/// refused. Swift `private` is file-scoped, so every remaining seam needs a member of this
/// actor reachable from a sibling file — and D36 is that stored state stays `private` and is
/// mutated only from its declaring file, while only what a sibling *must* call widens to
/// `internal`. Trading that for a line count is the wrong side of the trade anywhere, and
/// this is the privilege boundary, which is why #237 declined it too. What was weighed:
///
/// - **The verbs are already gone**, and that was the seam worth having.
///   `HelperClientVerbs.swift` holds all six, written over `withHandshakenProxy` and
///   `withProxy`, and no verb touches this client's state. Its own comment records that it
///   was split along a seam rather than along a line count.
/// - **`translate(_:on:)` and the transport mapping** would move eighty-odd lines and need
///   `hasEverHandshaken` widened — a stored input one arm of it decides on — and
///   `discardConnection` with it, which is the single function that invalidates the
///   connection and moves the generation. Reshaping it to return a verdict the actor then
///   applies splits the classification from its consequence, which its own comment treats as
///   one thing, and writes more lines into a new file than it takes out of this one.
/// - **The connection's own lifecycle cannot leave this file at all**, and that is the
///   compiler's ruling rather than a rule anybody chose. `exchange`, `liveConnection` and
///   `handshakenConnection` each take or return `ConnectionGeneration`, which is `private`
///   and nested; widening one without widening that type is *"method must be declared
///   private because its parameter uses a private type"*. Anything built on those three
///   stays here, so a split would have to start by publishing the type whose whole purpose
///   is that a generation travels with its connection instead of being read back off the
///   actor. `HelperClientAccessTests` records the attempt.
/// - **The health signal** — `currentHealth`, `observers`, `publish`, `observe`,
///   `stopObserving` — was the one slice that could own its state outright in a type of its
///   own rather than borrowing this actor's, so it was the one that would widen nothing. When
///   this was written (#268) it was worth about twenty-five lines, against a file of 665 lines,
///   some 265 past the 400-line `file_length` warning, in exchange for an indirection on the
///   path that reports whether this client can see the helper at all. Not worth doing for a
///   line count; worth reconsidering on its own merits if the signal grows.
///
///   It grew by three lines in #532, which made a stream's removal wait for its registration.
///   #534 noted that the growth went unremarked here; it did not take the split question up.
///   Those three lines existed because `observers` was this actor's state and
///   `healthUpdates()`, which registers and removes observers, is `nonisolated`, so each reached
///   it through a task, and two tasks reach the actor in no set order. That was the merit, and
///   #541 took it: `HealthSignal` owns the value now and the observers under a lock, so a
///   stream registers in its builder and leaves in its termination handler, both synchronously,
///   and the race the three lines ordered cannot happen. The indirection is the cost #268
///   weighed, paid for the race rather than for a line count. It widened nothing:
///   `healthSignal` and `healthStreams` are `private`, held so by `HelperClientAccessTests`; the
///   signal's publishing half is not `Sendable`, so only this actor publishes; and `publish(_:)`
///   stays here as the one way the health changes, which `health` reads.
///
/// The threshold is not this file's problem in particular either. Over thirty files in the tree
/// are past it, ten-odd of them under `Sources`, and **four of those are longer than this
/// one** — `ReclamationWatchdog` at 980, `LeaseAuthority` at 884, `SMCConnection` at 813 and
/// `SMCReadScheduler` at 679. Those four are the argument; the tally is left approximate on
/// purpose, because it moves on merges that have nothing to do with this file — it went up by
/// one, in `AeolusXPC`, between this section being written and the branch being brought up to
/// date. Splitting whichever file a review round happened to open, at the cost of the access
/// rule, buys a tidier number and a wider gate.
///
/// **`HelperClientAccessTests` is what makes the decision keepable.** The lesson D36 exists
/// because of is #128's — a paragraph is not enforcement — and until #242 nothing asserted
/// access anywhere in this target, so a later split could have widened every property named
/// above with the whole suite green. Each is now held `private` by a test, and the two
/// exhaustive halves beside it report a member that stops being private whether or not
/// anybody thought to list it.
public actor HelperClient {

    private let transport: HelperClientTransport
    private let pinning: any HelperConnectionPinning
    private let clientDescription: String
    private let deadlines: HelperClientDeadlines

    /// Every message in flight, and when each one's deadline starts: at its send, or for a
    /// message the helper sequences, when the sequenced messages sent before it have settled
    /// (#413). See `InFlightMessages`.
    private let inFlight: InFlightMessages

    private var connection: NSXPCConnection?
    private var negotiatedReply: HelloReply?
    private var handshake: Task<HelloReply, Error>?

    /// Whether a `hello` has ever succeeded on the **current connection object**, as
    /// distinct from whether one is in force now.
    ///
    /// It is what separates "the helper restarted" from "no helper ever answered", and it
    /// has to be separate from `negotiatedReply` because that is cleared by the very event
    /// being classified — libxpc fires the interruption handler on its own thread, so by the
    /// time a failed message is being explained, the reply may already be gone.
    private var hasEverHandshaken = false

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
    /// been replaced by the time it is read. `translate(_:on:)` is the case that made this a
    /// type: it runs when a message has *already* failed, which is precisely when a later
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
    init(
        transport: HelperClientTransport,
        pinning: any HelperConnectionPinning,
        clientDescription: String,
        deadlines: HelperClientDeadlines,
        clock: any Clock<Duration>
    ) {
        self.transport = transport
        self.pinning = pinning
        self.clientDescription = clientDescription
        self.deadlines = deadlines
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
    /// `internal`, like `translate(_:on:)` and the two handlers, and for the same reason:
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
    /// (`performHandshake`): a teardown caused by a caller going away, which `translate(_:on:)`
    /// refuses to allow for every other message. Only a caller handed the handshake's own outcome
    /// clears it, exactly as every caller did before.
    ///
    /// **When the last waiter goes, the handshake still runs**, to its answer or to its own
    /// deadline, as if someone were waiting. Cancelling it instead would end it without a
    /// `HelloReply` on a connection whose peer may have recorded the `hello`, which costs the
    /// connection: the same teardown by another door. So a handshake nobody waits for any more
    /// leaves the connection handshaken for the next caller, or fails and takes it, exactly as it
    /// would have with a caller there. Each relay ends when the handshake does, and the handshake
    /// is bounded by its `hello`'s own deadline (`handshakeVerb`, counted from the `hello`'s turn,
    /// `InFlightMessages`), so no relay outlives that deadline.
    private func handshakenConnection() async throws -> ConnectionGeneration {
        let live = try liveConnection()
        if negotiatedReply != nil { return live }

        let generation = live.generation
        let task =
            handshake ?? Task { try await self.performHandshake(generation: generation) }
        handshake = task
        // `nil` is this caller's cancellation: the latch has no deadline, the handshake has.
        let waiter = PendingReply<Result<HelloReply, Error>?>(ifNothingArrives: nil)
        Task.detached(priority: Task.currentPriority) { waiter.deliver(await task.result) }
        guard let outcome = await waiter.waitForAnswer() else { throw CancellationError() }
        if self.generation == generation { handshake = nil }
        _ = try outcome.get()

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
    private func performHandshake(generation: UInt64) async throws -> HelloReply {
        guard generation == self.generation, let connection else {
            throw HelperClientError.helperUnreachable(code: XPCTransportCode.invalid)
        }
        let live = ConnectionGeneration(connection: connection, generation: generation)
        let request = try HelperClientPayload.encode(
            HelloRequest(
                clientProtocolVersion: AeolusXPCVersion.current,
                clientDescription: clientDescription
            )
        )
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
            if generation == self.generation {
                negotiatedReply = reply
                hasEverHandshaken = true
                publish(.handshaken)
            }
            return reply
        } catch {
            // Still held at this generation means nothing above tore it down — the peer
            // answered `hello`, or refused it, on a session that may now have recorded the
            // handshake. See this function's own documentation for why that is fatal to the
            // connection rather than to the message.
            if generation == self.generation, self.connection != nil {
                let health = Self.healthAfterFailedHandshake(for: error)
                discardConnection(generation, as: health, answering: .connectionAbandoned)
            }
            throw error
        }
    }

    /// What a failed handshake says about the connection it failed on.
    ///
    /// Reached for every failure whose connection is still held at this generation, which is
    /// **not** the same set as "failures the transport did not classify" — an earlier
    /// version of this comment claimed it was, and was wrong about two arms:
    ///
    /// - The three arms of `translate(_:on:)` that call `discardConnection` move the
    ///   generation, so the `catch` guard declines and this is genuinely not consulted.
    /// - **4097 does reach here.** `connectionWasInterrupted` keeps its connection and does
    ///   not move the generation, so the `catch` runs and the verdict becomes `.invalidated`,
    ///   overwriting the `.interrupted` published a moment earlier. That is correct — the
    ///   connection has now been discarded — but it is this function that says so.
    /// - **4101 reaches here too**, because `replyNotDelivered` publishes nothing at all.
    ///
    /// The behaviour was right in both; the comment was the defect, and it was the kind that
    /// makes a later reader believe a live function unreachable.
    private static func healthAfterFailedHandshake(
        for error: Error
    ) -> HelperConnectionHealth {
        guard let fault = error as? AeolusXPCFault else {
            // A `HelloReply` this build could not read, or a proxy that does not speak the
            // protocol. The connection has just been declared dead, and that is the honest
            // thing to say about it.
            return .invalidated
        }
        if case .versionMismatch = fault { return .versionMismatched }
        return .refused
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
        let proxy = live.connection.remoteObjectProxyWithErrorHandler { sent.settle(.failure($0)) }
        guard let typed = proxy as? any AeolusXPCProtocol else {
            throw sent.failing(
                with: HelperClientError.protocolViolation(
                    detail: "the connection vended a proxy that does not speak this protocol"))
        }
        send(typed, sent.settle)

        switch await sent.answer() {
        case .success(let answer):
            return answer
        case .failure(let error):
            throw translate(error, on: live.generation)
        }
    }

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
    /// Reachable from the suite for the same reason the two handlers below are: one arm of
    /// this switch — `NSXPCConnectionReplyInvalid` — cannot be provoked over a real
    /// connection at all, and an arm that decides whether a live connection survives is not
    /// one this project is willing to ship untested.
    func translate(_ error: Error, on generation: UInt64) -> Error {
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
            let hadSpokenToAHelper = hasEverHandshaken
            connectionWasInterrupted(generation)
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

    // MARK: - Giving up on a connection

    /// The helper process was replaced. Keep the connection, drop what the old one said.
    ///
    /// Reachable from the suite rather than `private`, because this and
    /// `connectionWasInvalidated` are **libxpc's entry points into this actor** and the
    /// interleaving `generation` exists to survive — a dead connection's handler arriving
    /// after its replacement is already live and handshaken — is not one a test can provoke
    /// on demand over a real connection. `HelperClientConnectionTests` plays libxpc instead.
    func connectionWasInterrupted(_ generation: UInt64) {
        guard generation == self.generation else { return }
        negotiatedReply = nil
        handshake = nil
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
    /// `invalidate()` below reaches each of them as 4099, and `translate(_:on:)` reads a 4099
    /// as a helper that is not installed or not yet approved — so a message this client killed
    /// itself, answered by its own invalidation, would be misdiagnosed. Each caller says what
    /// is true instead: `connectionAbandoned` when the client chose to give up, and the
    /// transport's own verdict when the transport ended the connection. Answering them settles
    /// them too, so no message stays waiting for a turn on a connection that is gone.
    private func discardConnection(
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
