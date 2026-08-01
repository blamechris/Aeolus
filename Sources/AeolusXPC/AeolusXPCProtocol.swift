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
///   how the process died.
/// - **The TTL is an independent backstop**, for the case where invalidation never fires.
///   Either mechanism alone suffices; both must fail for the fans to stay pinned; **they
///   share no code path.** An implementation that expires leases *from* the invalidation
///   handler has one mechanism wearing two names.
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
    func hello(request: Data, reply: @escaping (Data?, Error?) -> Void)

    /// Returns a JSON-encoded `SystemSnapshot`: every fan, every sensor, current lease.
    func snapshot(reply: @escaping (Data?, Error?) -> Void)

    /// Requests manual control of one or more fans.
    ///
    /// - Parameters:
    ///   - request: JSON-encoded `LeaseRequest`. Validated by the helper with
    ///     `AeolusXPCValidation`, which refuses rather than repairs.
    ///   - reply: Receives a JSON-encoded `Lease` on success, or the refusal.
    func acquireLease(request: Data, reply: @escaping (Data?, Error?) -> Void)

    /// Renews an existing lease. Clients must call this on their heartbeat interval or
    /// the helper will restore all fans to automatic.
    ///
    /// Renewal is refused on any connection other than the one that acquired the lease,
    /// and after expiry — an expired lease is re-acquired, never resurrected, because
    /// resurrection would let a client that stopped proving it was alive carry on as
    /// though it never had.
    func renewLease(id: String, reply: @escaping (Data?, Error?) -> Void)

    /// Voluntarily releases a lease and returns the affected fans to automatic.
    func releaseLease(id: String, reply: @escaping (Error?) -> Void)

    /// Applies fan settings under an active lease.
    ///
    /// - Parameters:
    ///   - settings: JSON-encoded `[FanSetting]`.
    ///   - leaseID: The lease authorising the change. An expired or unknown lease is a
    ///     refusal, never a silently accepted no-op.
    ///   - reply: Receives the failure, or `nil` on success.
    func apply(settings: Data, leaseID: String, reply: @escaping (Error?) -> Void)

    /// The panic path. Restores every fan to automatic, clears the Apple Silicon force
    /// key, and drops all leases. Must succeed even when the helper's state is
    /// inconsistent — this is what `fanctl reset --all` calls.
    ///
    /// **Exempt from the handshake gate** — never from the authorisation gate — and its
    /// semantics are frozen at v1 permanently. Its only expressible effect is the safe
    /// state, so a version fence that stopped a panicked user's older `fanctl` from
    /// restoring automatic control would be a safety mechanism defeating safety. The
    /// panic path carries the fewest preconditions of anything in this protocol, by
    /// design.
    func restoreAllToAutomatic(reply: @escaping (Error?) -> Void)
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
