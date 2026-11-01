import FanKit
import Foundation
import Testing

@testable import AeolusHelper

// The engagement driver's fixtures, shared by `EngagementDriverTests` and
// `EngagementEpochTests`.

// MARK: - The rig

/// One driver over one scripted plane: a lease over its fans, a latch, a recording § 3 role, and
/// a clock whose sleeps can run a scenario's interference.
///
/// `driver` is bound to the rig's lease with `under(lease:)`, as § 5 and level 6 bind theirs
/// (#357); with no lease it is the composed driver, bound to none. `unbound` is always that.
struct EngagementRig {

    let plane: ScriptedControlPlane
    let clock = PollingClock()
    let latch = ThermalEmergencyLatch()
    let registry = RecordingEmergencyRegistry()
    let leases: LeaseAuthority
    let log = RecordedLog()
    /// The plane the driver writes through, which can act inside its steps.
    let writes: InterferingFanStateSensing
    /// The driver every scenario engages through: bound to `lease` when there is one.
    let driver: EngagementDriver<InterferingFanStateSensing>
    /// The driver as composed, bound to no lease, which refuses every step.
    let unbound: EngagementDriver<InterferingFanStateSensing>
    /// The lease `driver` is bound to, or `nil` for an unleased rig.
    let lease: Lease?
    /// The connection the rig's lease is bound to, so a scenario can end it.
    let holder = ConnectionID()
    private let fans: [Int]

    init(
        unlock: ScriptedControlPlane.UnlockBehaviour, fans: [Int] = [0],
        forceKey: ForceKeyPresence = .present, leased: Bool = true
    ) async throws {
        let plane = ScriptedControlPlane(
            fans: Dictionary(uniqueKeysWithValues: fans.map { ($0, .nominal) }),
            forceKey: forceKey, unlock: unlock)
        try await self.init(
            plane: plane, writes: InterferingFanStateSensing(plane, during: .restoreWrite),
            fans: fans, leased: leased)
    }

    init(
        plane: ScriptedControlPlane, writes: InterferingFanStateSensing, fans: [Int] = [0],
        leased: Bool = true
    ) async throws {
        self.plane = plane
        self.writes = writes
        self.fans = fans
        leases = LeaseFixture.authority(
            enumeration: ScriptedFanEnumeration(indices: Set(fans)), thermalEmergency: latch,
            clock: clock.base)
        let recording = log
        let composed = EngagementDriver(
            writer: SafetyActorWriter(plane: writes, level: .reclamationWatchdog),
            leases: leases, latch: latch, emergency: registry, clock: clock,
            level: .reclamationWatchdog, log: SafetyLog(recording: { recording.append($0, $1) }))
        unbound = composed
        if leased {
            let granted = try await leases.acquireLease(
                LeaseFixture.request(fans: fans), from: holder)
            lease = granted
            driver = composed.under(lease: granted.id)
        } else {
            lease = nil
            driver = composed
        }
    }

    func fan(_ index: Int) throws -> CommandableFan {
        try commandableFan(index, declaring: .nominal)
    }

    func engageThermalEmergency() async {
        await latch.engage(
            by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99), answering: [smcKey("Tp01")])
    }

    /// A real § 3 on this rig's plane and latch, for the scenario that cycles it.
    func thermalEmergency() -> ThermalEmergency<ScriptedControlPlane> {
        let telemetry = CuratedCriticalTemperatures(plane: plane, set: .mac16x5)
        return ThermalEmergency(
            telemetry: telemetry,
            sightings: CriticalTemperatureCache(source: telemetry, clock: clock.base),
            writer: SafetyActorWriter(plane: plane, level: .thermalEmergency),
            handback: LeaseFixture.handback(over: plane),
            leases: leases, latch: latch,
            handbackReadBack: LeaseFixture.reconciliation(over: plane))
    }
}

/// § 3's registration role, recorded.
actor RecordingEmergencyRegistry: ThermalEmergencyRegistering {
    private(set) var engaged: [Int] = []
    private(set) var accepted: [Int] = []

    func manualControlEngaged(_ fan: CommandableFan) { engaged.append(fan.index) }
    func handbackAccepted(fanAt index: Int) { accepted.append(index) }
}

/// `TestClock`'s virtual time, plus a hook per sleep so a scenario can act while the driver waits
/// between steps — the only moment it holds nothing.
final class PollingClock: MonotonicClock, @unchecked Sendable {
    let base = TestClock()
    private let lock = NSLock()
    private var hooks: [Int: @Sendable () async -> Void] = [:]
    private var intervals: [Duration] = []

    var now: ContinuousClock.Instant { base.now }
    var sleeps: [Duration] { lock.withLock { intervals } }

    /// Runs `hook` after the `ordinal`th sleep, counting from one.
    func onSleep(_ ordinal: Int, _ hook: @escaping @Sendable () async -> Void) {
        lock.withLock { hooks[ordinal] = hook }
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let hook: (@Sendable () async -> Void)? = lock.withLock {
            intervals.append(base.now.duration(to: deadline))
            return hooks.removeValue(forKey: intervals.count)
        }
        try await base.sleep(until: deadline)
        await hook?()
    }
}

actor CompletedCycles {
    private(set) var results: [Bool] = []
    func record(_ completed: Bool) { results.append(completed) }
}
