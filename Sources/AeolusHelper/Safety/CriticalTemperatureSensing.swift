import FanKit

/// One cycle of the curated critical temperatures, as a role.
///
/// ## Why the lease core needs a third dependency
///
/// `LeaseAuthority` deliberately owns no hardware. It asks `FanEnumerating` which fans
/// exist and tells `FanRestoring` to put them back, and those were the only two things it
/// needed of the machine. This is the third, and it is here rather than folded into either
/// of the others because it answers a different question at a different moment: not "what
/// is there" and not "put it back", but **"can the mechanism that protects a leased fan
/// currently see anything at all"**.
///
/// [ADR 0007](../../../docs/ADR/0007-safety-composition.md)'s second hole is that nothing
/// covered "the helper cannot read". `docs/SAFETY.md` § 5 covers divergence of *values*;
/// it does not cover the inability to obtain them, and a lease granted to a blind helper
/// pins fans with the TTL as the only surviving backstop.
///
/// ## Why this returns the report rather than a `Bool`
///
/// The lease core discards it — all it needs is whether the call threw. The report is
/// returned anyway, because the alternative signature is
/// `func canSeeCriticalTemperatures() async -> Bool`, and a boolean is the shape that
/// decays into a cached flag. Somebody optimises the hardware round trip out of the grant
/// path, the flag goes stale, and the gate reports "sighted" for a helper that has not
/// successfully read anything in an hour. An operation that must actually perform the read
/// to produce its return value cannot be satisfied by a remembered answer.
protocol CriticalTemperatureSensing: Sendable {

    /// Reads the curated critical set, once, now.
    ///
    /// - Returns: a report that is never empty — `CriticalTemperatureReport`'s initialiser
    ///   refuses to construct from no readings, which is the single place that rule lives.
    /// - Throws: `FanControlPlaneError.criticalTelemetryUnavailable` when no curated key
    ///   produced a believable reading, including when the curated set is empty.
    func readCriticalTemperatures() async throws -> CriticalTemperatureReport
}

/// The production conformer: a curated set, read through the seam, then gated.
///
/// Three separable things composed in one place — *which keys*
/// (`CriticalSensorSet`), *the read* (`FanControlPlane`), and *which readings are
/// believable* (`CriticalTemperaturePlausibility`) — because every consumer wants all
/// three and none of them wants to remember to apply the gate. A caller that reached
/// `FanControlPlane.readCriticalTemperatures(_:)` directly would get ungated readings, and
/// the one that forgot would be comparing a powered-down sensor's clean 0.00 °C against a
/// ceiling.
struct CuratedCriticalTemperatures<Plane: FanControlPlane>: CriticalTemperatureSensing {

    private let plane: Plane
    private let set: CriticalSensorSet

    init(plane: Plane, set: CriticalSensorSet) {
        self.plane = plane
        self.set = set
    }

    /// - Note: there is no `guard !set.isEmpty` here, and that is not an oversight. The
    ///   seam's contract already says an empty request throws
    ///   `criticalTelemetryUnavailable`, and it holds that structurally rather than by
    ///   promise: no keys produce no readings, and `CriticalTemperatureReport` refuses to
    ///   be constructed from none. Restating the rule here would give it a second home,
    ///   and the second home is the one that drifts.
    func readCriticalTemperatures() async throws -> CriticalTemperatureReport {
        let asRead = try await plane.readCriticalTemperatures(set.keys)
        return try CriticalTemperaturePlausibility.gate(asRead)
    }
}
