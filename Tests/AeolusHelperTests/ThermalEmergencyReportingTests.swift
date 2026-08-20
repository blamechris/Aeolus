import AeolusXPC
import FanKit
import Testing

@testable import AeolusHelper

/// § 3's *configuration* and its *reporting*, split out of `ThermalEmergencyTests` when that
/// suite crossed SwiftLint's file and type-body limits.
///
/// Different questions from the mechanism's own: not "does the override fire correctly" but
/// "can a configuration weaken it" and "is the user told, and how loudly".
@Suite("The thermal emergency's ceiling and reporting")
struct ThermalEmergencyReportingTests {

    @Test("A configuration cannot raise the ceiling, and a non-temperature falls back")
    func theCeilingIsTunableDownwardOnly() {
        let raised = ThermalMachine(stages: [.at(44)], requestedCeilingCelsius: 120)
        #expect(raised.emergency.ceilingCelsius == ThermalCeiling.cpuCelsius)

        let notATemperature = ThermalMachine(stages: [.at(44)], requestedCeilingCelsius: .nan)
        #expect(notATemperature.emergency.ceilingCelsius == ThermalCeiling.cpuCelsius)

        let tightened = ThermalMachine(stages: [.at(44)], requestedCeilingCelsius: 80)
        #expect(tightened.emergency.ceilingCelsius == 80)
        #expect(tightened.emergency.releaseThresholdCelsius == 75)
    }

    /// A tightened ceiling really governs the comparison — otherwise the assertion above
    /// would only prove a stored property.
    @Test("A tightened ceiling fires earlier")
    func aTightenedCeilingFiresEarlier() async throws {
        let machine = ThermalMachine(
            stages: [.at(44), .at(85)], requestedCeilingCelsius: 80)
        try await machine.lease(fans: [0])
        await machine.plane.advance()

        await machine.emergency.cycle()

        #expect(await machine.latch.isActive)
        let writes: [ScriptedControlPlane.Attempt] = await machine.writes
        #expect(writes.contains(.commandTarget(fan: 0, rpm: 5_777)))
    }

    /// The latch's own contract, which is where the atomicity that guard relies on lives.
    ///
    /// `engage` reports whether it engaged a latch that was **clear** — the transition — and
    /// the decision happens inside the actor, so exactly one of any number of concurrent
    /// callers can be told `true`. Make it return `true` unconditionally and this goes red,
    /// which is the closest a test gets to the interleaving above.
    @Test("The latch reports a transition once, and reports repeats as repeats")
    func theLatchReportsTransitionsNotState() async {
        let latch = ThermalEmergencyLatch()
        let hot = CriticalTemperature(key: smcKey("Tp01"), celsius: 99)
        let hotter = CriticalTemperature(key: smcKey("Tp01"), celsius: 101)

        #expect(await latch.engage(by: hot))
        #expect(await latch.engage(by: hotter) == false)
        // The most recent reading wins: a reader watching a machine that is still climbing
        // wants the latest number, not the one that happened to cross first.
        #expect(await latch.engagedBy == hotter)

        #expect(await latch.release())
        #expect(await latch.release() == false)
        #expect(await latch.engagedBy == nil)
    }

    // MARK: - What the log says, and how loudly

    /// § 3 engaging is the one line in this subsystem that must not be missable.
    ///
    /// `SafetyLog`'s level was untestable until now — the recording initialiser discarded
    /// it, so every `.fault` here could have been demoted to `.notice` with the suite green.
    /// That is the shape the type's own header warns about: a load-bearing claim needs a
    /// test that fails when it stops being true.
    ///
    /// Change `.fault` to `.notice` in `thermalEmergencyEngaged` and this goes red.
    @Test("Engaging and releasing the override are logged at fault level")
    func theOverrideLogsAtFaultLevel() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(97), .at(60)])
        try await machine.lease(fans: [0])
        await machine.plane.advance()
        await machine.emergency.cycle()

        let engaged = machine.safetyLog.faults
        #expect(engaged.count == 1)
        #expect(engaged.first?.contains("Thermal emergency engaged") == true)

        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(machine.safetyLog.faults.count == 2)
        #expect(machine.safetyLog.faults.last?.contains("released") == true)
    }

    /// The counterpart: a routine bridge write is **not** a fault. A subsystem that shouts
    /// at every step trains the reader to ignore the level that matters, which is the
    /// argument `SafetyLog.degradedCycle` already makes for itself.
    @Test("A routine bridge write is logged at notice, not fault")
    func aRoutineBridgeWriteIsNotAFault() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(97)])
        try await machine.lease(fans: [0])
        await machine.plane.advance()
        await machine.emergency.cycle()

        let notices = zip(machine.safetyLog.levels, machine.safetyLog.lines)
            .filter { $0.0 == .notice }
            .map(\.1)
        #expect(notices.contains { $0.contains("single write, bypassing the ramp governor") })
    }

    // MARK: - The contract does not move

    /// Every refusal § 3 raises is a fault case E2 already shipped. ADR 0007 promised no
    /// version bump for the whole of E5, and this is the assertion that keeps the promise
    /// checkable in the change that consumes the vocabulary.
    @Test("AeolusXPCVersion is unchanged by the thermal emergency")
    func theProtocolVersionIsUnchanged() {
        #expect(AeolusXPCVersion.current == 1)
    }
}
