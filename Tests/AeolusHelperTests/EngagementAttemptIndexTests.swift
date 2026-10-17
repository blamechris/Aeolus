import Testing

@testable import AeolusHelper

/// Each step's attempt index, logged by the driver before it asks the plane for the step (B1's
/// P0, #9; ADR 0014 D3: "every step logs … the attempt number"). The plane cannot know it, since
/// its step verb takes one permit and nothing else (ADR 0008), so the driver states it and B1's
/// plane's own lines for the step follow.
@Suite("Each engagement step's attempt index", .timeLimit(.minutes(1)))
struct EngagementAttemptIndexTests {

    /// The attempt indices fan 0's engagement logged, in order.
    private static func attempts(in log: RecordedLog) -> [Int] {
        let marker = "Fan 0's engagement asks the plane for one step: attempt "
        return log.lines(containing: marker).compactMap { line in
            line.range(of: marker).flatMap { Int(line[$0.upperBound...].prefix { $0.isNumber }) }
        }
    }

    /// A held fan engaged on its fourth step logs attempts 1 to 4, one per step, before each.
    ///
    /// **Mutation:** in `EngagementDriver.engageManualControl(of:)`, log a constant —
    /// `attempt: 1` in the poll loop's line. Run: red, `[1, 1, 1, 1]`.
    @Test("Every step of an engagement logs its attempt index")
    func everyStepLogsItsAttemptIndex() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 2))

        try await rig.driver.engageManualControl(of: rig.fan(0))

        #expect(await rig.plane.attempts.count == 4, "the scenario is not four steps")
        #expect(Self.attempts(in: rig.log) == [1, 2, 3, 4])
        let notice = SafetyLog.Level.notice
        #expect(
            rig.log.levels(containing: "asks the plane for one step") == [
                notice, notice, notice, notice,
            ])
    }

    /// A first step superseded at its admission is retried as attempt 2, as its own line says, and
    /// the steps after it continue from there.
    ///
    /// **Mutation:** in `EngagementDriver.firstStep(of:)`, log and return the retry as attempt 1.
    /// Run: red, `[1, 1, 2, 3]`.
    @Test("A retried first step is attempt 2, and later steps continue from it")
    func aRetriedFirstStepIsAttemptTwo() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 1), fans: [0, 1])
        await rig.writes.interfere(beforeEngageStep: 1) {
            _ = try? await rig.plane.restoreToAutomatic(.fan(1))
        }

        try await rig.driver.engageManualControl(of: rig.fan(0))

        #expect(await rig.writes.didFire, "the scenario never arranged the interleaving")
        #expect(rig.log.lines(containing: "retrying it once (attempt 2)").count == 1)
        #expect(Self.attempts(in: rig.log) == [1, 2, 3, 4])
        #expect(rig.plane.ledger.engagedFans == [0])
    }
}
