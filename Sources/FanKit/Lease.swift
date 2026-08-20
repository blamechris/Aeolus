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
///
/// The same downward-only rule governs `FanSafetyLimits.effectiveRampRPMPerSecond(
/// requested:)`, and for the same reason: both are compiled-in limits that a settings
/// payload crossing the privilege boundary is allowed to tighten and nothing else.
public enum ThermalCeiling {
    public static let cpuCelsius: Double = 95
    public static let storageCelsius: Double = 90

    /// How far below a ceiling a temperature must fall before § 3's override lets go.
    ///
    /// The latch releases at `cpuCelsius - releaseHysteresisCelsius`, never at the ceiling
    /// itself. Without a margin the override chatters: firing returns the fans to Apple's
    /// thermal management, which cools the package back across the ceiling, which releases
    /// the latch, which lets the same lease be re-granted into the same overheating
    /// workload — an audible cycle, and one that would keep a machine oscillating around
    /// its worst temperature rather than away from it.
    ///
    /// **Why 5 °C.** It has to exceed the ordinary drift of a package temperature so the
    /// latch does not release on noise, and stay small enough that the fans are not held at
    /// maximum long after the machine is safe. `docs/SMC-RESEARCH.md` recorded the package
    /// sensor moving about 6 °C across a whole load-and-soak session on `Mac16,5` — 56 °C
    /// under a twelve-way busy loop, 62 °C during the heat soak after it stopped — so a
    /// margin below a couple of degrees would sit inside that band. Five is comfortably
    /// outside it and still only 5 % of the ceiling.
    ///
    /// Compiled in and **not configurable in either direction**, unlike the ceilings above.
    /// A settings payload may tighten a ceiling; there is no coherent meaning to tightening
    /// a hysteresis margin, and a payload that could shrink it toward zero would be a
    /// payload that could reintroduce the chatter this constant exists to prevent.
    public static let releaseHysteresisCelsius: Double = 5

    /// Returns the effective ceiling, rejecting any attempt to raise the default.
    ///
    /// A non-finite request falls back to the compiled default rather than being honoured,
    /// and that guard is load-bearing rather than tidy. `min(_:_:)` alone returns NaN when
    /// handed one — every comparison with NaN is false — and a NaN ceiling silently
    /// *disables* the thermal override, because `temperature > ceiling` is then false at
    /// every temperature. A configuration that could turn the emergency off is precisely
    /// what `docs/SAFETY.md` says cannot exist. The fallback direction can never raise the
    /// ceiling, so the downward-only rule still holds by construction.
    public static func effective(requested: Double, default defaultCeiling: Double) -> Double {
        guard requested.isFinite else { return defaultCeiling }
        return min(requested, defaultCeiling)
    }
}
