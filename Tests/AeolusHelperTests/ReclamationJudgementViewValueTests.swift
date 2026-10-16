import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// [#383](https://github.com/blamechris/Aeolus/issues/383)'s record half, as values: what an
/// examination may read a fan as holding. The examination's stamp carries the target last
/// reported, an announced step is held until a report closes it, and only a `.targetDiverged`
/// reading is ever held. A held reading concludes nothing, and the next judgement settles every
/// hold: vindicated if it read an announced step that is the record when that examination begins,
/// and its target barred until an examination converges on the record otherwise (#390). The
/// actor's half, each step landed around a real read, is `ReclamationJudgementViewTests`,
/// `ReclamationAnnouncementCreditTests` and `ReclamationHoldSettlementTests`.
///
/// Every assertion names the mutation it kills, and each was run. The mutations are numbered as
/// the actor suite numbers them.
@Suite("§ 5's judgement view, as a value")
struct ReclamationJudgementViewValueTests {

    private typealias Registry = ReclamationWatchdog<ScriptedControlPlane>.Registry

    private let lease = UUID()

    private func target(_ rpm: Double) -> CommandedTarget { CommandedTarget(fanIndex: 0, rpm: rpm) }

    private func reading(_ rpm: Double, mode: FirmwareFanMode = .manual) -> FanControlState {
        FanControlState(index: 0, mode: mode, target: .rpm(rpm), actualRPM: .rpm(rpm))
    }

    /// Fan 0 registered under `lease`, with nothing commanded on it.
    private func registered() -> Registry {
        var registry = Registry()
        _ = registry.register(lease, fanAt: 0, live: true, since: registry.generation(ofFan: 0))
        return registry
    }

    /// **Mutations:** M1, drop `examinedCommanded` from `HeldFan.holds(_:readFrom:)`; M6, stamp
    /// `examinedCommanded` only once (`if examinedCommanded == nil`); M9, excuse any
    /// `.targetDiverged` while the record's target has moved since the stamp; M10, accept any
    /// reading between the stamp's target and the record's; M11, judge against the stamp's target
    /// alone (`examinedCommanded ?? commanded`); K, a held reading answered as `.converged`; M2,
    /// at the last assertion: an announced step held once the opening target's hold is settled
    /// (#390). Run: red on each.
    @Test("An examination reads the fan as holding the target reported as it began, and only then")
    func theOpeningTargetIsHeldForThatExaminationOnly() {
        var registry = registered()
        registry.command(target(2_400), ofFan: 0)
        _ = registry.beginExamination(ofFan: 0)
        registry.command(target(2_000), ofFan: 0)

        #expect(registry.judge(reading(2_400), ofFan: 0) == .held, "the opening target")
        #expect(registry.judge(reading(2_000), ofFan: 0) == .converged, "the current target")
        #expect(
            registry.judge(reading(2_200), ofFan: 0)
                == .diverged(.targetDiverged(commanded: 2_000, readBack: 2_200)),
            "a target between the two")

