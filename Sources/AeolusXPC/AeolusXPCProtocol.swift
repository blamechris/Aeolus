import Foundation

/// The privilege boundary.
///
/// Everything on the far side of this protocol runs as root. Treat every parameter as
/// hostile input: the helper must validate the calling client's code-signing requirement
/// before honouring any request, and must clamp every fan speed against the firmware's
/// own bounds regardless of what the client asked for. A client is a source of requests,
/// never a source of authority.
///
/// ## What this protocol carries — and what it can never carry
///
/// The messages here are **fan-control intents**, never SMC operations. There is no
/// "write key K with bytes B" message and there never will be one: a generic key-write
/// would make the helper a root SMC proxy and reduce every safety mechanism below it to
/// decoration. Equally absent, permanently — any message that raises a thermal ceiling,
/// disables the lease, widens firmware bounds, or enables an "advanced mode". Those are
/// not *refused* at runtime; they are inexpressible, which is a stronger property,
/// because a refusal is code that can be wrong and an absence cannot. See `CLAUDE.md`
/// rule 5 and [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md).
///
/// ## The handshake gate
///
/// Every connection is refused with `AeolusXPCFault.handshakeRequired` until `hello`
/// succeeds. The helper enforces this; a client's own version check is a courtesy. A
/// client outside the helper's supported range is refused with **both** sides' ranges,
/// so it can say "this helper speaks 1–1, this client speaks 3 — update Aeolus.app"
/// rather than shrugging. Refuse, never degrade.
///
/// `restoreAllToAutomatic` is the one deliberate exemption — see its own documentation.
///
/// ## Messages are processed in the order they were sent
///
/// Per connection, and it is the **helper's** guarantee rather than a client's discipline. A
/// client may pipeline `hello` and `snapshot` without awaiting the handshake's reply: the
/// `snapshot` is answered after the `hello` it was sent behind, and never with
/// `handshakeRequired` for having overtaken it. The helper calls message N's reply block
/// before it begins message N+1, so the answers come back in the order the questions went
/// out. "Fire `hello` and `snapshot` together to save a round trip at launch" is therefore a
/// legal optimisation and not a race a client has to know about.
///
/// **Exactly which messages are sequenced, and which are not.** Sequenced: `hello`,
/// `snapshot`, `acquireLease`, `apply`. Not sequenced: `restoreAllToAutomatic`, `renewLease`,
/// `releaseLease` — each **dispatched** the moment it arrives, in no order relative to
/// anything, and answered on its own schedule rather than the queue's. The line between the
/// two lists is not the verb's importance: it is whether waiting is a precondition the message
/// is allowed to acquire. The three unsequenced ones are the ones whose whole value is
/// promptness — restoring the safe state, proving the client is still alive, and handing the
/// fans back — and every one of them is an *unlock*, so the queue in front of it is time the
/// fans spend held by something nobody is checking. The four sequenced ones are the ones a
/// client pipelines ahead of a reply it has not received, which is the only place ordering
/// buys anything.
///
/// The three carry no ordering guarantee **in either direction**: they may overtake a message
/// sent before them, and a message sent before them may still complete after them. Each is
/// idempotent-or-safe under both interleavings — `restoreAllToAutomatic` is global,
/// `renewLease` extends a TTL it can only extend from now, and `releaseLease` releases a lease
/// that expiry would have taken anyway — so the reordering costs a *correct* client nothing.
/// What it can cost is an effect a client wanted last: see the panic path's own paragraph
/// below, which states the hazard once for all three.
///
/// **The panic path is exempt, and the exemption is the point of it.** Ordering is a
/// precondition — "every message sent earlier on this connection has returned" — and
/// `restoreAllToAutomatic` carries the fewest preconditions of anything here. It is
/// **dispatched** the moment it arrives and is never queued behind another message, so a
/// `snapshot` still in flight, or an operation that never returns at all, cannot hold it in
/// a queue. What that buys is promptness, not a bounded reply: the restore's own body drops
/// every lease and writes each fan back to automatic through the same control plane, so on
/// the wedged `io_connect_t` of `docs/SAFETY.md` § 4 it is *started* immediately and its
/// completion is still the plane's to give. A client may therefore send it at any time,
/// including on a connection it has already pipelined work onto, and it is answered on its
/// own schedule rather than the queue's. Its reply is the one that may arrive out of order.
///
/// **The hazard every exemption creates, stated plainly and once.** Because an unsequenced
/// message is not in the queue, a message sent *before* it on the same connection may still be
/// executing when it runs — and may therefore take effect *after* it. For the panic path that
/// means a fan left in manual that the restore was meant to clear; for `releaseLease` it means
/// an `apply` sent ahead of it landing on a lease the release had already dropped, or after it.
/// A client that needs one of the three to be the last thing that happens must await its
/// earlier replies first; the exemption buys promptness, not ordering.
/// [#180](https://github.com/blamechris/Aeolus/issues/180) is the mechanism that makes the
/// interleaving harmless — a write away from the safe state requires a live lease, checked
/// at the write — and until it is built, this ordering is the client's to manage.
///
/// **What ordering costs a client that pipelines.** One message at a time is one message at
/// a time in both directions: while a sequenced message N is being handled, the sequenced
/// message N+1 has not started, so a message the helper is slow to answer delays every later
/// *sequenced* message on that connection until it returns. There is still no queue bound and
/// no per-message deadline, so a client that pipelines faster than the helper answers grows
/// its own backlog and should treat its round-trip latency as the budget for everything
/// sequenced behind it.
///
/// **A heartbeat is no longer in that budget, and that is why the bound was not added**
/// ([#229](https://github.com/blamechris/Aeolus/issues/229)). It used to be: `renewLease` sat
/// in the queue, `docs/SAFETY.md` § 3 has a client rendering the snapshot at 1 Hz on the
/// connection it also holds its lease on, and a read costs 0.56–2.9 s on the maintainer's
/// Mac16,5 — so the backlog grew monotonically and, once it exceeded the TTL, a beat sent
/// exactly on schedule arrived after the lease it was renewing had expired. § 1 grants a 30 s
/// TTL with a 10 s beat so that two consecutive missed beats are tolerated, and that is a
/// property of the *client's sending*; a helper-side backlog defeated it with the client doing
/// nothing wrong. Bounding the queue would have answered the dropped message with a refusal a
/// compliant client could not have avoided either, and a ceiling wide enough not to do that is
/// wider than the TTL. So the heartbeat left the queue instead, and `releaseLease` with it.
///
/// Two connections still cost nothing to hold and are the way to keep an unrelated *sequenced*
/// message off a slow one's queue. The three unsequenced verbs need neither.
///
/// Nothing between connections is ordered, and nothing will be: two connections are two
/// clients as far as this boundary is concerned, and one must never be able to delay the
/// other. Neither is `connectionDidInvalidate` a message, so a connection's death is not
/// ordered against messages already in flight on it.
///
/// **Detecting a helper that predates this.** The guarantee is only usable by pipelining
/// ahead of the handshake's reply, and every version and capability signal arrives *in* that
/// reply — so it cannot be gated on one, whatever the version said. A client that pipelines
/// must therefore treat `handshakeRequired` **on the pipelined message** as a retryable
/// stale-helper signal and re-send it after the handshake, rather than as a contract
/// violation. `HelloReply.capabilities` carries `"ordered-messages"` from a helper that
/// honours this, which is what lets a client confirm afterwards, remember it, and skip the
/// fallback next time.
///
/// The rule is stated here, on the contract, because that is where a client can rely on it.
/// It is kept on the helper side, because rule 7 makes client-side validation a courtesy and
/// helper-side validation the control — the same argument applied to sequencing. This
/// strengthens what a compliant client may do without adding a message, a field, or any
/// change to what crosses the wire — the capability string is an added `capabilities` entry,
/// which the bump policy below lists as additive — so ``AeolusXPCVersion/current`` does not
/// move for it. See [#90](https://github.com/blamechris/Aeolus/issues/90).
///
/// ## The lease, as the helper must implement it
///
/// E2 defines these semantics; E5 implements them. They are written down here, on the
/// contract itself, so that an implementation cannot get them wrong without visibly
/// contradicting the boundary it is implementing.
///
/// - **Renewal is client-driven**, on the heartbeat interval of `timeToLive / 3` (see
///   `Lease.defaultHeartbeatInterval` and `docs/SAFETY.md` §1), so two consecutive missed
///   beats are tolerated before control is surrendered. A helper-driven "ping the client"
///   inversion is rejected by ADR 0005: it would make a root daemon depend on client
///   responsiveness.
/// - **Enforcement is helper-internal against a monotonic clock.** `Lease.expiresAt` is a
///   wall-clock `Date` and is display-grade only. The supervisor enforces on
///   `ContinuousClock`, so a wall-clock jump — NTP, a user setting the clock back — can
///   never extend a lease, and time asleep counts against the TTL.
/// - **A lease is bound to the connection that acquired it.** A valid lease ID presented
///   on a different connection is refused with
///   `AeolusXPCFault.leaseNotHeldByThisConnection`, not honoured.
/// - **Connection death releases immediately.** The invalidation handler for a
///   lease-holding connection restores those fans at once, covering crash, `SIGKILL`, and
///   logout within milliseconds, because the kernel tears the mach port down regardless of
///   how the process died. This describes the *default* lease — see self-renewal below.
/// - **The TTL is an independent backstop**, for the case where invalidation never fires.
///   Either mechanism alone suffices; both must fail for the fans to stay pinned; **they
///   share no code path.** An implementation that expires leases *from* the invalidation
///   handler has one mechanism wearing two names.
///
/// ### Self-renewing leases
///
/// `LeaseRequest.isSelfRenewing` asks for the one lease that **survives connection
/// death**, which is why the two rules above are written as the default rather than as
/// every lease. It is not an exception to the lease model and it is not a setting:
/// `CLAUDE.md` rule 2 settles this — "persist across quit" is a *helper-renewed lease*.
/// On invalidation the helper becomes the holder and inherits the obligation the client
/// was discharging, which is to keep proving the lease should still be held. It does not
/// inherit permission to stop proving it.
///
/// Its teardowns are therefore an explicit `releaseLease`, the safety supervisor (thermal
/// override, reclamation, implausible bounds), and a helper-side liveness policy.
/// Connection invalidation is not one of them.
///
/// **E5 owns that liveness policy** — what the helper checks, how often, and what makes it
/// let go. Nothing here presumes its shape, and no mechanism for it is invented here. E2
/// implements no part of self-renewal at all: nothing implements this protocol yet, so the
/// field crosses the boundary and is validated, and there is no code path that can yet
/// exercise it.
///
/// ## What a reply block promises — and what it does not
///
/// Two reply shapes cross this boundary, and both carry the same contract.
///
/// - `(Data?, Error?) -> Void` — **exactly one of the two is non-nil.** A payload means
///   success; an error means refusal. `(nil, nil)` is a protocol violation, not an empty
///   success, and a client that reads it as one has invented an answer the helper never
///   gave.
/// - `(Error?) -> Void` — `nil` means the request succeeded; non-nil is the refusal.
///
/// **A reply block may never be invoked at all.** When the connection itself fails — the
/// helper is not installed, crashed, or was killed mid-request — `NSXPCConnection` routes
/// to the error handler given to `remoteObjectProxyWithErrorHandler(_:)` and the block
/// passed with the message is simply dropped. A client that writes its failure path only
/// inside the reply block therefore has no failure path for the case that matters most.
/// "No reply" is a failure and must be rendered as one: leaving the last known fan state
/// on screen would claim control that nothing is honouring, which `CLAUDE.md` rule 6
/// forbids. Use `remoteObjectProxyWithErrorHandler(_:)`, never bare `remoteObjectProxy`.
///
/// `AeolusXPCFault.init?(nsError:)` returning `nil` says "this error did not come from
/// Aeolus's boundary" — a transport failure, a Cocoa error. That is still a failure, and
/// never "no problem". It is the "the helper never answered" case, which a client
/// distinguishes from a refusal and must not distinguish from a success.
///
/// ## Why every reply block is `@Sendable`
///
/// It is the one thing a reply block is *for*: libxpc invokes it from its own event
/// threads, and a helper answering a message it had to go and read hardware for cannot
/// answer on the thread the message arrived on. Saying so on the contract rather than at
/// each implementation is the difference between a checked fact and a claim. Without it,
/// an implementation that hands the block to a `Task` — which every asynchronous one must
/// — needs an `@unchecked Sendable` box or a `nonisolated(unsafe)` local, and `CLAUDE.md`
/// rule 10 is explicit that in this codebase those are claims requiring review rather than
/// ways to silence the compiler. The annotation is invisible to the Objective-C runtime:
/// the selectors are unchanged, the wire format is unchanged, and
/// `XPCContractTests.protocolDeclaresExactlyTheAllowedMessages` is what proves it.
///
/// - Note: `@objc` and reply blocks are required by `NSXPCConnection`; this is one of the
///   few places in the codebase that is not idiomatic Swift concurrency. Structured
///   payloads cross as JSON-encoded `Data` (see `AeolusXPCPayload`) so the wire format is
///   versioned and inspectable rather than depending on `NSSecureCoding` class graphs.
///   Refusals cross as `Error` and should be carried by `AeolusXPCFault.asNSError()`,
///   which survives the `NSXPCConnection` round trip with its vocabulary intact.
@objc public protocol AeolusXPCProtocol {

