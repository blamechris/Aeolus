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
/// purpose. **229 of its lines are code**; the rest is the reasoning around them, and the
/// rule counts comment lines. That figure did not move when this section was added — the file
/// grew by fifty-odd lines and by none of the thing the threshold is worth measuring, which
/// is the whole argument in one measurement. The warning is deliberately **not** suppressed —
/// no `swiftlint:disable`, no `file_length` override in `.swiftlint.yml` — because a file that
/// grew by two hundred lines of *logic* should draw exactly the attention this one drew.
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
///   `stopObserving` — is the one slice that could own its state outright in a type of its
///   own rather than borrowing this actor's, so it is the one that would widen nothing. It is
///   worth about twenty-five lines against an overage past two hundred and fifty, in exchange
///   for an indirection on the path that reports whether this client can see the helper at
///   all. Not worth doing for a line count; worth reconsidering on its own merits if the
///   signal grows.
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
    private var currentHealth: HelperConnectionHealth = .idle
    private var observers: [UUID: AsyncStream<HelperConnectionHealth>.Continuation] = [:]

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
    ///   - deadlines: How long to wait for one message. Unmeasured; see
    ///     `HelperClientDeadlines`.
    public init(
        transport: HelperClientTransport = .machService,
        pinning: any HelperConnectionPinning = SignedHelperPinning(),
        clientDescription: String,
        deadlines: HelperClientDeadlines = .default
    ) {
        self.transport = transport
        self.pinning = pinning
        self.clientDescription = clientDescription
        self.deadlines = deadlines
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
    public var health: HelperConnectionHealth { currentHealth }

    /// Which connection this client is on, for a suite that has to name one.
    ///
    /// `internal`, like `translate(_:on:)` and the two handlers, and for the same reason:
    /// the generation is the parameter every one of those guards turns on, so a test that
    /// could not name it could only assert them by accident. Nothing outside this module
    /// can see it and nothing inside it reads it except the guards themselves.
    var currentGeneration: UInt64 { generation }

    /// The same signal as a stream, for a client that renders it rather than polls it.
    ///
    /// Yields the current value immediately on subscription, so a subscriber never has to
    /// combine a first read with a stream to know where it stands. Buffers unboundedly by
    /// default and the values are four cases, so a slow consumer costs nothing that matters.
    nonisolated public func healthUpdates() -> AsyncStream<HelperConnectionHealth> {
        AsyncStream { continuation in
            let token = UUID()
            // `[weak self]`, because this client holds the continuation and the
            // continuation holds this closure: capturing strongly is a retain cycle that
            // keeps a connection-owning actor alive for as long as anyone forgets to end
            // the stream.
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.stopObserving(token) }
            }
            Task { await self.observe(continuation, as: token) }
        }
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
    func withHandshakenProxy<Answer: Sendable>(
        _ send: (any AeolusXPCProtocol, @escaping @Sendable (Result<Answer, Error>) -> Void) -> Void
    ) async throws -> Answer {
        let live = try await handshakenConnection()
        return try await exchange(on: live, within: deadlines.gatedVerb, send)
    }

    /// Runs one message on a live connection **without** a handshake.
    ///
    /// `restoreAllToAutomatic` is the only caller, permanently, and
    /// `HelperClientSeamTests.theUnhandshakenProxyHasExactlyOneCaller` is what keeps that
    /// true: it counts the occurrences of this function's name in this target's sources and
    /// requires exactly two — this declaration and that one call. A second caller would be a
    /// verb quietly exempting itself from the gate on the client's side of a boundary whose
    /// whole design is that gates are not optional.
    func withProxy(
        _ send: (any AeolusXPCProtocol, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void
    ) async throws {
        let live = try liveConnection()
        try await exchange(on: live, within: deadlines.panicVerb, send)
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
    private func handshakenConnection() async throws -> ConnectionGeneration {
        let live = try liveConnection()
        if negotiatedReply != nil { return live }

        let generation = live.generation
        let task =
            handshake ?? Task { try await self.performHandshake(generation: generation) }
        handshake = task
        defer { if self.generation == generation { handshake = nil } }
        _ = try await task.value

        // The connection this handshake ran on, not whatever is current now. If it died in
        // between, the message about to be sent on it fails through the error handler and is
        // reported as what it was — there is no second attempt here.
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
                on: live, within: deadlines.handshakeVerb
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
                discardConnection(generation, as: Self.healthAfterFailedHandshake(for: error))
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
    private func exchange<Answer: Sendable>(
        on live: ConnectionGeneration,
        within deadline: Duration,
        _ send: (any AeolusXPCProtocol, @escaping @Sendable (Result<Answer, Error>) -> Void) ->
            Void
    ) async throws -> Answer {
        // Two fallbacks, because the two ways of giving up are different events and the
        // deadline's is acted on. A caller that was cancelled has said nothing about the
        // helper; see `translate(_:on:)`.
        let pending = PendingReply<Result<Answer, Error>>(
            ifNothingArrives: .failure(HelperClientError.helperNeverAnswered(after: deadline)),
            ifCancelled: .failure(CancellationError())
        )
        let proxy = live.connection.remoteObjectProxyWithErrorHandler { error in
            pending.deliver(.failure(error))
        }
        guard let typed = proxy as? any AeolusXPCProtocol else {
            throw HelperClientError.protocolViolation(
                detail: "the connection vended a proxy that does not speak this protocol")
        }
        send(typed) { pending.deliver($0) }

        switch await pending.answer(within: deadline) {
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
        // The message stays at the head of the helper's queue and that is deliberate. The
        // next verb queues behind it, hits its **own** deadline, and discards then — one
        // extra timeout on a genuinely wedged helper, which is the right price for never
        // tearing down a healthy one.
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
                discardConnection(generation, as: .unresponsive)
            }
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
            discardConnection(generation, as: .refused)
            return HelperClientError.helperSignatureRejected
        default:
            // Every other transport code, 4099 included: the connection failed and no
            // message was delivered. The code is carried rather than mapped, because a
            // reason this build has not heard of must still reach a log line.
            discardConnection(generation, as: .invalidated)
            return HelperClientError.helperUnreachable(code: nsError.code)
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
    func connectionWasInvalidated(_ generation: UInt64) {
        discardConnection(generation, as: .invalidated)
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
    public func disconnect() {
        guard connection != nil else { return }
        discardConnection(generation, as: .idle)
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
    private func discardConnection(_ generation: UInt64, as health: HelperConnectionHealth) {
        guard generation == self.generation else { return }
        let dying = connection
        self.generation &+= 1
        connection = nil
        negotiatedReply = nil
        handshake = nil
        hasEverHandshaken = false
        publish(health)
        dying?.invalidate()
    }

    // MARK: - The health signal

    private func publish(_ health: HelperConnectionHealth) {
        guard health != currentHealth else { return }
        currentHealth = health
        for continuation in observers.values { continuation.yield(health) }
    }

    private func observe(
        _ continuation: AsyncStream<HelperConnectionHealth>.Continuation,
        as token: UUID
    ) {
        observers[token] = continuation
        continuation.yield(currentHealth)
    }

    private func stopObserving(_ token: UUID) {
        observers[token] = nil
    }

}
