import Foundation

/// The privilege boundary.
///
/// Everything on the far side of this protocol runs as root. Treat every parameter as
/// hostile input: the helper must validate the calling client's code-signing requirement
/// before honouring any request, and must clamp every fan speed against the firmware's
/// own bounds regardless of what the client asked for. A client is a source of requests,
/// never a source of authority.
///
/// - Note: `@objc` and reply blocks are required by `NSXPCConnection`; this is one of the
///   few places in the codebase that is not idiomatic Swift concurrency. Structured
///   payloads cross as JSON-encoded `Data` (see `AeolusXPCPayload`) so the wire format is
///   versioned and inspectable rather than depending on `NSSecureCoding` class graphs.
@objc public protocol AeolusXPCProtocol {

    /// Returns the helper's supported protocol version. Clients call this first.
    ///
    /// A stale client against a newer helper must fail loudly with a clear message —
    /// never degrade silently into misbehaviour. See `docs/ARCHITECTURE.md`.
    func protocolVersion(reply: @escaping (Int) -> Void)

    /// Returns a JSON-encoded `SystemSnapshot`: every fan, every sensor, current lease.
    func snapshot(reply: @escaping (Data?, Error?) -> Void)

    /// Requests manual control of one or more fans.
    ///
    /// - Parameters:
    ///   - request: JSON-encoded `LeaseRequest`.
    ///   - reply: Receives a JSON-encoded `Lease` on success, or the refusal.
    func acquireLease(request: Data, reply: @escaping (Data?, Error?) -> Void)

    /// Renews an existing lease. Clients must call this on their heartbeat interval or
    /// the helper will restore all fans to automatic.
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
    func restoreAllToAutomatic(reply: @escaping (Error?) -> Void)
}

/// Version of the XPC contract itself, negotiated at connect time.
///
/// Independent of the app's marketing version: a Homebrew-installed `fanctl` and a
/// Sparkle-updated app will routinely be at different releases, and only this number
/// determines whether they can talk.
public enum AeolusXPCVersion {
    public static let current = 1

    /// The oldest client protocol version this helper still accepts.
    public static let minimumSupported = 1

    public static func isCompatible(clientVersion: Int) -> Bool {
        clientVersion >= minimumSupported && clientVersion <= current
    }
}

/// The mach service the helper registers and clients connect to.
public enum AeolusXPCService {
    public static let machServiceName = "com.blamechris.Aeolus.Helper"
}
