import FanKit
import SMCCore

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
/// `func canSeeCriticalTemperatures() async -> Bool`, and a boolean gives a consumer
/// nothing to check: "sighted" is the whole of it, and a conformer that cached one would be
/// indistinguishable from one that read. The report at least *can* be inspected — which
/// keys answered, how many did not.
///
/// **It does not make staleness impossible, and an earlier draft of this comment said it
/// did.** `CriticalTemperatureReport` is a plain value type with no instant and no nonce,
/// so a conformer can cache one and return it exactly as cheaply as it could cache a
/// `Bool`. Nothing in this signature forces a read. Freshness here is policy held by
/// review, not by the type — the same honest framing `CommandedTarget` uses in
/// `FanControlPlane.swift`, and for the same reason: a type that is claimed to guarantee
/// something it does not is worse than one that guarantees nothing, because the next person
/// stops checking.
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
    private let log: SafetyLog

    /// Holds the previous cycle's silent set, so an unchanged degradation is logged once
    /// rather than once per cycle. See `DegradationMemo`.
    private let memo = DegradationMemo()

    init(plane: Plane, set: CriticalSensorSet, log: SafetyLog = SafetyLog()) {
        self.plane = plane
        self.set = set
        self.log = log
    }

    /// - Note: there is no `guard !set.isEmpty` here, and that is not an oversight. The
    ///   seam's contract already says an empty request throws
    ///   `criticalTelemetryUnavailable`, and it holds that structurally rather than by
    ///   promise: no keys produce no readings, and `CriticalTemperatureReport` refuses to
    ///   be constructed from none. Restating the rule here would give it a second home,
    ///   and the second home is the one that drifts.
    func readCriticalTemperatures() async throws -> CriticalTemperatureReport {
        let asRead = try await plane.readCriticalTemperatures(set.keys)
        let gated = try CriticalTemperaturePlausibility.gate(asRead)
        switch await memo.transition(to: gated.unreadableKeys) {
        case .degraded:
            log.degradedCycle(
                provenance: set.provenance,
                answered: gated.readings.count,
                requested: set.keys.count,
                silent: gated.unreadableKeys
            )
        case .cleared:
            log.degradationCleared(
                provenance: set.provenance, answered: gated.readings.count)
        case nil:
            break
        }
        return gated
    }
}

/// Remembers which curated keys were silent last cycle, so only a **change** is logged.
///
/// ## Why this exists at all
///
/// #124 shipped `SafetyLog.degradedCycle` with one caller, `LeaseAuthority.acquireLease`,
/// which fires at most once per lease acquisition. #125 adds the second caller, and it is a
/// supervisor polling on a cycle. As the forward constraint on that issue puts it: *"an
/// unchanged degraded set logged every tick at 1 Hz is not a log, it is a denial of service
/// against the reader, and it would bury the one line that matters."* The one line that
/// matters is `thermalEmergencyEngaged`.
///
/// It lives here rather than in the supervisor deliberately. The log call is here, so the
/// collapse belongs here too — and putting it here fixes it for *every* consumer, including
/// the grant-time check, rather than for whichever one remembered. Two callers each
/// remembering their own previous set would be two answers to one question.
///
/// A `Set` comparison, not a count: losing one key and gaining another keeps the count
/// identical while changing what the mechanism can see, and that is a transition a reader
/// needs.
///
/// - Note: state is per instance. The composition root shares **one**
///   `CuratedCriticalTemperatures` between the lease core and the supervisor, which is what
///   makes the collapse global rather than per consumer.
actor DegradationMemo {

    private var silent: Set<SMCKey> = []

    /// What changed since the last cycle, or `nil` when nothing did.
    func transition(to nowSilent: [SMCKey]) -> DegradationTransition? {
        let updated = Set(nowSilent)
        defer { silent = updated }
        guard updated != silent else { return nil }
        return updated.isEmpty ? .cleared : .degraded
    }
}

/// A change in what the curated set can see. Deliberately not a `Bool`: "recovered" and
/// "degraded differently" are different lines, and a boolean would collapse them.
enum DegradationTransition: Sendable, Hashable {
    /// Keys are silent, and which ones changed since the last cycle.
    case degraded
    /// Every curated key is answering again.
    case cleared
}
