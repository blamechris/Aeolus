import Foundation
import Testing

@testable import AeolusHelper

/// `EngagementDriver` over `ScriptedControlPlane`'s unlock model
/// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D2 to D4, D7).
///
/// Every scenario here is a hypothesis the hardware runs have not tested: the sequence is D3's,
/// scripted, so these pin what the driver does with each answer, not what the firmware gives.
@Suite("The engagement driver", .timeLimit(.minutes(1)))
struct EngagementDriverTests {

    // MARK: - Engaging

    /// The report's first step, when the system is not asserting control: one accepted mode
    /// write that reads back `1`, no force key, and the fan registered with § 3.
    @Test("A naive write that reads back engaged is one step, with no force key")
    func aNaiveWriteEngagesInOneStep() async throws {
        let rig = try await EngagementRig(unlock: .naive)

        try await rig.driver.engageManualControl(of: rig.fan(0))

        #expect(await rig.plane.keyWrites == [.mode(fan: 0, value: 1)])
        #expect(await rig.plane.isForceKeySet == false)
        #expect(await rig.registry.engaged == [0])
        #expect(rig.plane.ledger.engagedFans == [0])
        #expect(rig.clock.sleeps.isEmpty)
    }

    /// Refuse-then-yield: `0x82`, the force key, then `UnlockLimits.pollInterval` between
    /// Y-writes until the yield arrives — and no turn held across the sleeps.
    @Test("A held fan is engaged under the force key once the firmware yields")
    func aHeldFanEngagesUnderTheForceKey() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 3))

        try await rig.driver.engageManualControl(of: rig.fan(0))

        #expect(
            await rig.plane.keyWrites
                == [.mode(fan: 0, value: 1), .forceKey(1)]
                + Array(repeating: .mode(fan: 0, value: 1), count: 4))
        #expect(await rig.plane.isForceKeySet)
        #expect(rig.plane.ledger.isForceKeySet)
        #expect(await rig.registry.engaged == [0])
        #expect(
            rig.clock.sleeps == Array(repeating: UnlockLimits.pollInterval, count: 4))
    }

    /// D3 step 3's second branch: a second fan engaging while the first holds the key writes no
    /// key of its own and waits for its own yield.
    ///
    /// **Mutation:** drop `!forceKeySet` from `EngagementRules.afterModeWrite`'s held branch.
    /// Run: red — the second fan sets the key again.
    @Test("A second fan engaging under a key already set writes no key")
    func aSecondFanWritesNoKey() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 1), fans: [0, 1])
        try await rig.driver.engageManualControl(of: rig.fan(0))

        try await rig.driver.engageManualControl(of: rig.fan(1))

        #expect(
            await rig.plane.keyWrites.filter { $0 == .forceKey(1) }.count == 1,
            "the second engagement set the force key again")
        #expect(rig.plane.ledger.engagedFans == [0, 1])
    }

    // MARK: - Refusing, and undoing

    /// The budget: 3.5 s of polling, so at most 35 steps, then the undo — the fan's mode and,
    /// with no engaged fan left, the key this engagement set.
    @Test("A yield that never arrives exhausts the budget and is undone")
    func aYieldThatNeverArrivesIsUndone() async throws {
        let rig = try await EngagementRig(unlock: .neverYields)

        await #expect(throws: EngagementRefusal.yieldDidNotArrive(fan: 0, steps: 35)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.plane.keyWrites.suffix(2) == [.mode(fan: 0, value: 0), .forceKey(0)])
        #expect(await rig.plane.isForceKeySet == false, "the undo left the force key set")
        #expect(await rig.registry.engaged.isEmpty)
        #expect(await rig.registry.accepted == [0])
    }

    /// The answers D3 does not retry: accepted-not-applied (#291), a raw value outside the
    /// hypothesis, and a first result that is neither `0x00` nor `0x82` — which also never
    /// reaches the force key. Each is undone.
    @Test(
        "An answer outside the hypothesis is refused and undone",
        arguments: [
            ScriptedControlPlane.UnlockBehaviour.readsBack(rawMode: 0),
            .readsBack(rawMode: 3),
            .answers(code: 0x89),
        ])
    func anUnexpectedAnswerIsRefusedAndUndone(
        _ unlock: ScriptedControlPlane.UnlockBehaviour
    ) async throws {
        let rig = try await EngagementRig(unlock: unlock)

        await #expect(throws: FanControlPlaneError.self) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        let writes = await rig.plane.keyWrites
        #expect(writes.first == .mode(fan: 0, value: 1))
        #expect(writes.last == .mode(fan: 0, value: 0), "a refused engagement was not undone")
        #expect(writes.contains(.forceKey(1)) == false, "D3 reached the force key")
        #expect(await rig.registry.engaged.isEmpty)
    }

    /// D3 step 1: a fan whose raw mode is not `0` is someone else's. Nothing is written — not
    /// the mode write, and not an undo, which would be ADR 0011's contest.
    ///
    /// **Mutation:** make `EngagementRules.requireAutomatic` accept any raw mode. Run: red on the
    /// refusal. **Mutation:** delete the `.notAutomatic` early exit from the driver's `catch`.
    /// Run: red on the no-restore assertion.
    @Test("A fan already in manual is refused before anything is written, and not undone")
    func aFanNotAutomaticIsRefusedWithNothingWritten() async throws {
        let rig = try await EngagementRig(unlock: .naive)
        await rig.plane.setMode(.manual, ofFan: 0)

        await #expect(throws: FanControlPlaneError.notAutomatic(index: 0, rawMode: 1)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.plane.keyWrites.isEmpty)
        #expect(await rig.plane.attempts.contains(.restoreToAutomatic(.fan(0))) == false)
    }

    /// A firmware with no force key that holds the fan has no route this ADR knows, and the key
    /// is never written — not to set it, and not by the undo.
    @Test("With the force key absent, a held fan is refused and the key never written")
    func anAbsentForceKeyIsNeverWritten() async throws {
        let rig = try await EngagementRig(unlock: .neverYields, forceKey: .absent)

        await #expect(throws: FanControlPlaneError.self) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }
        try await rig.plane.restoreToAutomatic(.everyFan)

        let keyWrites = await rig.plane.keyWrites.filter {
            if case .forceKey = $0 { true } else { false }
        }
        #expect(keyWrites.isEmpty, "a key recorded absent was written")
    }

    // MARK: - The entitlement, before and after every step (D4)

    /// Before the first step: a latched § 3 or a lapsed lease refuses the engagement with no
    /// step issued and nothing to undo.
    ///
    /// **Mutation:** delete the `try await requireEntitlement(for: fan)` that opens
    /// `engageManualControl(of:)`. Run: red on both cases' no-step assertion.
    @Test("No step is issued when the entitlement is refused before the first")
    func theEntitlementIsAskedBeforeTheFirstStep() async throws {
        let latched = try await EngagementRig(unlock: .naive)
        await latched.engageThermalEmergency()
        await #expect(throws: EngagementRefusal.preempted(fan: 0, by: .thermalEmergency)) {
            try await latched.driver.engageManualControl(of: latched.fan(0))
        }
        #expect(await latched.plane.attempts.isEmpty, "a step was issued above the ceiling")

        let unleased = try await EngagementRig(unlock: .naive, leased: false)
        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await unleased.driver.engageManualControl(of: unleased.fan(0))
        }
        #expect(await unleased.plane.attempts.isEmpty, "a step was issued with no lease")
    }

    /// Between steps: § 3 latching while the engagement waits for its yield refuses the next
    /// step, and the undo clears the key the first step set.
    ///
    /// **Mutation:** delete the `try await requireEntitlement(for: fan)` after the sleep. Run:
    /// red — the engagement polls on to the yield and engages above the ceiling.
    @Test("A latch arriving mid-poll refuses the next step and undoes the first")
    func theEntitlementIsAskedBeforeEveryLaterStep() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 2))
        rig.clock.onSleep(1) { await rig.engageThermalEmergency() }

        await #expect(throws: EngagementRefusal.preempted(fan: 0, by: .thermalEmergency)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.plane.keyWrites.suffix(2) == [.mode(fan: 0, value: 0), .forceKey(0)])
        #expect(await rig.plane.isForceKeySet == false)
        #expect(await rig.registry.engaged.isEmpty, "a fan never engaged was registered")
    }

    /// After `.engaged`: the fan is registered with § 3 **before** the after-check, so an undo
    /// the firmware refuses leaves it where § 3's next emergency bridges it (#181).
    ///
    /// **Mutation:** move `await emergency.manualControlEngaged(fan)` below the after-check.
    /// Run: red on the registry assertion. **Mutation:** delete the after-check. Run: red on
    /// the refusal.
    @Test("A latch after the write is caught, and a refused undo leaves the fan registered")
    func theAfterCheckRegistersBeforeItAsks() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [.nominal(), .nominal(writes: .refused(reason: "firmware said no"))])
        let interfering = InterferingFanStateSensing(plane, during: .engageWrite)
        let rig = try await EngagementRig(plane: plane, writes: interfering)
        await interfering.interfere {
            await rig.engageThermalEmergency()
            await plane.advance()
        }

        await #expect(throws: EngagementRefusal.preempted(fan: 0, by: .thermalEmergency)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await interfering.didFire, "the scenario never arranged the interleaving")
        #expect(await rig.registry.engaged == [0], "the fan was not registered with § 3")
        #expect(await rig.registry.accepted.isEmpty, "a refused undo was reported accepted")
        #expect(rig.log.faults.contains { $0.contains("Could not undo the engagement of fan 0") })
    }

    // MARK: - The restore epoch (D4)

    /// A restore requested while the engagement waits supersedes it: the next step writes
    /// nothing, and the engagement is undone. Any restore, of any fan.
    ///
    /// **Mutation:** make `PlaneWriteLedger.admitStep(fanAt:)` return `.continuing` whatever
    /// the epoch. Run: red — the engagement polls on to the yield.
    @Test("A restore requested mid-poll supersedes the engagement")
    func aRestoreSupersedesAnEngagementInProgress() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 2), fans: [0, 1])
        rig.clock.onSleep(1) { try? await rig.plane.restoreToAutomatic(.fan(1)) }

        await #expect(throws: FanControlPlaneError.superseded) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        let writes = await rig.plane.keyWrites
        #expect(
            writes.filter { $0 == .mode(fan: 0, value: 1) }.count == 1,
            "a step wrote after a restore requested before it")
        #expect(writes.last == .mode(fan: 0, value: 0))
        #expect(await rig.registry.engaged.isEmpty)
    }

    // MARK: - No turn held between steps (D7)

    /// § 3 keeps completing cycles while an engagement waits for its yield: the driver holds
    /// nothing across its sleeps, so § 3's reads are admitted between steps.
    @Test("§ 3 completes cycles while an engagement is mid-poll")
    func theEmergencyCyclesWhileAnEngagementPolls() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 3))
        let emergency = rig.thermalEmergency()
        let completed = CompletedCycles()
        for sleep in 1...3 {
            rig.clock.onSleep(sleep) { await completed.record(await emergency.cycle()) }
        }

        try await rig.driver.engageManualControl(of: rig.fan(0))

        #expect(await completed.results == [true, true, true])
        let attempts = await rig.plane.attempts
        let firstStep = try #require(attempts.firstIndex(of: .engageManualControl(fan: 0)))
        let lastStep = try #require(attempts.lastIndex(of: .engageManualControl(fan: 0)))
        let readsBetween = attempts[firstStep...lastStep].filter {
            if case .readCriticalTemperatures = $0 { true } else { false }
        }
        #expect(readsBetween.count == 3, "§ 3 did not read between the engagement's steps")
    }

    // MARK: - § 5 engages only through the driver

    /// The plane's step verb is called from exactly two places in `Sources/`: the writer's
    /// one-step pass-through, and the driver. § 5 engages through the driver, never the writer.
    ///
    /// **Mutation:** in `ReclamationWatchdog.reassert`, call
    /// `writer.engageManualControl(of: permit)` in place of the driver. Run: red.
    @Test("Nothing in the helper engages a fan except through the driver")
    func onlyTheDriverEngages() throws {
        var calls: [String] = []
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            let pattern = try NSRegularExpression(pattern: #"(\w+)\.engageManualControl\(of:"#)
            for match in pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let receiver = Range(match.range(at: 1), in: code) else { continue }
                calls.append("\(file.lastPathComponent): \(code[receiver])")
            }
        }
        #expect(
            calls.sorted() == [
                "EngagementDriver.swift: writer",
                "ReclamationWatchdog.swift: engagement",
                "SafetyWriters.swift: plane",
            ],
            "a fan is engaged around the driver: \(calls.sorted())")
    }
}

// MARK: - The rig

/// One driver over one scripted plane: a lease over its fans, a latch, a recording § 3 role, and
/// a clock whose sleeps can run a scenario's interference.
private struct EngagementRig {

    let plane: ScriptedControlPlane
    let clock = PollingClock()
    let latch = ThermalEmergencyLatch()
    let registry = RecordingEmergencyRegistry()
    let leases: LeaseAuthority
    let log = RecordedLog()
    let driver: EngagementDriver<InterferingFanStateSensing>
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
        self.fans = fans
        leases = LeaseFixture.authority(thermalEmergency: latch, clock: clock.base)
        let recording = log
        driver = EngagementDriver(
            writer: SafetyActorWriter(plane: writes, level: .reclamationWatchdog),
            leases: leases, latch: latch, emergency: registry, clock: clock,
            log: SafetyLog(recording: { recording.append($0, $1) }))
        if leased {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: fans), from: ConnectionID())
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
private final class PollingClock: MonotonicClock, @unchecked Sendable {
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

private actor CompletedCycles {
    private(set) var results: [Bool] = []
    func record(_ completed: Bool) { results.append(completed) }
}
