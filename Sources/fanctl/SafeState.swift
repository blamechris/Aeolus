import AeolusXPC
import FanKit
import Foundation

/// The safe-state check: "does the helper report every fan cleared and nothing leased?"
///
/// **One implementation, for every command that asks for the safe state and then looks.**
/// `fanctl auto` ends on it, and `fanctl set` ends on it after releasing its lease. Two
/// copies would be two definitions of "confirmed", and the day they disagreed one command would
/// report the fans fine that the other reported pinned.
///
/// ## What it may conclude
///
/// Only what a `snapshot()` reply says, in the helper's words, and from **both** fields that
/// speak to a fan: its `mode` and its `manualControlAvailability`. The mode alone is not enough.
/// The helper reports an unreadable `F<n>Md` as `automatic`
/// ([#178](https://github.com/blamechris/Aeolus/issues/178)), and on Intel the register does not
/// exist, so `automatic` is also what a fan reads when nobody has looked. The availability is the
/// field that says "the helper has not cleared this fan", and it says so whatever the mode
/// reads. A fan is **cleared** when its mode reads automatic *and* its availability does not say
/// otherwise. That is still the helper reporting, not the fans being so, which is why every
/// string a command prints for it says "the helper reports".
///
/// ## The three verdicts, and their order
///
/// 1. `cannotReturn` — a fan carries a reason that **retrying cannot change**, whatever its mode
///    reads. Checked first: a pinned fan beside a lease is still pinned, and "wait" would be
///    wrong.
/// 2. `automatic` — every fan is cleared and nothing is leased.
/// 3. `notConfirmed` — anything else: not yet, or the helper stopped answering.
///
/// A lease present when the wait ends is `notConfirmed` here. `fanctl auto` reports that as exit
/// 5, because naming the holder is the useful thing to say about it; `fanctl set` ending maps it
/// as its own contract says. The distinction is the caller's, so the check does not make it.
enum SafeState {

    /// How long a command waits for the helper to report the safe state after asking for it.
    ///
    /// A whole number of poll intervals, held by `SafeStateTests`: `settle` sleeps one interval
    /// at a time and stops at the first read taken at or past the end, so a window that was not
    /// a multiple would overshoot by up to one interval.
    static let window = Duration.seconds(10)

    /// How often the snapshot is read while waiting.
    static let pollInterval = Duration.seconds(1)

    enum Verdict: Equatable, Sendable {
        /// No lease, and every fan cleared: automatic, with no reason beside it.
        case automatic
        /// These fans carry a reason that waiting will not change, whatever their mode reads.
        case cannotReturn(fans: [Int])
        /// Not the safe state, and not known to be unreachable either.
        case notConfirmed
    }

    /// What one snapshot says.
    static func verdict(for snapshot: SystemSnapshot) -> Verdict {
        let pinned = snapshot.fans.filter {
            clearance(of: $0.manualControlAvailability) == .durable
        }
        if !pinned.isEmpty { return .cannotReturn(fans: pinned.map(\.index)) }
        if snapshot.fans.allSatisfy(isCleared) && snapshot.activeLease == nil { return .automatic }
        return .notConfirmed
    }

    /// Whether the helper reports this fan as back under automatic control: its mode reads
    /// automatic **and** its availability is not a reason the helper has not cleared it.
    ///
    /// `.silent` is the only availability that lets the mode speak for itself. Anything else is
    /// the helper saying something about the fan that a mode of `automatic` does not contradict,
    /// because `automatic` is also what an unread mode is reported as.
    static func isCleared(_ fan: FanState) -> Bool {
        fan.mode == .automatic && clearance(of: fan.manualControlAvailability) == .silent
    }

    /// What a fan's availability says about whether the helper has cleared it.
    enum Clearance: Equatable, Sendable {
        /// A reason that waiting will not change, whatever the mode reads.
        case durable
        /// The helper has not established this fan's mode, or a restore of it is outstanding.
        /// Worth looking again.
        case pending
        /// Says nothing about whether the fan is back under automatic control: the mode decides.
        case silent
    }

