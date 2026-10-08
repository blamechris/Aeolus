import AeolusXPC
import FanKit
import Foundation

@testable import fanctl

/// What the `fanctl set` message and closing-shape suites share: a plan built the way
/// `SetPlan` builds one, a hold over it, and a safe-state settlement.
enum SetFixtures {

    static func plan(
        _ index: Int, _ speed: SetArguments.Speed, minimum: Double = 1350, maximum: Double = 5777
    ) throws -> SetFanPlan {
        let envelope = try FanControlEnvelope.validating(
            declaredMinimumRPM: minimum, declaredMaximumRPM: maximum
        ).get()
        let target: FanTargetRPM
        switch speed {
        case .percent(let percent): target = envelope.target(forPercent: Double(percent))
        case .rpm(let rpm): target = envelope.target(for: Double(rpm))
        }
        return SetFanPlan(index: index, requested: speed, envelope: envelope, target: target)
    }

    static func hold(_ plans: [SetFanPlan], seconds: Int = 1_800) -> SetCommand.Hold {
        SetCommand.Hold(leaseID: UUID(), plans: plans, duration: .seconds(seconds))
    }

    static func settlement(
        _ snapshot: SystemSnapshot?, interruption: (any Error)? = nil,
        verdict: SafeState.Verdict = .notConfirmed
    ) -> SafeState.Settlement {
        SafeState.Settlement(
            verdict: verdict, snapshot: snapshot, polls: 1, interruption: interruption)
    }

    struct Gone: Error, LocalizedError {
        var errorDescription: String? { "the helper went away" }
    }
}
