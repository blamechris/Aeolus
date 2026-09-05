import Foundation

/// One attempt at the keystone write, for one fan.
///
/// The narrowest seam that can be retried: an index in, a throw or nothing out. It is
/// deliberately *not* `FanControlPlane` — the lease core asks for what it uses, and what
/// `BoundedFanRestorer` uses is "try this fan once, tell me if it did not take". Which
/// `FanRestoreScope` a production conformer reaches for, and whether it clears the Apple
/// Silicon force key along the way, stays
/// [#102](https://github.com/blamechris/Aeolus/issues/102)'s decision rather than being
/// pre-empted by the type that counts the attempts.
///
/// [ADR 0007](../../../docs/ADR/0007-safety-composition.md)'s keystone applies here
/// unchanged: no bound, no clamp, no sensor reading and no lease crosses this signature, so
/// the attempt stays available in the one case it exists for — the helper that cannot read.
protocol FanRestoreAttempting: Sendable {

    /// Attempts to return one fan to the system's own thermal management, once.
    ///
    /// Throwing means the firmware did not take the write. It does **not** mean the fan is
    /// manual: a refused restore of a fan that was already automatic is a no-op that
    /// happened to fail, which is why the caller retries rather than concluding anything.
    func restoreOnce(fanAt index: Int) async throws
}

/// The bounds on a handback.
///
/// A sibling of `ReclamationLimits`, kept apart from it for the reason
/// `docs/SAFETY.md` § 5's own budget exists: these are the numbers a reviewer has to be
/// able to find and argue with, and burying them at the point of use is how a retry loop
/// becomes an unbounded one without anybody choosing that.
enum RestoreLimits {

    /// How many times a restorer will try to hand one fan back before reporting that it
    /// could not.
    ///
    /// Three, matching `ReclamationLimits.reassertAttemptBudget` — the same firmware, the
    /// same kind of mode write, and no reason for a reader to have to remember two numbers.
    /// The floor is different, and that difference is the whole of
    /// [#110](https://github.com/blamechris/Aeolus/issues/110): § 5's budget falls back to
    /// *restore*, and this one cannot, because restore is what has just failed. Its floor is
    /// therefore **report** — say which fan, and refuse to pretend it came back.
    ///
    /// There is no delay between attempts, deliberately. A restore is a mode write rather
    /// than a contest to be waited out, the caller is a teardown path on a safety actor's
    /// cycle, and a sleep here would buy an unmeasured chance of success with a measured
    /// delay to `ReclamationSupervisor`'s next cycle for every other fan.
    static let attemptBudget = 3
}

/// A `FanRestoring` that gives up, and says so.
///
/// The shipped answer to [#110](https://github.com/blamechris/Aeolus/issues/110). It spends
/// `RestoreLimits.attemptBudget` attempts **per fan**, stops on the first that the firmware
/// takes, and returns the fans it never managed to hand back. `LeaseAuthority` turns that
/// set into a durable refusal; see `FanRestoring`'s contract for why returning at all is the
/// load-bearing property.
///
/// **Per fan, not per call**, because the refusal it feeds is per fan. A single budget
/// shared across the set would let one stubborn fan spend the attempts of every other fan
/// in the same teardown, and the fans that were never tried would then be reported as
/// abandoned — a lie in the safe direction, which is still a lie a client acts on.
///
/// A `struct` over a `Sendable` attempt seam: it holds no mutable state of its own, so two
/// teardown paths restoring the same fan at the same instant need no isolation here. The
/// overlap they can produce is handled where it matters, in `LeaseAuthority.restore`.
struct BoundedFanRestorer<Attempting: FanRestoreAttempting>: FanRestoring {

    private let attempting: Attempting
    private let log: LeaseLog

    init(attempting: Attempting, log: LeaseLog = LeaseLog()) {
        self.attempting = attempting
        self.log = log
    }

    func restoreToAutomatic(fans: Set<Int>, because cause: FanRestoreCause) async -> Set<Int> {
        var abandoned: Set<Int> = []
        // Sorted so the log reads in fan order and the attempt sequence a test observes is
        // the same one every run. Set iteration order is not a contract.
        for fan in fans.sorted() {
            var lastFailure: (any Error)?
            for _ in 0..<RestoreLimits.attemptBudget {
                do {
                    try await attempting.restoreOnce(fanAt: fan)
                    lastFailure = nil
                    break
                } catch {
                    lastFailure = error
                }
            }
            guard let lastFailure else { continue }
            abandoned.insert(fan)
            log.abandonedHandback(
                fanAt: fan,
                because: cause,
                after: RestoreLimits.attemptBudget,
                error: lastFailure
            )
        }
        return abandoned
    }
}
