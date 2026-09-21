import FanKit
import Foundation

/// The handback ledger: a fan whose return to automatic control did not go cleanly, and
/// everything that follows from that.
///
/// Split out of `LeaseLog.swift` by [#272](https://github.com/blamechris/Aeolus/issues/272);
/// see that file for the type's declaration and the two `describe` helpers this extension
/// calls.
extension LeaseLog {

    /// The restore did not take, the attempts are spent, and the helper has stopped asking.
    ///
    /// `.fault`, and it is the line `restored(fans:because:)` above must be read against:
    /// that one is written before the write is attempted, so for this fan it says something
    /// that turned out not to be true. Correcting the record is exactly what this level is
    /// for — a user asking why a fan can no longer be controlled has this line as the
    /// answer, and nothing else in the log says it.
    ///
    /// **It states the helper's uncertainty rather than a destination.** An earlier version
    /// closed by asserting the fan was under the system's own thermal management — the very
    /// state the write that just failed was trying to establish, and a claim `CLAUDE.md`
    /// rule 6 forbids. `SafetyLog.reclamationFanMayStillBePinned` already says the true
    /// thing about the identical event next door, so the two now agree.
    ///
    /// **It has exactly one producer, and that is what keeps the sentence true.** Only
    /// `BoundedFanRestorer` writes this line, and only once the firmware has refused
    /// `RestoreLimits.attemptBudget` attempts — so "Aeolus has stopped trying" reports
    /// something observed. `docs/SAFETY.md` § 4's acknowledgement budget used to reach the
    /// same durable state by another route, and this line would have been untrue of the fans
    /// it covered: the helper had stopped *waiting*, which is not the same as having stopped
    /// trying, and no attempt count or firmware error existed to name. Since ADR 0007,
    /// amendment 2026-09-06 (#209) that path records
    /// `ManualControlAvailability.Reason.handbackUnconfirmed` and writes
    /// `SafetyLog.allowingSleepWithHandbackUnconfirmed(after:leaving:)` instead, so the two
    /// stay distinguishable in `log show`.
    func abandonedHandback(
        fanAt index: Int, because cause: FanRestoreCause, after attempts: Int, error: any Error
    ) {
        log.fault(
            """
            Fan \(index, privacy: .public) could not be returned to automatic control \
            (\(Self.describe(cause), privacy: .public)) after \(attempts, privacy: .public) \
            attempts: \(String(describing: error), privacy: .public). Aeolus has stopped \
            trying and will refuse manual control of this fan. It may still be under manual \
            control at a speed Aeolus is no longer tracking. Check the fan physically, and \
            see docs/RECOVERY.md.
            """
        )
    }

    /// A fan the helper had given up on went back after all, and the durable refusal is gone.
    ///
    /// The correction to `abandonedHandback(fanAt:because:after:error:)` above — a `.fault`
    /// telling the reader Aeolus has stopped trying and they should check the fan physically and
    /// read `docs/RECOVERY.md`. Without this line the log's last word on the fan is that advice,
    /// and a user following it would be acting on a refusal that no longer exists. `.notice` for
    /// `restored(fans:because:)`'s reason: nothing is wrong here.
    ///
    /// **It reports a read-back, not only a write** (#291). `FanRestoring` promises a return
    /// and never a read-back, so until #291 "the write was not refused this time" was the whole
    /// of what the helper knew and this line said no more. The refusal is now lifted only after
    /// a fresh read reports the fan automatic, so that is what this line reports — at the
    /// instant of the read, which is all any read can say.
    func recoveredAbandonedHandback(fans: Set<Int>) {
        log.notice(
            """
            Fan(s) \(Self.describe(fans), privacy: .public), whose earlier handback Aeolus \
            gave up on, were handed back without being refused and have now read back under \
            automatic control. The durable refusal over them is lifted and manual control of \
            them may be taken again.
            """
        )
    }

    /// A fan the helper had given up on took the write this time — which lifts nothing yet.
    ///
    /// `.notice`. The refusal stands until `confirmAcceptedHandbacks()` reads the fan back
    /// automatic (#291); this line exists so a reader who sees the handback go through is not
    /// left believing the refusal lifted with it.
    func abandonedHandbackAcceptedUnconfirmed(fans: Set<Int>, because cause: FanRestoreCause) {
        log.notice(
            """
            Fan(s) \(Self.describe(fans), privacy: .public) were handed back without being \
            refused this time (\(Self.describe(cause), privacy: .public)), after an earlier \
            handback Aeolus gave up on. The write was accepted but not yet read back, so the \
            durable refusal over them stands until docs/SAFETY.md § 7's restore confirms it.
            """
        )
    }

