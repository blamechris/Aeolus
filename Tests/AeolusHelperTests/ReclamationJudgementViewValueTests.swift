import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// [#383](https://github.com/blamechris/Aeolus/issues/383)'s record half, as values: what an
/// examination may read a fan as holding. The examination's stamp carries the target last
/// reported, an announced step is held until a report closes it, and only a `.targetDiverged`
/// reading is ever held. A held reading concludes nothing, and an announced step holds one
/// reading until a report of it gives the credit back (#390). The actor's half, each step landed
/// around a real read, is `ReclamationJudgementViewTests` and `ReclamationAnnouncementCreditTests`.
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
    /// alone (`examinedCommanded ?? commanded`); K, a held reading answered as `.converged`; SPO,
    /// a reading the opening target holds spending the announcement's credit (#390). Run: red on
    /// each.
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
            "holding the opening target spent the announcement's credit")
    }

    /// **Mutations:** M2, drop `announced` from `HeldFan.holds(_:readFrom:)`; M3, make
    /// `Registry.announce(_:)` record nothing; M5, leave `announced` set in `HeldFan.command(_:)`;
    /// K. Run: red on each. M5 survived this test as #383 wrote it once the credit existed: the
    /// spent credit kept the unclosed announcement from holding, a downstream guard masking the
    /// upstream one, so the announcement it closes is now one with its credit unspent (#390).
    @Test("An announced step is held until a report closes it")
    func anAnnouncedStepIsHeldUntilAReportClosesIt() {
        var registry = registered()
        registry.command(target(2_400), ofFan: 0)
        _ = registry.beginExamination(ofFan: 0)
        registry.announce(target(2_000))

        #expect(registry.judge(reading(2_000), ofFan: 0) == .held, "the announced step")

        // Its own report gives the credit back, so the next announcement is closed by a report
        // with the credit unspent: what keeps it from holding is the close, and nothing after it.
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

    /// **Mutations:** C1, no credit at all (`holds(_:readFrom:)` never sets `announcementSpent`);
    /// B, a fresh announcement renews it (`announcementSpent = false` in `Registry.announce`); R,
    /// any report renews it (the match dropped from `HeldFan.command(_:)`); N, no report renews
    /// it (the reset deleted). Run: red on each, at the assertion that names it.
    @Test("An announcement holds one reading until a report of its own step confirms it")
    func anAnnouncementHoldsOneReadingUntilAReportConfirmsIt() {
        var registry = registered()
        registry.command(target(2_400), ofFan: 0)
        registry.announce(target(2_000))
        _ = registry.beginExamination(ofFan: 0)
        #expect(registry.judge(reading(2_000), ofFan: 0) == .held, "the announced step")

        let unheld = ReclamationDivergence.targetDiverged(commanded: 2_400, readBack: 2_000)
        _ = registry.beginExamination(ofFan: 0)
        #expect(registry.judge(reading(2_000), ofFan: 0) == .diverged(unheld), "C1: held twice")

        registry.announce(target(2_000))
        _ = registry.beginExamination(ofFan: 0)
        #expect(registry.judge(reading(2_000), ofFan: 0) == .diverged(unheld), "B: renewed")

        registry.command(target(2_100), ofFan: 0)
        registry.announce(target(1_900))
        _ = registry.beginExamination(ofFan: 0)
        #expect(
            registry.judge(reading(1_900), ofFan: 0)
                == .diverged(.targetDiverged(commanded: 2_100, readBack: 1_900)),
            "R: a report of another target confirmed the announcement")

        registry.command(target(1_900), ofFan: 0)
        registry.announce(target(1_800))
        _ = registry.beginExamination(ofFan: 0)
        #expect(registry.judge(reading(1_800), ofFan: 0) == .held, "N: its own report did not")
    }

    /// **Mutation:** S2, `.held` replaced by the converged path (`primary = nil` and fall
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
