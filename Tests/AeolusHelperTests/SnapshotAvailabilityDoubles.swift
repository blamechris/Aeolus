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

    /// The shape of a byte-swapped `flt`. A test that stages it asserts the firmware reads it back,
    /// so the scenario cannot pass vacuously over plausible bounds.
    static let byteSwappedBound = 1e14

    /// `F0Mx`'s value in the bounds scenarios, which § 2's gate refuses as `.maximumAboveCeiling`.
    static let byteSwappedMaximum = ScriptedControlPlane.BoundRead.reads(byteSwappedBound)

    /// A stage like `fanZeroMaximum(_:)`'s, with `F0Mn` reading `minimum` and `F0Mx` the declared
    /// maximum. A byte-swapped `F0Mn` sits above `F0Mx`: § 2's gate refuses it as `.notAscending`.
    static func fanZeroMinimum(
        _ minimum: ScriptedControlPlane.BoundRead
    ) -> ScriptedControlPlane.Stage {
        var stage = ScriptedControlPlane.Stage(temperatures: LeaseFixture.nominalDieTemperatures)
        stage.minimumReads = [0: minimum]
        return stage
    }

    /// A stage on which the SMC answers, the temperatures are nominal, and fan 0's `F0Mx` reads
    /// `maximum` — to the snapshot's provider and to the grant's `readEnvelope(ofFan:)` alike
    /// (#270). `unreadableModes` and `writes` are the stage's own, for a scenario that needs a
    /// mode that does not read or a write the firmware refuses beside the bounds.
    static func fanZeroMaximum(
        _ maximum: ScriptedControlPlane.BoundRead,
        writes: ScriptedControlPlane.WriteBehaviour = .honoured,
        unreadableModes: Set<Int> = []
    ) -> ScriptedControlPlane.Stage {
        ScriptedControlPlane.Stage(
            temperatures: LeaseFixture.nominalDieTemperatures, writes: writes,
            unreadableModes: unreadableModes, maximumReads: [0: maximum])
    }

    /// A stage on which the SMC answers every fan read and **no critical temperature**, so § 3 is
    /// blind — the curated read throws `.criticalTelemetryUnavailable` — while the snapshot still
    /// reads every fan (#269). `ScriptedControlPlane.Stage.blind` fails every read, the fans' too.
    static func sightless(
        writes: ScriptedControlPlane.WriteBehaviour = .honoured,
        unreadableModes: Set<Int> = [],
        maximumReads: [Int: ScriptedControlPlane.BoundRead] = [:]
    ) -> ScriptedControlPlane.Stage {
        ScriptedControlPlane.Stage(
            writes: writes, unreadableModes: unreadableModes, maximumReads: maximumReads)
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
    ///
    /// The snapshot reads each fan's `F<n>Md`, `F<n>Mn` and `F<n>Mx` from that same firmware,
    /// through `PlaneBackedProvider` (#360, #270), so the two sides judge one machine.
    /// `afterwards` follows the nominal stage, for a scenario whose fan stops answering, or
    /// starts reading implausible bounds, once something is set up.
    ///
    /// `clock` is the lease core's and the sightings cache's, for a scenario that has to age a
    /// sighting out — a lease taken while § 3 could see, on a machine that then goes blind.
    ///
    /// **Every graph here defaults to a frozen `TestClock()`**
    /// ([#411](https://github.com/blamechris/Aeolus/issues/411)). The composition hands its
    /// clock to reconciliation's 5 s budget, the lease TTL and the sightings cache's age bound,
    /// so on the system clock a runner stall longer than one of them changes what a test sees:
    /// `UnreadModeAvailabilityTests`' reconciliation cases lose their refused handback when the
    /// pass runs out before it reads fan 0. No caller drives a wait the composition bounds by
    /// sleeping on that clock (a contended examination gate, an unlock that polls, § 4's
    /// acknowledgement), and `TestClock`'s sleep jumps to its deadline, so a caller that starts
    /// to do so wants a `ManualClock`. A scenario about time passes its own clock and moves it.
    static func composed(
        writes: ScriptedControlPlane.WriteBehaviour = .honoured,
        fanCount: Int = 1,
        clock: some MonotonicClock = TestClock(),
        afterwards: [ScriptedControlPlane.Stage] = []
    ) -> HelperComposition<ScriptedControlPlane> {
        let firmware = Self.firmware(fanCount: fanCount, writes: writes, afterwards: afterwards)
        return composed(
            plane: firmware, provider: PlaneBackedProvider(over: firmware, fanCount: fanCount),
            clock: clock)
    }

    /// The same wiring over a plane and a provider the test chooses: a plane answering
    /// `.notBuilt` over scripted firmware, or a provider of the test's own.
    static func composed<Plane: FanControlPlane>(
        plane: Plane, provider: some SensorProvider,
        clock: some MonotonicClock = TestClock()
    ) -> HelperComposition<Plane> {
        HelperComposition(
            plane: plane,
            snapshotProvider: provider,
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: clock,
            log: Self.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    /// The same wiring over firmware whose restore can be parked on demand. `firmware` is a
    /// parameter so a scenario can keep it and advance its stages beneath the parking plane, and
    /// `clock` so it can age a sighting out under a parked handback.
    static func wedging(
        firmware: ScriptedControlPlane = AvailabilityFixture.firmware(
            fanCount: 1, writes: .honoured),
        clock: some MonotonicClock = TestClock()
    ) -> HelperComposition<CycleWedgingRestorePlane> {
        HelperComposition(
            plane: CycleWedgingRestorePlane(firmware),
            snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: clock,
            log: Self.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    static func firmware(
        fanCount: Int, writes: ScriptedControlPlane.WriteBehaviour,
        afterwards: [ScriptedControlPlane.Stage] = []
    ) -> ScriptedControlPlane {
        ScriptedControlPlane(
            fans: Dictionary(
                uniqueKeysWithValues: (0..<fanCount).map { ($0, .automatic(at: 2_400)) }),
            stages: [
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures, writes: writes)
            ] + afterwards)
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
        // Bounded and cancellable: a registration that never comes is a named red, not a spin
        // past `.timeLimit`. The `Task.yield()` loop this replaced never ended under a mutation
        // that registered the fan only after its restore returned (#516's review).
        try await waitUntil("fan \(fan)'s handback is registered as in flight") {
            await helper.leases.fansMidHandback.contains(fan)
        }
        return Task { _ = await parked.result }
    }
}
