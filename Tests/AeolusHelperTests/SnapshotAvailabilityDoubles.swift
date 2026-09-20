import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The graphs `SnapshotAvailabilityTests` drives, and the two readers its agreement
/// assertions compare — in a file of its own, for `UnconfirmedHandbackDoubles`' reason: the
/// suite is at SwiftLint's 400-line limit with them in it.
///
/// A namespace rather than an `extension SnapshotAvailabilityTests`, because a `private`
/// member is unreachable from another file and widening the suite's own members to reach
/// them would be the wrong direction. `LeaseFixture` is the same shape.
enum AvailabilityFixture {

    /// What the scripted firmware does to a restore in the abandoned-handback tests: refuses
    /// it, every attempt, so `BoundedFanRestorer` spends its budget and reports the fan.
    static let firmwareRefusesTheModeWrite = ScriptedControlPlane.WriteBehaviour.refused(
        reason: "the firmware refused the mode write")

    static let helperLog = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Availability")
    static let safetyLog = SafetyLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Availability")

    // MARK: - Reading the two sides

    /// The reason the grant path refuses a lease over `fan`, or a failure if it grants one.
    ///
    /// It names no reason, deliberately: the agreement assertions compare it against the
    /// snapshot's, and a helper that returned an expected value here would make them tautologies.
    static func refusalForGrant(
        over fan: Int, from leases: LeaseAuthority
    ) async -> ManualControlAvailability.Reason {
        do {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: [fan]), from: ConnectionID())
            Issue.record("the grant path granted a lease over fan \(fan) rather than refusing")
            return .unknown("granted")
        } catch let fault as AeolusXPCFault {
            guard case .manualControlUnavailable(let reason) = fault else {
                Issue.record("the grant path refused with \(fault), not a manual-control reason")
                return .unknown(String(describing: fault))
            }
            return reason
        } catch {
            Issue.record("the grant path failed with \(error)")
            return .unknown(String(describing: error))
        }
    }

    static func availability(
        ofFanAt index: Int, in snapshot: SystemSnapshot
    ) throws -> ManualControlAvailability {
        try #require(snapshot.fans.first { $0.index == index }).manualControlAvailability
    }

    // MARK: - The graphs

    /// The daemon's own wiring over scripted firmware that can write.
    ///
    /// Composed here rather than borrowed from `HelperRestorerTests.composed` because these
    /// tests need two fans present in the *plane* as well as in the provider:
    /// `StartupReconciliation.refusalForGrant` reads the named fan's control state, and a fan
    /// the scripted firmware has never heard of throws `.fanNotAddressable`, which the grant
    /// gate would have to report as blindness. `LeaseFixture.automaticFans()` records the same
    /// hazard.
    static func composed(
        writes: ScriptedControlPlane.WriteBehaviour = .honoured,
        fanCount: Int = 1,
        extraKeys: [String: Result<SensorReading, SensorReadFailure>] = [:]
    ) -> HelperComposition<ScriptedControlPlane> {
        HelperComposition(
            plane: Self.firmware(fanCount: fanCount, writes: writes),
            snapshotProvider: fanProvider(fanCount: fanCount, extraKeys: extraKeys),
            criticalSensors: .mac16x5,
            log: Self.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    /// The same wiring over firmware whose restore can be parked on demand.
    static func wedging() -> HelperComposition<CycleWedgingRestorePlane> {
        HelperComposition(
            plane: CycleWedgingRestorePlane(Self.firmware(fanCount: 1, writes: .honoured)),
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            log: Self.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    static func firmware(
        fanCount: Int, writes: ScriptedControlPlane.WriteBehaviour
    ) -> ScriptedControlPlane {
        ScriptedControlPlane(
            fans: Dictionary(
                uniqueKeysWithValues: (0..<fanCount).map { ($0, .automatic(at: 2_400)) }),
            stages: [
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures, writes: writes)
            ])
    }

    /// Takes a lease over `fan` and releases it, which is the ordinary teardown path.
    static func acquireAndRelease<Plane: FanControlPlane>(
        fanAt fan: Int, in helper: HelperComposition<Plane>
    ) async throws {
        await helper.bindSafetyRegistries()
        let connection = ConnectionID()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [fan]), from: connection)
        try await helper.leases.releaseLease(id: lease.id, from: connection)
    }

    /// Leaves `fan`'s restore-to-automatic parked inside the firmware, and hands back the task
    /// holding it there so the caller can let it finish.
    ///
    /// The release must be awaited rather than abandoned: a task still inside
    /// `LeaseAuthority.restore(_:because:)` when the test ends keeps the actor's `defer`
    /// unrun, and a suite that leaves one behind reports a passing test while a fan stays in
    /// the register for whatever runs next.
    static func parkedHandback(
        ofFanAt fan: Int, in helper: HelperComposition<CycleWedgingRestorePlane>
    ) async throws -> Task<Void, Never> {
        await helper.bindSafetyRegistries()
        let connection = ConnectionID()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [fan]), from: connection)
        await helper.plane.wedgeTheNextRestore()

        let leases = helper.leases
        let parked = Task { try? await leases.releaseLease(id: lease.id, from: connection) }
        while await !helper.leases.fansMidHandback.contains(fan) { await Task.yield() }
        return Task { _ = await parked.result }
    }
}
