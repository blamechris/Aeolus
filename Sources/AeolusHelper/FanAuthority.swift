import AeolusXPC
import FanKit
import Foundation

/// The E2/E5 seam: everything from the mach port down to here is E2's, everything behind
/// it is E5's.
///
/// E2 owns the listener, the code-signing requirement, the handshake gate, and the decode
/// and pure validation of every payload. E5 replaces the implementation of this protocol
/// and touches none of those. That is the whole point of the split, so the two properties
/// that make it hold are worth stating.
///
/// ## It carries decoded domain values, never `Data`
///
/// No method here takes JSON. The listener has already decoded the payload and run every
/// pure check in `AeolusXPCValidation` before anything crosses. An implementation that
/// received `Data` would have to parse a wire format to do its job, and a second parser is
/// a second place for the boundary's validation to be re-implemented slightly differently
/// — which is the failure mode `CLAUDE.md` rule 7 is about. Behind this protocol there is
/// no wire format left.
///
/// ## The split of what is checked where
///
/// - **Listener:** the shape of the request. Does the JSON decode, is the holder
///   description a description, is the TTL a number of seconds this helper grants, is the
///   lease ID a UUID — and has this connection handshaken at all.
/// - **Authority:** the state of the hardware. Which fans exist
///   (`AeolusXPCValidation.validateFanIndices(_:enumeratedFanIndices:)` against the set it
///   enumerated itself), whether their bounds are plausible, whether a lease is held,
///   whether the system has taken a fan back.
///
/// The fan set is checked here rather than at the listener deliberately: the authority
/// owns the enumeration, and shipping the set up to the listener on every message would be
/// both chatty and a time-of-check/time-of-use gap on the one input that decides which
/// fans a lease may cover.
///
/// ## Connection identity crosses; connection objects do not
///
/// Every method that could affect control takes a `ConnectionID`, because a lease is bound
/// to the connection that acquired it and only the layer above knows which connection a
/// message arrived on. Nothing else about the connection crosses — no `NSXPCConnection`,
/// no PID, no audit token. An implementation cannot re-derive authorisation, and does not
/// need to: a message reaching this protocol has already passed the requirement libxpc
/// enforces.
protocol FanAuthority: Sendable {

    /// Everything a client needs to render the current state of the machine.
    func snapshot() async throws -> SystemSnapshot

    /// Grants manual control of the requested fans, or refuses.
    func acquireLease(_ request: LeaseRequest, from connection: ConnectionID) async throws -> Lease

    /// Extends a lease this connection holds, or refuses.
    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease

    /// Drops a lease this connection holds and returns its fans to automatic.
    func releaseLease(id: UUID, from connection: ConnectionID) async throws

    /// Applies fan settings under a lease this connection holds.
    func apply(
        _ settings: [FanSetting],
        leaseID: UUID,
        from connection: ConnectionID
    ) async throws

    /// The panic path. Returns every fan to automatic and drops every lease.
    ///
    /// Reached without a handshake — see `AeolusXPCProtocol.restoreAllToAutomatic` — and
    /// never without the code-signing requirement.
    func restoreAllToAutomatic(from connection: ConnectionID) async throws

    /// A connection died: crash, `SIGKILL`, logout, or an orderly disconnect.
    ///
    /// **On the seam in E2 even though `ReadOnlyFanAuthority` does nothing with it.**
    /// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) makes immediate release on
    /// connection death one of the lease's *two independent* teardown paths, the TTL being
    /// the other, and requires that they share no code path. The invalidation handler is
    /// listener code. If the event did not cross this seam in E2, E5 could only implement
    /// its half by editing the listener — and a seam whose contract says "E5 touches
    /// neither the listener, the auth, the handshake, nor the contract" would be false the
    /// first time it mattered.
    ///
    /// Not throwing, and not returning anything. A teardown that a caller could fail to
    /// act on is not a teardown, and there is nobody to report a failure to: the connection
    /// this concerns is already gone.
    func connectionDidInvalidate(_ connection: ConnectionID) async
}

/// Identifies one live XPC connection, for as long as it lives.
///
/// A freshly minted `UUID`, created in `listener(_:shouldAcceptNewConnection:)`. The three
/// obvious alternatives are all worse, and each is worse in its own way:
///
/// - **`ObjectIdentifier(connection)`** is reusable after deallocation. A lease bound to a
///   dead connection could collide with a live one that the allocator happened to place at
///   the same address, which turns a lease check into a coin flip at exactly the moment a
///   client has crashed.
/// - **The PID** is the canonical hole in this architecture and
///   [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) rejected it outright: PID reuse
///   and exec-after-check.
/// - **The audit token** is what libxpc itself keys enforcement on, and is not publicly
///   reachable from `NSXPCConnection`. Reaching it means a shim over a private structure
///   layout, which is the hand-rolled path the same ADR declined.
///
/// A minted UUID has none of those properties: it is unique for the process's lifetime,
/// unforgeable by a client because a client never sees or supplies one, and meaningless
/// outside this process — which is why it is declared here in `AeolusHelper` and not in
/// `AeolusXPC`. A type that cannot cross the wire cannot be supplied by a client.
struct ConnectionID: Hashable, Sendable {
    let raw: UUID

    init(raw: UUID = UUID()) {
        self.raw = raw
    }

    /// For log lines. Not a stable identifier across helper restarts, and nothing outside
    /// this process should treat it as one.
    var logDescription: String { raw.uuidString }
}
