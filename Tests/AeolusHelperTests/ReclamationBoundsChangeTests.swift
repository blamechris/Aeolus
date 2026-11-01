import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5's re-assert under firmware bounds that moved since the held target was admitted (PR #676's
/// Codex 3; ADR 0014's minimal-run amendment, item 7's re-ruling, § 4). The re-assert reads a
/// fresh envelope; when its `F<n>Mn` or `F<n>Mx` differs, by exact value, from the bounds the fan
/// was registered under, it writes nothing, logs at `.fault` and takes the give-up path: the fan
/// handed back and the lease ended. A target admitted under one floor is never re-asserted under
/// bounds whose floor is higher.
@Suite("§ 5 gives up a fan whose firmware bounds moved", .timeLimit(.minutes(1)))
struct ReclamationBoundsChangeTests {

    /// Which bound the second stage reads differently, or neither.
    enum Moved: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case maximum, minimum, neither
        var testDescription: String { rawValue }

        /// The stage the re-assert reads its fresh envelope from.
        var stage: ScriptedControlPlane.Stage {
            switch self {
            case .maximum:
                return ScriptedControlPlane.Stage(maximumReads: [0: .reads(6_500)])
            case .minimum:
                var stage = ScriptedControlPlane.Stage(maximumReads: [:])
                stage.minimumReads = [0: .reads(1_400)]
                return stage
            case .neither:
                return .nominal()
            }
        }
    }

    /// Fan 0 is held at 4,228 RPM, the firmware takes it back, and the bounds read then moves.
    /// The re-assert writes neither the mode nor the target, the fan is restored and the lease
    /// ended; with the bounds unchanged, the same scenario re-asserts, so the expectations are
    /// about the bounds and not the scenario.
    ///
    /// **Mutation:** in `ReclamationWatchdog.reassert`, delete the `if let admitted =
    /// registry.boundsChanged(…)` block. Run: red on the maximum and minimum rows, the fan
    /// re-engaged and commanded. **Mutation:** in `Registry.boundsChanged(ofFan:reading:)`, drop
    /// the `declaredMinimumRPM` comparison. Run: red on the minimum row alone.
    @Test(
        "A re-assert under bounds that moved writes nothing and gives the fan up",
        arguments: Moved.allCases)
    func aReassertUnderMovedBoundsGivesTheFanUp(_ moved: Moved) async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(), moved.stage], fans: [0: .automatic(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 4_228)
        await machine.plane.advance()

        await machine.watchdog.cycle()

        let faults = machine.safetyLog.faults.filter { $0.contains("bounds read") }
        switch moved {
        case .maximum, .minimum:
            #expect(
                await machine.attempts.contains(.engageManualControl(fan: 0)) == false,
                "the fan was re-engaged under bounds that moved")
            #expect(await machine.commandedRPMs.isEmpty, "a target was re-asserted")
            #expect(await machine.didRestore(fan: 0), "the fan was not handed back")
            #expect(await machine.leases.leaseCount == 0, "the lease outlived the fan")
            #expect(faults.count == 1, "\(machine.safetyLog.faults)")
        case .neither:
            #expect(await machine.attempts.contains(.engageManualControl(fan: 0)))
            #expect(await machine.commandedRPMs == [4_228])
            #expect(await machine.leases.leaseCount == 1)
            #expect(faults.isEmpty)
        }
    }
}

extension ReclamationWatchdog.Registry {

    /// `register(_:fanAt:live:since:admitting:)` under `Mac16,5`'s declared bounds, 1,350 to
    /// 5,777 RPM, for the value tests that judge registration and not bounds. The actor's own
    /// registration passes the permit's bounds, and `ReclamationBoundsChangeTests` the ones it
    /// scripts.
    mutating func register(
        _ lease: UUID, fanAt index: Int, live: Bool, since generation: UInt64
    ) -> ReclamationWatchdog.Registration {
        register(
            lease, fanAt: index, live: live, since: generation,
            admitting: ReclamationBoundsChangeTests.declaredBounds)
    }
}

extension ReclamationBoundsChangeTests {
    /// `Mac16,5`'s declared bounds, which `validating` accepts.
    static let declaredBounds: FanControlEnvelope = {
        guard
            case .success(let bounds) = FanControlEnvelope.validating(
                declaredMinimumRPM: 1_350, declaredMaximumRPM: 5_777)
        else { preconditionFailure("Mac16,5's declared bounds were refused") }
        return bounds
    }()
}