    /// A fan owed a read-back did not read back automatic, so its durable refusal stands.
    ///
    /// `.notice`, not `.fault`: the fault was `abandonedHandback`, and nothing got worse. It
    /// names no cause: a fan still reading manual after an accepted write may be firmware that
    /// did not apply it, a write that has not settled, or another program — and one read
    /// cannot tell them apart.
    func abandonedHandbackStillUnconfirmed(fans: Set<Int>) {
        log.notice(
            """
            Fan(s) \(Self.describe(fans), privacy: .public) were handed back without being \
            refused after an earlier handback Aeolus gave up on, but did not read back under \
            automatic control. The durable refusal over them stands.
            """
        )
    }

    /// A client asked for a fan whose handback was given up on.
    ///
    /// `.notice` rather than `.fault`: the fault was logged once, where it happened. This is
    /// a client meeting the consequence, and it is worth persisting because a client that
    /// sees it repeatedly is the evidence that the durable refusal is durable — which is the
    /// half of [#110](https://github.com/blamechris/Aeolus/issues/110) a client can see.
    func refusedAbandonedHandback(_ connection: ConnectionID, fans: Set<Int>) {
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) asked for fan(s) \
            \(Self.describe(fans), privacy: .public) that Aeolus could not return to \
            automatic control. Refused: their mode is not what the helper last asked for, \
            and a lease over one would be claiming control nothing has confirmed.
            """
        )
    }

    /// A restore ran before the safety registries were bound to the restorer.
    ///
    /// `.fault`, and it should never appear: `HelperComposition.bringUp()` binds them as its
    /// first act, before either supervisor starts and long before `listener.resume()`
    /// advertises the Mach service, so nothing can reach a teardown path in the window this
    /// line describes. It exists because the alternative to logging an impossible state is
    /// not noticing it — the restore itself still runs, because
    /// [ADR 0007](../../../docs/ADR/0007-safety-composition.md)'s keystone must never be
    /// gated on bookkeeping.
    func restoredWithoutSafetyRegistries(fans: Set<Int>, because cause: FanRestoreCause) {
        log.fault(
            """
            Fan(s) \(Self.describe(fans), privacy: .public) were restored \
            (\(Self.describe(cause), privacy: .public)) before the safety registries were \
            bound. The restore ran; §3 and §5 were not told, so a fan may be left in a \
            registry it has already gone back to automatic from.
            """
        )
    }

    /// A refusal that resolves itself in milliseconds, so it is worth being able to tell
    /// apart from the ones that do not. A client seeing this repeatedly is watching a
    /// restore that never completes, which is a different and much worse fault.
    func refusedMidHandback(_ connection: ConnectionID, fans: Set<Int>) {
        // `.notice` rather than `.info`, for the reason the doc comment above gives: `.info`
        // is not persisted by default, so the repeated-refusal evidence would not be there
        // when someone went looking for it. Same argument that promoted `refusedInFlightBinding`.
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) asked for fans \
            \(fans.sorted().map(String.init).joined(separator: ", "), privacy: .public) \
            while their restore to automatic is still in flight. Refused: a lease granted \
            now would be overwritten by that restore.
            """
        )
    }

    /// A client asked for a fan whose handback the helper stopped waiting for.
    ///
    /// `docs/SAFETY.md` § 4's budget expired with this fan's restore still outstanding, and
    /// nothing has answered for it since. Beside `refusedMidHandback` deliberately: the two
    /// are the same fan in the same register — `handbackUnconfirmed` is a subset of
    /// `releasing` — and what separates them is how long the restore has been out. That one
    /// is worth writing because a client seeing it repeatedly has found a restore that never
    /// completes; this one *is* that fault, already diagnosed.
    ///
    /// `.notice` for `refusedMidHandback`'s reason: `.info` is not persisted by default, and
    /// the repeated-refusal evidence has to be there when somebody goes looking. Not
    /// `.fault` — the fault was written once, by § 4, where the budget expired.
    ///
    /// The wording says what a client should do, because the answer differs from the one next
    /// door in the way that matters most: a restart is the route out of a refused handback
    /// and is the wrong action here.
    func refusedUnconfirmedHandback(_ connection: ConnectionID, fans: Set<Int>) {
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) asked for fan(s) \
            \(Self.describe(fans), privacy: .public) whose return to automatic control the \
            helper stopped waiting for when the pre-sleep budget expired. Refused: the \
            restore is still outstanding and nothing has confirmed the fan's mode, so a \
            lease over it would be claiming control nothing has answered for. It may clear \
            on its own when that restore returns; if it stands across a wake, the restore \
            never returned, and a helper restart — whose startup reconciliation reads every \
            fan's mode — is the route out, as it is for a refused handback.
            """
        )
    }
}
