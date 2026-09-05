import AeolusXPC
import FanKit
import SMCCore
import Testing

@testable import AeolusHelper

/// § 3 across a suspension point: what happens when the episode changes while a cycle is
/// looking, and what a cycle that could not look at all still owes the leases.
///
/// `ThermalEmergency` is a reentrant actor, the latch lives in a *different* actor, and every
/// `await` between reading a fact and acting on it is a point at which that fact can stop
/// being true. Two defects of exactly that shape shipped in 3caac9d and are what this suite
/// exists to keep found — [#150](https://github.com/blamechris/Aeolus/issues/150) and
/// [#152](https://github.com/blamechris/Aeolus/issues/152).
///
/// ## Scripted, not raced
///
/// `InterferingCriticalTemperatures` runs a side effect inside a chosen read, so the arrival
/// of the interfering work is scriptable rather than hoped for. A repeat-until-it-races loop
/// would be the flakiness [#109](https://github.com/blamechris/Aeolus/issues/109) is open
/// about, and `ThermalEmergency.fire(_:from:)` already records a concurrency test that was
/// written, passed against the very code it condemned, and was deleted for it.
///
/// Each test asserts `didFire`, so a scenario that silently failed to arrange its own
/// interleaving is a failure rather than a pass.
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

    /// **A cycle that cannot see still owes the leases whatever it can take back.**
    ///
    /// `LeaseAuthority.revokeEveryLease(because:)` names a grant-time window it cannot close
    /// from its own side — the latch is read, a real 34-key read is awaited, and § 3 can
    /// engage across it — and then asserts the mitigation: *"the emergency taking back
    /// whatever it finds, every cycle it holds."* A cycle whose read threw used to return
    /// before ever reaching the revocation, so that sentence was false on exactly the machine
    /// where it matters most.
    ///
    /// The teeth: `renewLease` consults neither the latch nor telemetry, so a holder that
    /// survives one blind cycle renews indefinitely and the TTL never becomes the backstop
    /// the composition assumes — a client holding manual control through an emergency the
    /// mechanism believes it took back, which is `CLAUDE.md` rule 6.
    ///
    /// Both halves of the scenario are scripted rather than argued: the grant really does
    /// complete after the latch engages, because § 3's cycle runs *inside* `refuseIfBlind`'s
    /// telemetry read.
    ///
    /// Mutation-checked: delete the `takeBackAnythingEngagedSinceFiring()` call from
    /// `cycleSawNothing(_:)` and this goes red.
    @Test("A blind cycle still takes back a lease granted in the window § 3 latched across")
    func aBlindCycleWhileLatchedStillRevokes() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(97), .blind()])
        await machine.plane.advance()

        // The window itself. The grant reads the latch clear, parks in the 34-key read, and
        // § 3 fires across it — so `fire(_:from:)`'s own revocation finds an empty table.
        await machine.leaseTelemetry.interfere { [emergency = machine.emergency] in
            await emergency.cycle()
        }
        try await machine.acquireWithoutEngaging(fans: [0])

        #expect(await machine.leaseTelemetry.didFire, "the scenario never arranged the window")
        #expect(await machine.latch.isActive, "§ 3 did not engage across the grant")
        #expect(
            await machine.leases.leaseCount == 1,
            "the grant did not complete after the latch engaged")

        // The SMC stops answering. This is the cycle that used to return early.
        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(
            await machine.leases.leaseCount == 0,
            "a cycle that could not see left a lease alive through the emergency")
        #expect(await machine.latch.isActive, "a cycle that could not read never releases")
        #expect(await machine.restorer.causes == [.thermalEmergency])
    }

    /// The control that keeps the branch above from becoming "a blind cycle revokes".
    ///
    /// With the latch clear, an unreadable cycle changes nothing — firing or revoking on one
    /// missed read would take the fans from a client on a transient, and persistent read
    /// failure is [#126](https://github.com/blamechris/Aeolus/issues/126)'s to escalate. The
    /// latch is what separates the two, so both sides of it are asserted.
    @Test("A blind cycle with the latch clear revokes nothing")
    func aBlindCycleWithNoEmergencyRevokesNothing() async throws {
        let machine = ThermalMachine(stages: [.at(44), .blind()])
        try await machine.lease(fans: [0])
        await machine.plane.advance()

        await machine.emergency.cycle()
        await machine.emergency.cycle()

        #expect(await machine.latch.isActive == false)
        #expect(await machine.leases.leaseCount == 1)
        #expect(await machine.restorer.restores.isEmpty)
    }
}