    /// Classifies one availability.
    ///
    /// - **`durable`** — `foreignManualControl` ("nothing in Aeolus will change it, because
    ///   nothing in Aeolus put the fan there") and `restoreToAutomaticFailed` ("the firmware
    ///   never took the write").
    /// - **`pending`** — the reasons that mean the helper has not established the fan's mode, or
    ///   a restore is outstanding: `releaseInProgress`, `handbackUnconfirmed`,
    ///   `restoreToAutomaticUnconfirmed`, `systemSleeping`, `unknown` (which the type says is
    ///   never to be treated as available) and `supervisorBlind`. A blind fan's state is
    ///   *unknown*, not manual, so it is 8 and not 9 even though reconciliation can leave it so
    ///   for the life of the process.
    /// - **`silent`** — the reasons about manual control being *granted*, not about the fan:
    ///   `writePathNotBuilt` (every fan on today's helper), `boundsImplausible`,
    ///   `leaseHeldByAnotherClient` (a lease is judged from `activeLease`),
    ///   `selfRenewalNotBuilt`, `noThermalTelemetry` and `reclaimedBySystem`.
    ///
    /// **Exhaustive, with no `default:` arm,** so a reason added to the vocabulary is a compile
    /// error here rather than a quiet "silent": the classification decides whether to wait at
    /// all, or to stop waiting, and a new reason has to be decided.
    static func clearance(of availability: ManualControlAvailability) -> Clearance {
        guard case .unavailable(let reason) = availability else { return .silent }
        switch reason {
        case .foreignManualControl,
            .restoreToAutomaticFailed:
            return .durable
        case .releaseInProgress,
            .handbackUnconfirmed,
            .restoreToAutomaticUnconfirmed,
            .supervisorBlind,
            .systemSleeping,
            .unknown:
            return .pending
        case .writePathNotBuilt,
            .boundsImplausible,
            .leaseHeldByAnotherClient,
            .selfRenewalNotBuilt,
            .noThermalTelemetry,
            .reclaimedBySystem:
            return .silent
        }
    }

    // MARK: - Waiting

    /// How a wait ended.
    struct Settlement: Sendable {
        /// `.automatic` only if the last read said so. A read that failed is never `.automatic`.
        let verdict: Verdict
        /// The last snapshot that was read, if any was.
        let snapshot: SystemSnapshot?
        /// How many snapshots were read.
        let polls: Int
        /// Why the wait stopped early, if it did: a read that failed, or a sleep that was
        /// cancelled. When this is set, `snapshot` may predate the end of the wait.
        let interruption: (any Error)?
    }

    /// Reads the snapshot now and then once a `pollInterval` until it says the safe state, or
    /// until `window` has passed.
    ///
    /// The first read is immediate. The last is the first one taken at or after the end of the
    /// window, so a window of ten seconds reads at 0, 1, … 10 s — eleven reads — and a helper
    /// that settles at the tenth second is still seen to.
    ///
    /// **It never sends anything.** The request for the safe state is the caller's, made once
    /// before this is called: a loop that re-sent it while waiting would be a tug-of-war with
    /// whoever else writes (ADR 0011 D2).
    ///
    /// **The deadline is minted here, from `clock`,** and compared here, against the same
    /// clock. A deadline handed in by a caller would be an instant minted somewhere else, and
    /// under a clock that does not move it is a comparison that can never fire.
    static func settle(
        reading read: () async throws -> SystemSnapshot,
        clock: SettleClock
    ) async -> Settlement {
        let deadline = clock.now() + window
        var polls = 0
        var latest: SystemSnapshot?
        while true {
            let snapshot: SystemSnapshot
            do {
                snapshot = try await read()
            } catch {
                return Settlement(
                    verdict: .notConfirmed, snapshot: latest, polls: polls, interruption: error)
            }
            polls += 1
            latest = snapshot

            let current = verdict(for: snapshot)
            if current == .automatic || clock.now() >= deadline {
                return Settlement(
                    verdict: current, snapshot: snapshot, polls: polls, interruption: nil)
            }
            do {
                try await clock.sleep(pollInterval)
            } catch {
                return Settlement(
                    verdict: .notConfirmed, snapshot: snapshot, polls: polls, interruption: error)
            }
        }
    }
}

/// How the wait tells time and waits.
///
/// Closures, and `Decodable` by hand, for the same reasons `HelperConnection` and `Terminal`
/// are: swift-argument-parser decodes every stored property of a command, this one included,
/// and a command that must be driven by a test needs a seam that is not an argument. Answering
/// with `production` whatever the decoder holds is what keeps a flag from ever reaching it.
///
/// `ContinuousClock.Instant`, as the helper's own `MonotonicClock` is: the wait is measured on
/// a clock that counts time asleep and cannot be stepped, never on wall time.
struct SettleClock: Decodable, Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (Duration) async throws -> Void

    init(
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    init(from decoder: Decoder) throws {
        self = .production
    }

    static let production = SettleClock(
        now: { ContinuousClock.now },
        sleep: { try await ContinuousClock().sleep(for: $0) })
}
