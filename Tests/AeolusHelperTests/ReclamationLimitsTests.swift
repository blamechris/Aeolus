import Testing

@testable import AeolusHelper

/// § 5's constants, bounded from **above**.
///
/// ## Why driving the mechanism is not enough
///
/// Every other test of these numbers drives the watchdog to its threshold and counts real
/// cycles, deriving both the loop bound and the expectation from the constant. That is the
/// right shape for asking whether the mechanism honours its constant, and it is exactly why
/// raising one changes nothing: the test moves with it. #136 stated that as a virtue —
/// *"changing a constant changes what the test observes without changing whether it
/// passes"* — and the second half of that sentence is what left these unpinned. Measured on
/// a full green suite: `reassertAttemptBudget` 3 → 300, `blindCyclesBeforeDivergence`
/// 3 → 300 and `actualDwellCycles` 5 → 300 each survived.
///
/// The downward direction is already pinned by those driven tests, and upward is the
/// safety-relevant direction. At the supervisor's 1 Hz a constant of 300 is **five minutes**
/// fighting the operating system for a fan, or five minutes blind with a fan pinned before
/// it is handed back. Only a literal catches that, because only a literal fails to move.
///
/// ## Ceilings, not restatements
///
/// Each bound is well clear of the shipped value on purpose. An assertion of equality would
/// be this file agreeing with the constant it is watching — a second copy of the number,
/// updated in the same commit that changed the first, catching nothing. A ceiling is
/// crossed by a change that alters what the mechanism is *for* and not by ordinary tuning,
/// which is the only distinction worth a test here. Each carries the 1 Hz arithmetic that
/// picked it, so a future editor raising one has to argue with a stated consequence rather
/// than with a bare number.
@Suite("§ 5's constants, bounded from above")
struct ReclamationLimitsTests {

    /// Three attempts, five seconds of fighting at most.
    ///
    /// Each attempt is a fresh envelope read plus two writes on the same cycle, so the
    /// budget is the number of consecutive 1 Hz cycles § 5 will contest a fan before
    /// falling back to automatic control and telling the user. A machine whose firmware
    /// silently discards every write has to *end up* on automatic control, not stay in a
    /// contest it cannot win.
    @Test("The re-assert budget stays a few seconds of fighting, not minutes of it")
    func theReassertBudgetIsBoundedAbove() {
        #expect(
            ReclamationLimits.reassertAttemptBudget <= 5,
            """
            at the supervisor's 1 Hz this is how many seconds § 5 fights the OS for a fan \
            before falling back to automatic control
            """)
    }

    /// Three blind cycles, five seconds at most.
    ///
    /// The threshold buys tolerance of noise — one missed read, or two, must not take a fan
    /// from a client. What it spends is time with a fan pinned at a speed nobody can any
    /// longer observe, which is ADR 0007's hole 2. Minutes of that is not patience, it is
    /// the unbounded retry the escalation exists to replace.
    @Test("Blindness escalates within seconds, never after minutes of a pinned fan")
    func theBlindCycleThresholdIsBoundedAbove() {
        #expect(
            ReclamationLimits.blindCyclesBeforeDivergence <= 5,
            """
            at 1 Hz this is how many seconds a fan stays pinned on a machine § 5 cannot see \
            before it is restored and reported
            """)
    }

    /// Five cycles, ten seconds at most.
    ///
    /// The dwell only ever delays a **report** — the secondary signal reaches no terminal
    /// action — so the cost of raising it is that the user is told later, not that anything
    /// unsafe happens. Later still has a limit: § 8's full-scale ramp is 22 seconds, and a
    /// dwell allowed to approach that would mean a fan that cannot reach its commanded speed
    /// is only ever announced after the ramp that provoked the question has finished.
    @Test("The secondary signal's dwell stays well inside § 8's full-scale ramp")
    func theActualDwellIsBoundedAbove() {
        #expect(
            ReclamationLimits.actualDwellCycles <= 10,
            """
            at 1 Hz this is how long a fan is short of its commanded speed before the user \
            is told, and § 8's full-scale ramp is 22 seconds
            """)
    }
}
