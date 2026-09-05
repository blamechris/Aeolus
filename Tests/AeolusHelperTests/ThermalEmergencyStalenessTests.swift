import AeolusXPC
import FanKit
import SMCCore
import Testing

@testable import AeolusHelper

/// § 3 across a suspension point: what happens when the episode changes while a cycle is
/// looking.
///
/// `ThermalEmergency` is a reentrant actor, the latch lives in a *different* actor, and every
/// `await` between reading a fact and acting on it is a point at which that fact can stop
/// being true. A defect of exactly that shape shipped in 3caac9d and is what this suite
/// exists to keep found — [#150](https://github.com/blamechris/Aeolus/issues/150).
///
/// ## Scripted, not raced
///
/// `InterferingCriticalTemperatures` runs a side effect inside a chosen read, so the arrival
/// of the interfering work is scriptable rather than hoped for. A repeat-until-it-races loop
/// would be the flakiness [#109](https://github.com/blamechris/Aeolus/issues/109) is open
/// about, and `ThermalEmergency.fire(_:from:)` already records a concurrency test that was
/// written, passed against the very code it condemned, and was deleted for it.
///
/// A scenario that uses the seam asserts `didFire`, so one that silently failed to arrange
/// its own interleaving is a failure rather than a pass.
@Suite("The thermal emergency, across a suspension point")
struct ThermalEmergencyStalenessTests {

    /// **The degraded-view guard must be armed by the episode that is holding**, not by one
    /// that has already ended.
    ///
    /// The qualifying key set used to live on `ThermalEmergency` while the bit it qualifies
    /// lived on `ThermalEmergencyLatch`, and two facts in two actors can disagree. This
    /// scenario makes them disagree deterministically: the latch changes episode across the
    /// read, from one that could see four keys to one that could see all thirty-four, while
    /// anything cached on the emergency still describes the episode that ended.
    ///
    /// Eight keys then answer, cool. Against the dead episode's four that is a complete view
    /// of a machine that cooled down, and the latch lets go with the live episode's thirty
    /// missing keys never asked about — `acquireLease` stops refusing, and the client that
    /// was revoked retries into the same overheating workload. Against the *holding*
    /// episode's thirty-four it is a machine that has lost most of its sensors, which is not
    /// evidence of anything.
    ///
    /// Mutation-checked: give `ThermalEmergency` back a `keysAnsweringAtEngage` field
    /// assigned in `fire(_:from:)` and read by the subset guard — the pre-fix design — and
    /// this goes red on the latch assertion.
    @Test("The guard follows the episode that is holding, not the one that ended")
    func theGuardFollowsTheHoldingEpisodeAcrossTheRead() async throws {
        let machine = ThermalMachine(
            stages: [
                .at(44),
                // Engages on a narrow view: four keys, well above the ceiling.
                .partial(answering: 4, at: 97),
                // Cool, and *wider* than that view — which is what makes the stale set
                // vacuous rather than merely wrong.
                .partial(answering: 8, at: 60),
            ])
        await machine.plane.advance()
        await machine.emergency.cycle()
        #expect(await machine.latch.isActive)

        // A cooler concurrent cycle let go, and a hotter one engaged a fresh episode that
        // could see the whole curated set — all of it inside this cycle's read.
        let everyCuratedKey = Set(CriticalSensorSet.mac16x5.keys)
        await machine.emergencyTelemetry.interfere { [latch = machine.latch] in
            #expect(await latch.release())
            #expect(
                await latch.engage(
                    by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99),
                    answering: everyCuratedKey))
        }

        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(
            await machine.emergencyTelemetry.didFire,
            "the scenario never arranged the episode boundary")
        #expect(
            await machine.latch.isActive,
            "the holding episode qualified on 34 keys and 8 answered: not a machine that cooled")
        // What makes this discriminate rather than merely agree: the latch could also still
        // be active because the release comparison failed, and it did not — 60 °C is below
        // the release threshold. The hold has to be the degraded-view guard's doing.
        #expect(machine.safetyLog.lines(containing: "have gone silent").count == 1)
        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            _ = try await machine.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    /// The latch's half of the same contract: the qualifying set is the episode's, and it
    /// goes when the episode does.
    ///
    /// Holding the set beside `engagedBy` inside one optional is what makes "engaged with no
    /// qualifying keys" unrepresentable rather than merely avoided — `Set().isSubset(of:)` is
    /// vacuously `true`, so an empty set on a holding latch is the degraded-view guard
    /// switched off.
    ///
    /// A *repeat* engage deliberately does not replace the set. `engage(by:answering:)` is
    /// reached on every cycle above the ceiling, and a redundant one arriving from a degraded
    /// cycle would narrow the set the episode is qualified by — weakening the guard from the
    /// direction that looks harmless.
    @Test("The qualifying key set belongs to the episode and goes when it does")
    func theQualifyingSetBelongsToTheEpisode() async {
        let latch = ThermalEmergencyLatch()
        let hot = CriticalTemperature(key: smcKey("Tp01"), celsius: 99)
        let hotter = CriticalTemperature(key: smcKey("Tp01"), celsius: 101)
        let wide: Set<SMCKey> = [smcKey("Tp01"), smcKey("Tp09")]

        #expect(await latch.engage(by: hot, answering: wide))
        #expect(await latch.holding?.keysAnsweringAtEngage == wide)

        #expect(await latch.engage(by: hotter, answering: [smcKey("Tp01")]) == false)
        #expect(
            await latch.holding?.keysAnsweringAtEngage == wide,
            "a redundant engage from a narrower cycle narrowed the guard")
        #expect(await latch.engagedBy == hotter, "the most recent reading is the useful one")

        #expect(await latch.release())
        #expect(await latch.holding == nil)
        #expect(await latch.keysAnsweringAtEngage.isEmpty)
    }
}