    /// Opens the connection. Every other message except `restoreAllToAutomatic` is
    /// refused until this succeeds.
    ///
    /// This replaces an earlier `protocolVersion(reply:)` that handed the helper's
    /// version to the client and hoped it compared. That is rule 8 ("being able to
    /// connect is not authorisation") applied to versioning: a stale client must be
    /// *unable* to proceed unchecked, not merely expected not to.
    ///
    /// - Parameters:
    ///   - request: JSON-encoded `HelloRequest`.
    ///   - reply: Receives a JSON-encoded `HelloReply` on success, or the refusal —
    ///     `AeolusXPCFault.versionMismatch`, carrying both sides' ranges.
    func hello(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void)

    /// Returns a JSON-encoded `SystemSnapshot`: every fan, every sensor, current lease.
    func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)

    /// Requests manual control of one or more fans.
    ///
    /// - Parameters:
    ///   - request: JSON-encoded `LeaseRequest`. Validated by the helper with
    ///     `AeolusXPCValidation`, which refuses rather than repairs.
    ///   - reply: Receives a JSON-encoded `Lease` on success, or the refusal.
    func acquireLease(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void)

    /// Renews an existing lease. Clients must call this on their heartbeat interval or
    /// the helper will restore all fans to automatic.
    ///
    /// **Exempt from the per-connection ordering above** — never from the handshake gate, and
    /// never from the authorisation gate. A beat is the message that proves the client is
    /// still alive, and `docs/SAFETY.md` § 1 tolerates two missed beats as a property of the
    /// client's *sending*; queueing it behind the client's own reads defeated that with the
    /// client doing nothing wrong ([#229](https://github.com/blamechris/Aeolus/issues/229)).
    /// So a beat is dispatched on arrival and may be answered before a `snapshot` sent ahead
    /// of it. The exemption costs a client nothing it has to handle: this extends a TTL from
    /// now, so an earlier message completing afterwards cannot shorten it.
    ///
    /// Renewal is refused on any connection other than the one that acquired the lease,
    /// and after expiry — an expired lease is re-acquired, never resurrected, because
    /// resurrection would let a client that stopped proving it was alive carry on as
    /// though it never had.
    ///
    /// `id` is a `Lease.id` — a `UUID` on both sides, a bare `String` only because that is
    /// what an `@objc` signature carries. Check it with
    /// `AeolusXPCValidation.validateLeaseID(_:)` before it reaches a lookup or a log line.
    func renewLease(id: String, reply: @escaping @Sendable (Data?, Error?) -> Void)

    /// Voluntarily releases a lease and returns the affected fans to automatic.
    ///
    /// **Exempt from the per-connection ordering above**, for `renewLease`'s reason pointing
    /// the other way: every message queued in front of this one is time the fans stay in manual
    /// after the client has already asked for them back, with nothing renewing the lease and
    /// nobody wanting it. Unlike `renewLease`, this exemption *is* observable — an `apply` sent
    /// ahead of it may land after the release and be refused, or before it and be undone — so a
    /// client that wants a last setting to stick awaits that reply before releasing. See the
    /// hazard paragraph in the ordering section above, which states it once for all three
    /// unsequenced verbs.
    ///
    /// `id` is checked with `AeolusXPCValidation.validateLeaseID(_:)`, as for `renewLease`.
    func releaseLease(id: String, reply: @escaping @Sendable (Error?) -> Void)

    /// Applies fan settings under an active lease.
    ///
    /// - Parameters:
    ///   - settings: JSON-encoded `[FanSetting]`.
    ///   - leaseID: The lease authorising the change, checked with
    ///     `AeolusXPCValidation.validateLeaseID(_:)`. An expired or unknown lease is a
    ///     refusal, never a silently accepted no-op.
    ///   - reply: Receives the failure, or `nil` on success.
    func apply(settings: Data, leaseID: String, reply: @escaping @Sendable (Error?) -> Void)

    /// The panic path. Restores every fan to automatic, clears the Apple Silicon force
    /// key, and drops all leases. Must succeed even when the helper's state is
    /// inconsistent — this is what `fanctl reset --all` calls.
    ///
    /// **Exempt from the handshake gate** — never from the authorisation gate — **and from
    /// the per-connection ordering above**, and its semantics are frozen at v1 permanently.
    /// Its only expressible effect is the safe state, so a version fence that stopped a
    /// panicked user's older `fanctl` from restoring automatic control would be a safety
    /// mechanism defeating safety. The panic path carries the fewest preconditions of
    /// anything in this protocol, by design — which is why it is not queued behind messages
    /// sent before it: a message still in flight is a precondition, and a message that never
    /// returns is a permanent one. The exemption is over *dispatch*: a message pipelined
    /// ahead of this one may still complete after it, so a client that wants this to be the
    /// last effect on the connection awaits its earlier replies first.
    ///
    /// It is the only verb exempt from the handshake gate; since
    /// [#229](https://github.com/blamechris/Aeolus/issues/229) it is **not** the only one
    /// exempt from ordering — `renewLease` and `releaseLease` are too, on the same argument
    /// about preconditions. It is still the only one that carries *all* of the exemptions,
    /// which is what "fewest preconditions of anything in this protocol" means.
    func restoreAllToAutomatic(reply: @escaping @Sendable (Error?) -> Void)
}

