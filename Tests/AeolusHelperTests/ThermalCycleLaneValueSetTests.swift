import SMCCore
import Testing

@testable import AeolusHelper

/// The lane's two value sets are pinned, so a new case fails to compile until it is placed (ADR
/// 0012's 2026-10-18 amendment).
///
/// Every census in `ThermalCycleLaneTripwireTests` counts a word. A third `PlaneAdmission` mapped
/// to the lane's priority beside `.thermalCycle`, or a fourth `SMCReadPriority` the scheduler
/// queues in the lane, reaches § 3's lane without that word: from any file, at a call site as well
/// as in the composition, with every count unchanged. So both enums are switched over here
/// exhaustively, **with no `default`**. A new case is a compile error in this file until the pin
/// says where it maps, and the pin holds that only `.thermalCycle` reaches the lane. The scheduler
/// keys both its queues and its run-time overlap count on one mapping (`SMCReadScheduler`'s
/// `isLane(_:)`), so a priority placed in the lane there is counted as a lane request too.
@Suite("The lane's admission and priority value sets are pinned", .timeLimit(.minutes(1)))
struct ThermalCycleLaneValueSetTests {

    /// Where each admission's turns must be admitted. No `default`: a new case does not compile.
    private static func pinnedPriority(of admission: PlaneAdmission) -> SMCReadPriority {
        switch admission {
        case .thermalCycle: return .thermalCycle
        case .supervisor: return .supervisor
        }
    }

    /// Whether a priority is § 3's lane. No `default`: a new case does not compile.
    private static func isTheLane(_ priority: SMCReadPriority) -> Bool {
        switch priority {
        case .thermalCycle: return true
        case .supervisor, .snapshot: return false
        }
    }

    /// Exactly two admissions, each admitted where the pin says, and only `.thermalCycle` in the
    /// lane.
    ///
    /// **Mutation:** add `case reassert` to `PlaneAdmission`, mapped with `.thermalCycle` to the
    /// lane. Run: this file does not compile.
    /// **Mutation:** the same, with the pin updated to map it to the lane as well. Run: red — two
    /// admissions reach the lane. (`ThermalCycleLaneWriterTests` is red too, if a writer uses it.)
    /// **Mutation:** map `.supervisor` to `.thermalCycle` in `PlaneAdmission.priority`. Run: red.
    @Test("PlaneAdmission is exactly two cases, and only .thermalCycle is admitted in the lane")
    func theAdmissionsArePinned() {
        #expect(Set(PlaneAdmission.allCases) == [.supervisor, .thermalCycle])
        for admission in PlaneAdmission.allCases {
            #expect(
                admission.priority == Self.pinnedPriority(of: admission),
                "\(admission) is admitted at \(admission.priority)")
        }
        let lane = PlaneAdmission.allCases.filter { Self.isTheLane($0.priority) }
        #expect(lane == [.thermalCycle], "admitted in § 3's lane: \(lane)")
    }

    /// Exactly three priorities, only `.thermalCycle` the lane — and the scheduler queues each
    /// where the pin says: a request at each priority, parked behind a turn in flight, is counted
    /// in its own queue and no other.
    ///
    /// **Mutation:** add `case urgent` to `SMCReadPriority` and queue it in the lane. Run: this
    /// file does not compile.
    /// **Mutation:** in `SMCReadScheduler.queue(for:)`, send `.supervisor` to the lane. Run: red.
    @Test("SMCReadPriority is exactly three cases, and each is queued where the pin says")
    func thePrioritiesArePinned() async throws {
        #expect(Set(SMCReadPriority.allCases) == [.snapshot, .supervisor, .thermalCycle])
        #expect(SMCReadPriority.allCases.count == 3)
        #expect(SMCReadPriority.allCases.filter(Self.isTheLane) == [.thermalCycle])

        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)
        let inFlight = observing { try await scheduler.read(keys: ["H0"], at: .snapshot) }
        await yieldUntil("a turn to hold the connection") { await provider.turns.count == 1 }

        var parked: [ObservableWork<[SensorReadOutcome]>] = []
        for priority in SMCReadPriority.allCases {
            parked.append(
                observing { try await scheduler.read(keys: ["P\(priority)"], at: priority) })
            await yieldUntil("a request at \(priority) to park") {
                await scheduler.queuedTurns(at: priority) == 1
            }
        }
        for priority in SMCReadPriority.allCases {
            #expect(await scheduler.queuedTurns(at: priority) == 1, "\(priority)'s queue")
        }

        await provider.releaseEveryTurn()
        _ = try await finished("the turn in flight", inFlight)
        for (index, read) in parked.enumerated() {
            _ = try await finished("parked request \(index)", read)
        }
    }
}
