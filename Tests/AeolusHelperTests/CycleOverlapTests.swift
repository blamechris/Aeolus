import Testing

@testable import AeolusHelper

/// One cycle at a time, per mechanism.
///
/// Both safety cycles are documented as sequential, and both were sequential only *within*
/// one invocation ([#144](https://github.com/blamechris/Aeolus/issues/144)). Nothing stopped
/// a second `cycle()` from entering while the first was suspended inside a read, and
/// `stop()` — which cancels without awaiting — followed by `start()` reaches exactly that:
/// the outgoing loop's cycle is still in flight when the incoming loop calls its first.
///
/// The consequence is not merely a duplicated read. § 5 keeps per-fan mutable state across
/// its awaits — a re-assert budget and a dwell counter — so two overlapping sweeps of the
/// same fan spend one budget twice and count one dwell twice, and a dwell that elapses in
/// half the cycles is how the secondary signal starts reading a ramp as a reclamation.
///
/// ## The gate is the whole test
///
/// `ScriptedControlPlane` has no suspension point inside its methods, so two concurrent
/// callers could never be *seen* to overlap there — a test built on the mock alone passes
/// against an unguarded `cycle()` and proves nothing. Both scenarios below hold the first
/// cycle's read open, which is what makes "the second one did not act" observable.
///
/// Neither waits on the second task before asserting. Awaiting a `cycle()` that is not
/// guarded would park on the gate and the regression would arrive as a CI timeout with no
/// line number, which is the shape [#109](https://github.com/blamechris/Aeolus/issues/109)
/// is open about.
@Suite("A safety cycle never overlaps itself")
struct CycleOverlapTests {

    /// **Kills:** deleting the in-flight guard from `ReclamationWatchdog.cycle()`. The second
    /// sweep then issues its own control-state read for fan 0 while the first is still
    /// waiting on one, and `controlStateRequests` becomes `[0, 0]`.
    @Test("A second reclamation cycle does not act while one is in flight")
    func aSecondReclamationCycleDoesNotAct() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 2_400)])
        let sensing = GatedFanStateSensing(plane)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 2_400)], sensing: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)

        let first = Task { await machine.watchdog.cycle() }
        #expect(
            await yieldUntil("the first sweep's control-state read") {
                await sensing.controlStateRequests.isEmpty == false
            })

        let second = Task { await machine.watchdog.cycle() }
        // Every opportunity to reach the read the guard is supposed to have prevented.
        for _ in 0..<200 { await Task.yield() }

        #expect(
            await sensing.controlStateRequests == [0],
            "a second cycle() examined a fan while a sweep was already in flight")
        #expect(await sensing.peakOutstanding == 1)

        await sensing.open()
        await first.value
        await second.value

        // The guard is a guard, not a latch: once the sweep is over the next one runs.
        await machine.watchdog.cycle()
        #expect(
            await sensing.controlStateRequests == [0, 0],
            "the in-flight guard was never cleared, so § 5 stopped watching")
    }

    /// **Kills:** deleting the in-flight guard from `ThermalEmergency.cycle()`. The second
    /// cycle then takes its own sample of the curated critical set while the first is still
    /// waiting on one, and `reads` becomes 2.
    ///
    /// § 3 carries state across its awaits too — `lastCycleWasUnreadable` and
    /// `keysAnsweringAtEngage` — and it is the mechanism whose decisions are least
    /// tolerable to duplicate: two cycles that both find the machine cool enough would each
    /// ask the latch to release.
    @Test("A second thermal cycle does not act while one is in flight")
    func aSecondThermalCycleDoesNotAct() async {
        let plane = ScriptedControlPlane(fans: [0: .nominal], stages: [.at(44)])
        let telemetry = GatedCriticalTemperatures(
            CuratedCriticalTemperatures(plane: plane, set: .mac16x5))
        let latch = ThermalEmergencyLatch()
        let emergency = ThermalEmergency(
            telemetry: telemetry,
            writer: SafetyActorWriter(plane: plane, level: .thermalEmergency),
            leases: LeaseFixture.authority(thermalEmergency: latch),
            latch: latch)

        let first = Task { await emergency.cycle() }
        #expect(await yieldUntil("the first cycle's sample") { await telemetry.reads == 1 })

        let second = Task { await emergency.cycle() }
        for _ in 0..<200 { await Task.yield() }

        #expect(
            await telemetry.reads == 1,
            "a second cycle() sampled while a cycle was already in flight")
        #expect(await telemetry.peakOutstanding == 1)

        await telemetry.open()
        await first.value
        await second.value

        // The guard is a guard, not a latch: once the cycle is over the next one runs.
        await emergency.cycle()
        #expect(
            await telemetry.reads == 2,
            "the in-flight guard was never cleared, so § 3 stopped sampling")
    }
}

/// Holds every critical-temperature sample open until the test lets it go, and records how
/// many were in flight at once.
///
/// `GatedFanStateSensing`'s counterpart for § 3, and it exists for that type's reason: the
/// production conformer reaches `ScriptedControlPlane`, whose methods have no suspension
/// point, so overlapping samples could never be observed through the mock alone.
///
/// It wraps the **real** `CuratedCriticalTemperatures` rather than answering for itself, so
/// the curated key list and the plausibility gate stay on the path under test.
actor GatedCriticalTemperatures: CriticalTemperatureSensing {

    private let inner: any CriticalTemperatureSensing
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    /// How many samples have been asked for.
    private(set) var reads = 0
    private var outstanding = 0
    /// The most samples in flight simultaneously. **The assertion this type exists for.**
    private(set) var peakOutstanding = 0

    init(_ inner: any CriticalTemperatureSensing) {
        self.inner = inner
    }

    /// Lets every waiting sample through, and stops gating the ones that follow.
    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    func readCriticalTemperatures() async throws -> CriticalTemperatureReport {
        reads += 1
        outstanding += 1
        peakOutstanding = max(peakOutstanding, outstanding)
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        outstanding -= 1
        return try await inner.readCriticalTemperatures()
    }
}
