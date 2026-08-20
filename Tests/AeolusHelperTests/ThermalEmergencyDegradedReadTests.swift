import AeolusXPC
import FanKit
import Testing

@testable import AeolusHelper

/// What § 3 does when it can see **less** than it could, which is different from seeing
/// nothing.
///
/// The release path had no test for this state, and it is the one where a shrinking view of
/// the machine is indistinguishable from a machine that cooled down. Split from
/// `ThermalEmergencyTests` when that suite crossed SwiftLint's limits.
@Suite("The thermal emergency on a degraded read")
struct ThermalEmergencyDegradedReadTests {

    /// **A cooling machine and a machine that lost its hot sensors look identical to
    /// `max()`.** Only one of them is safe to act on.
    ///
    /// `cycle()` released on the maximum of whatever answered and asked nothing about what
    /// did not. `CriticalSensorSet` records this cluster spanning 55.85–62.40 °C at peak — a
    /// ~6.5 °C spread — against a 5 °C `releaseHysteresisCelsius`, so a spread wider than
    /// the margin is the **measured** case: hottest die key over the ceiling, coolest at or
    /// below the release threshold. Lose the hot half to SMC contention (#127, on the single
    /// connection ADR 0006 mandates) and the latch would let go while the machine was still
    /// over its ceiling, `acquireLease` would stop refusing, and the revoked client's retry
    /// would succeed — the exact loop the refusal exists to prevent.
    ///
    /// Delete the `keysAnsweringAtEngage.isSubset(of:)` guard and this goes red.
    @Test("A degraded cycle never releases the latch, however cool the survivors read")
    func aDegradedCycleDoesNotRelease() async throws {
        let machine = ThermalMachine(
            stages: [.at(44), .at(97), .partial(answering: 4, at: 60)])
        try await machine.lease(fans: [0])
        await machine.plane.advance()
        await machine.emergency.cycle()
        #expect(await machine.latch.isActive)

        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(
            await machine.latch.isActive,
            "30 of the 34 keys that were answering when it fired have gone silent")
        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            _ = try await machine.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    /// The control that keeps the guard from being "never release". A **complete** cool
    /// cycle still lets go — otherwise the fix would strand every latch forever, which is
    /// `CLAUDE.md` rule 6 reached from the safe-looking direction.
    @Test("A complete cool cycle still releases")
    func aCompleteCoolCycleStillReleases() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(97), .at(60)])
        try await machine.lease(fans: [0])
        await machine.plane.advance()
        await machine.emergency.cycle()
        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(await machine.latch.isActive == false)
    }

    /// Keys that were **already** silent when the latch engaged must not block the release.
    ///
    /// `CriticalSensorSet`'s whole justification for a compiled-in key list is that a key
    /// this firmware never exposes is not a failure. Requiring `unreadableKeys.isEmpty`
    /// would therefore strand the latch on any machine permanently missing one of the 34 —
    /// which is why the guard compares against the engaging cycle's key set instead.
    @Test("Keys already silent at engage time do not block a later release")
    func permanentlyMissingKeysDoNotStrandTheLatch() async throws {
        let machine = ThermalMachine(
            stages: [
                .partial(answering: 4, at: 44),
                .partial(answering: 4, at: 97),
                .partial(answering: 4, at: 60),
            ])
        try await machine.lease(fans: [0])
        await machine.plane.advance()
        await machine.emergency.cycle()
        #expect(await machine.latch.isActive)

        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(
            await machine.latch.isActive == false,
            "the same four keys answered throughout, and they are cool")
    }
}