        _ = registry.beginExamination(ofFan: 0)
        #expect(
            registry.judge(reading(2_400), ofFan: 0)
                == .diverged(.targetDiverged(commanded: 2_000, readBack: 2_400)),
            "the next examination still read the fan as holding a superseded target")

        registry.announce(target(1_900))
        #expect(
            registry.judge(reading(1_900), ofFan: 0) == .held,
            "the opening target's hold refused a later announced step")
    }

    /// **Mutations:** M2, drop `announced` from `HeldFan.holds(_:readFrom:)`; M3, make
    /// `Registry.announce(_:)` record nothing; M5, leave `announced` set in `HeldFan.command(_:)`;
    /// K. Run: red on each. M5 survived this test as #383 wrote it under #390's first fold, whose
    /// spent credit kept the unclosed announcement from holding, a downstream guard masking the
    /// upstream one. The bar the first hold leaves is at 2,000, not at the announcement's 1,900, so
    /// nothing downstream of the close refuses that reading (#390).
    @Test("An announced step is held until a report closes it")
    func anAnnouncedStepIsHeldUntilAReportClosesIt() {
        var registry = registered()
        registry.command(target(2_400), ofFan: 0)
        _ = registry.beginExamination(ofFan: 0)
        registry.announce(target(2_000))

        #expect(registry.judge(reading(2_000), ofFan: 0) == .held, "the announced step")

        // The step is reported and superseded before the next examination, so its hold is barred
        // at 2,000; what keeps the next announcement from holding is the close, and nothing after.
        registry.command(target(2_000), ofFan: 0)
        registry.announce(target(1_900))
        registry.command(target(2_100), ofFan: 0)
        _ = registry.beginExamination(ofFan: 0)
        #expect(
            registry.judge(reading(1_900), ofFan: 0)
                == .diverged(.targetDiverged(commanded: 2_100, readBack: 1_900)),
            "a report did not close the announcement")
    }

    /// **Mutations:** M7, delete the "began with nothing commanded" excuse from
    /// `HeldFan.holds(_:readFrom:)`; M8, widen the hold in `HeldFan.holds(_:readFrom:)` past
    /// `.targetDiverged`; M13, M8 with the candidates compared on raw RPM. Run: red on each. The
    /// actor suite's reclaimed-mode test survives M8 alone, because
    /// `primaryDivergence(of:against:)` refuses a reclaimed mode downstream of the excuse; the last
    /// assertion here does not.
    @Test("An examination begun with nothing commanded judges the mode and no target")
    func anExaminationBegunUncommandedJudgesOnlyTheMode() throws {
        var registry = registered()
        _ = registry.beginExamination(ofFan: 0)
        registry.command(target(2_000), ofFan: 0)

        let first = registry.judge(reading(1_350), ofFan: 0)
        #expect(first != .diverged(.targetDiverged(commanded: 2_000, readBack: 1_350)))
        #expect(try #require(registry.record(ofFan: 0)).uncommandedDivergentCycles == 0)
        #expect(
            registry.judge(reading(1_350, mode: .automatic), ofFan: 0)
                == .diverged(.modeReclaimed), "the mode was excused")
    }

    // MARK: - #390

    /// **Mutations:** Q1, a hold never barred (`barred = held` deleted from `settleLastHold`); Q2,
    /// the bar never consulted in `holds(_:readFrom:)`; Q3, the bar lifted by any judgement that
    /// holds nothing, not only one that converges; Q4, the bar never lifted; Q8, a hold that is
    /// not vindicated refusing every hold of the next examination rather than its own target. Run:
    /// red on each, at the assertion that names it.
    @Test("A hold the next examination does not vindicate bars its target until convergence")
    func anUnvindicatedHoldIsBarredUntilConvergence() {
        var registry = registered()
        registry.command(target(2_400), ofFan: 0)
        registry.announce(target(2_000))
        _ = registry.beginExamination(ofFan: 0)
        #expect(registry.judge(reading(2_000), ofFan: 0) == .held, "the announced step")

        // Codex's sequence: the step is reported, and then another, before § 5 looks again.
        registry.command(target(2_000), ofFan: 0)
        registry.command(target(2_400), ofFan: 0)
        let unheld = ReclamationDivergence.targetDiverged(commanded: 2_400, readBack: 2_000)
        registry.announce(target(2_000))
        _ = registry.beginExamination(ofFan: 0)
        #expect(registry.judge(reading(2_000), ofFan: 0) == .diverged(unheld), "Q1/Q2: held again")

        registry.announce(target(2_000))
        _ = registry.beginExamination(ofFan: 0)
        #expect(registry.judge(reading(2_000), ofFan: 0) == .diverged(unheld), "Q3: bar lifted")

        registry.announce(target(1_900))
        _ = registry.beginExamination(ofFan: 0)
        #expect(registry.judge(reading(1_900), ofFan: 0) == .held, "Q8: another target refused")

        registry.command(target(1_900), ofFan: 0)
        _ = registry.beginExamination(ofFan: 0)
        #expect(registry.judge(reading(1_900), ofFan: 0) == .converged)
        registry.command(target(2_400), ofFan: 0)
        registry.announce(target(2_000))
        _ = registry.beginExamination(ofFan: 0)
        #expect(registry.judge(reading(2_000), ofFan: 0) == .held, "Q4: convergence kept the bar")
    }

    /// A loop on A6's contract holds every reading of a ramp in either phase, and across a drift
    /// between them, because the next examination vindicates each hold.
    ///
    /// **Mutations:** Q6, the vindication ignored (an announced step is barred even when it is the
    /// record as the next examination begins); Q8. Run: red on each.
    @Test("Each hold of a ramp is vindicated by the next examination, in either phase")
    func eachHoldOfARampIsVindicated() {
        var registry = registered()
        registry.command(target(2_400), ofFan: 0)
        // Reverse: each step is announced and read before its report, which then lands.
        for step in [2_200.0, 2_000, 1_800] {
            registry.announce(target(step))
            _ = registry.beginExamination(ofFan: 0)
            #expect(registry.judge(reading(step), ofFan: 0) == .held, "reverse step \(step)")
            registry.command(target(step), ofFan: 0)
        }
        // A drift to forward: the next step's report lands after the read, which reads the step
        // just held again (Q6); an oscillation holds each of its two targets in turn.
        for (read, next) in [(1_800.0, 2_000.0), (2_000, 1_800), (1_800, 2_000)] {
            _ = registry.beginExamination(ofFan: 0)
            registry.command(target(next), ofFan: 0)
            #expect(registry.judge(reading(read), ofFan: 0) == .held, "forward read \(read)")
        }
        // A drift back to reverse: the last hold, at 1,800, is barred, and the new step is held
        // all the same, because only 1,800 is (Q8).
        registry.announce(target(2_200))
        _ = registry.beginExamination(ofFan: 0)
        #expect(registry.judge(reading(2_200), ofFan: 0) == .held, "a drift to reverse")
    }

    /// **Mutation:** K, `.held` replaced by the converged path (`primary = nil` and fall
    /// through), which closes the episode and refills the budget from a reading the record does
    /// not hold. Run: red.
    @Test("A held reading moves no counter, closes no episode and refills nothing")
    func aHeldReadingMovesNothing() {
        var fan = ReclamationWatchdog<ScriptedControlPlane>.HeldFan(lease: lease)
        fan.command(target(2_400))
        fan.beginExamination(atGeneration: 0)
        fan.episodeInFlight = true
        fan.reassertAttempts = 2
        fan.actualDwellCycles = 1
        fan.announced = target(3_000)

        let reading = FanControlState(
            index: 0, mode: .manual, target: .rpm(3_000), actualRPM: .rpm(2_400))
        #expect(fan.judge(reading) == .held)
        #expect(fan.episodeInFlight, "a held reading closed the episode")
        #expect(fan.reassertAttempts == 2, "a held reading refilled the budget")
        #expect(fan.actualDwellCycles == 1, "a held reading moved the dwell")
    }

    /// **Mutation:** N1, the `examinedAtGeneration != nil` conjunct deleted from
    /// `HeldFan.holds(_:readFrom:)`. Run: red.
    @Test("A judgement with no examination's stamp holds nothing")
    func aJudgementWithNoStampHoldsNothing() {
        var fan = ReclamationWatchdog<ScriptedControlPlane>.HeldFan(lease: lease)
        fan.command(target(2_400))
        let unheld = ReclamationDivergence.targetDiverged(commanded: 2_400, readBack: 2_000)
        #expect(fan.judge(reading(2_000)) == .diverged(unheld))
    }

    /// **Mutation:** S1, `primaryDivergence(of:against:)`'s comparison restored to
    /// `guard abs(...) > tolerance else { return nil }`, under which a target that is not a number
    /// reads every reading back. Run: red on both.
    @Test("A target that is not a number holds no reading, and a reading diverges from it")
    func aTargetThatIsNotANumberHoldsNothing() {
        var fan = ReclamationWatchdog<ScriptedControlPlane>.HeldFan(lease: lease)
        fan.command(target(2_400))
        fan.beginExamination(atGeneration: 0)
        fan.announced = target(.nan)
        let unheld = ReclamationDivergence.targetDiverged(commanded: 2_400, readBack: 1_800)
        #expect(fan.judge(reading(1_800)) == .diverged(unheld), "a NaN announcement held a reading")
        let againstNaN = ReclamationWatchdog<ScriptedControlPlane>.primaryDivergence(
            of: reading(1_800), against: target(.nan))
        #expect(againstNaN != nil, "a target that is not a number converged")
    }
}
