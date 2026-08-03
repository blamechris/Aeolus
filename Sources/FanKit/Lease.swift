import Foundation

/// Manual fan control is a **lease**, not a setting.
///
/// This is the project's most important safety mechanism, so it is worth stating the
/// failure mode it exists to prevent: a user drops the fans to 800 RPM for silence, the
/// app crashes, and then they render video for two hours on a machine whose cooling is
/// pinned low. Nothing in a settings-based design stops that. A lease does.
///
/// A client acquires a lease with a TTL and must renew it on a heartbeat. If the lease
/// expires for any reason — crash, `kill -9`, a hung UI, logout — the helper restores
/// every fan to automatic and clears the Apple Silicon force key. "Persist across app
/// quit" is not an exception: it is a lease the helper renews itself, kept alive by the
/// helper's own launchd job.
public struct Lease: Sendable, Hashable, Codable {
    public let id: UUID
    /// Identifies the holder for display and diagnostics, e.g. `Aeolus.app`, `fanctl`.
    public let holderDescription: String
    /// When the lease lapses if not renewed — **display-grade, and nothing enforces it.**
    ///
    /// A wall-clock `Date`, so it moves when NTP steps the clock or a user sets it back.
    /// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) therefore puts enforcement on
    /// `ContinuousClock` inside the helper, where a clock jump cannot extend a lease and
    /// time asleep counts against the TTL. This field exists to be rendered — "expires in
    /// about 20 seconds" — and for no other purpose.
    ///
    /// This type deliberately offers **no `isExpired(at: Date)`**. It had one; it was
    /// removed rather than documented, because a wall-clock expiry predicate sitting on
    /// the lease type is not a hazard anyone reads a comment about — it is the obvious
    /// thing to reach for when writing a supervisor, and reaching for it is the exact bug
    /// ADR 0005 wrote its rule to prevent. An absence is a stronger guarantee than a
    /// warning, for the same reason `AeolusXPCProtocol` prefers a message that cannot be
    /// expressed to one that is refused.
    public let expiresAt: Date
    /// How long each renewal extends the lease.
    public let timeToLive: TimeInterval
    /// Whether the helper renews this lease on the client's behalf.
    public let isSelfRenewing: Bool

    /// Default lease lifetime. Short enough that a crashed client is caught quickly.
    public static let defaultTimeToLive: TimeInterval = 30
    /// Default client heartbeat interval — a third of the TTL, so two consecutive missed
    /// heartbeats are tolerated before control is surrendered.
    public static let defaultHeartbeatInterval: TimeInterval = 10

    public init(
        id: UUID = UUID(),
        holderDescription: String,
        expiresAt: Date,
        timeToLive: TimeInterval = Lease.defaultTimeToLive,
        isSelfRenewing: Bool = false
    ) {
        self.id = id
        self.holderDescription = holderDescription
        self.expiresAt = expiresAt
        self.timeToLive = timeToLive
        self.isSelfRenewing = isSelfRenewing
    }
}

/// Ceilings above which the helper overrides any user configuration, forces the affected
/// fan to maximum, and notifies the user.
///
/// These are compiled in and **tunable downward only**. A configuration file that asks to
/// raise them is rejected, not honoured — the point of a safety limit no user can defeat
/// is that no user can defeat it.
public enum ThermalCeiling {
    public static let cpuCelsius: Double = 95
    public static let storageCelsius: Double = 90

    /// Returns the effective ceiling, rejecting any attempt to raise the default.
    public static func effective(requested: Double, default defaultCeiling: Double) -> Double {
        min(requested, defaultCeiling)
    }
}