/// Version of the XPC contract itself, negotiated at connect time.
///
/// Independent of the app's marketing version: a Homebrew-installed `fanctl` and a
/// Sparkle-updated app will routinely be at different releases, and only this number
/// determines whether they can talk.
///
/// ## Bump policy
///
/// Within a version, these changes are **additive** and require no bump:
///
/// - Adding an *optional* field to a DTO. Both peers keep decoding.
/// - Adding a case to a forward-tolerantly decoded vocabulary — `AeolusXPCFault` and
///   `ManualControlAvailability.Reason`. An older peer decodes the new value to its
///   `unknown` case and renders it generically. This is exactly what forward tolerance
///   was built for, and the reason both vocabularies were written out in full in E2
///   rather than grown case by case.
/// - Adding a string to `HelloReply.capabilities`.
///
/// These changes bump ``current``:
///
/// - Adding, removing, or renaming a **required** DTO field, or changing its type.
/// - Changing what an existing message *means*, even with an unchanged signature.
/// - Adding, removing, or renaming a method on `AeolusXPCProtocol`.
///
/// The policy binds from the first **shipped** implementation, which is why #70 reshaped
/// v1 without bumping it: replacing `protocolVersion(reply:)` with `hello(request:reply:)`
/// is a method removed and a method added, and ``current`` stays at 1 because no helper
/// had ever implemented this protocol and no client had ever spoken it. There was no
/// installed peer for a bump to protect. From #72 onward that is no longer true, and the
/// list above is binding without exception.
///
/// Raising ``minimumSupported`` orphans installed clients and is a **release-notes
/// event**, not a routine change: a user whose `fanctl` stops talking to their helper is
/// owed an explanation in the release they upgraded to.
///
/// ## Capabilities are not a safety switch
///
/// `HelloReply.capabilities` is feature discovery, nothing more. A capability may gate a
/// convenience — a UI affordance, an extra CLI subcommand. It may **never** gate a safety
/// mechanism, because a safety mechanism that a peer can decline to advertise is a safety
/// mechanism a peer can turn off, which `CLAUDE.md` rule 5 forbids by construction.
public enum AeolusXPCVersion {
    public static let current = 1

    /// The oldest client protocol version this helper still accepts.
    public static let minimumSupported = 1

    /// The pair a helper advertises in `HelloReply`.
    public static let supportedRange = ProtocolVersionRange(
        minimumSupported: minimumSupported,
        current: current
    )

    public static func isCompatible(clientVersion: Int) -> Bool {
        supportedRange.accepts(clientVersion: clientVersion)
    }
}

/// The mach service the helper registers and clients connect to.
public enum AeolusXPCService {
    public static let machServiceName = "com.blamechris.Aeolus.Helper"
}
