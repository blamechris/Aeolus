import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// [#383](https://github.com/blamechris/Aeolus/issues/383)'s record half, as values: what an
/// examination may read a fan as holding. The examination's stamp carries the target last
/// reported, an announced step is held until a report closes it, and only a `.targetDiverged`
/// reading is ever excused. The actor's half, each step landed around a real read, is
/// `ReclamationJudgementViewTests`.
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

    /// **Mutations:** M1, drop `examinedCommanded` from `HeldFan.couldHaveBeenHolding(_:)`; M6,
    /// stamp `examinedCommanded` only once (`if examinedCommanded == nil`); M9, excuse any
    /// `.targetDiverged` while the record's target has moved since the stamp; M10, accept any
    /// reading between the stamp's target and the record's; M11, judge against the stamp's target
    /// alone (`examinedCommanded ?? commanded`). Run: red on each.
    @Test("An examination reads the fan as holding the target reported as it began, and only then")
    func theOpeningTargetIsHeldForThatExaminationOnly() {
        var registry = registered()
        registry.command(target(2_400), ofFan: 0)
        _ = registry.beginExamination(ofFan: 0)
        registry.command(target(2_000), ofFan: 0)

        #expect(registry.judge(reading(2_400), ofFan: 0) == .converged, "the opening target")
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
    }

    /// **Mutations:** M2, drop `announced` from `HeldFan.couldHaveBeenHolding(_:)`; M3, make
    /// `Registry.announce(_:ofFan:)` record nothing; M5, leave `announced` set in
    /// `HeldFan.command(_:)`; M9; M10. Run: red on each.
    @Test("An announced step is held until a report closes it")
    func anAnnouncedStepIsHeldUntilAReportClosesIt() {
        var registry = registered()
        registry.command(target(2_400), ofFan: 0)
        _ = registry.beginExamination(ofFan: 0)
        registry.announce(target(2_000), ofFan: 0)

        #expect(registry.judge(reading(2_000), ofFan: 0) == .converged, "the announced step")

        registry.command(target(2_100), ofFan: 0)
        _ = registry.beginExamination(ofFan: 0)
        #expect(
            registry.judge(reading(2_000), ofFan: 0)
                == .diverged(.targetDiverged(commanded: 2_100, readBack: 2_000)),
            "a report did not close the announcement")
    }

    /// **Mutations:** M7, delete the "began with nothing commanded" excuse from
    /// `HeldFan.couldHaveBeenHolding(_:)`; M8, widen the excuse in `HeldFan.judge(_:)` past
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
}
