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
    /// **The judged cycle is the one after the boundary, deliberately.** The cycle the
    /// boundary lands inside is refused by the episode-boundary guard below — its report
    /// predates the episode entirely, so no comparison it makes means anything — and a
    /// scenario that stopped there would be asserting that guard twice and the degraded-view
    /// guard never. What makes the ownership question real is that the stale fact *outlives*
    /// the boundary: the third cycle takes a fresh report of the same eight cool keys against
    /// an episode that has been holding the whole time, and only the qualifying set decides
    /// it.
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
        // The cycle the boundary lands inside. Its report was taken before the episode it
        // finds, so it declines to judge at all — see the episode-boundary test below.
        await machine.emergency.cycle()
        // The cycle that judges. Its report is taken *after* the episode began, so the only
        // thing standing between eight cool keys and a release is whose key set the guard is
        // armed by.
        await machine.emergency.cycle()

        #expect(
            await machine.emergencyTelemetry.didFire,
            "the scenario never arranged the episode boundary")
        #expect(
            await machine.latch.isActive,
            "the holding episode qualified on 34 keys and 8 answered: not a machine that cooled")
        // What makes this discriminate rather than merely agree: the latch could also still
        // be active because the release comparison failed, and it did not — 60 °C is below
        // the release threshold. And it is not the boundary guard holding either, which fired
        // on the previous cycle and is asserted separately. The hold has to be the
        // degraded-view guard's doing.
        #expect(machine.safetyLog.lines(containing: "have gone silent").count == 1)
        #expect(machine.safetyLog.lines(containing: "across an episode boundary").count == 1)
        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            _ = try await machine.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    /// **A release is never decided on a report older than the episode it would release.**
    ///
    /// The sibling of the scenario above, at the other end of the same window. There the
    /// episode boundary landed inside the read and the *qualifying keys* were the stale fact;
    /// here it lands inside the read and the **temperature** is the stale fact. `cycle()`
    /// gathers its report and only then looks at the latch, so an episode that engaged in
    /// between is younger than the reading in hand — and that reading describes the machine
    /// before it went over its ceiling.
    ///
    /// So: the latch is clear, the machine reads a comfortable 60 °C, and § 3 fires at 99 °C
    /// inside the read. A cycle that judges the new episode against its own report finds
    /// 60 °C ≤ the 90 °C release threshold and lets go — of an emergency one millisecond old,
    /// on a machine at 99 °C. `acquireLease` stops refusing and the client that was just
    /// revoked retries into the workload that fired it.
    ///
    /// The lease is the teeth. It is granted while the latch is clear, which is legal, and
    /// the cycle that declines to judge takes it back as an engagement it cannot account for;
    /// a cycle that releases instead leaves it live over an overheating machine.
    ///
    /// Mutation-checked: delete the `episode.sequence == episodeBeforeRead?.sequence` guard
    /// from `cycle()` — the pre-fix control flow — and this goes red on the latch assertion
    /// and on the lease count.
    @Test("A release is never judged on a report older than the episode holding")
    func aReleaseIsNeverJudgedOnAReportOlderThanTheEpisode() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(60)])
        try await machine.acquireWithoutEngaging(fans: [0])
        await machine.plane.advance()

        // 60 °C everywhere, comfortably below the 90 °C release threshold — and § 3 engages
        // on the whole curated set *after* that report is in hand, so the subset guard has
        // nothing to catch and only the episode's age separates the two.
        let everyCuratedKey = Set(CriticalSensorSet.mac16x5.keys)
        await machine.emergencyTelemetry.interfere { [latch = machine.latch] in
            #expect(
                await latch.engage(
                    by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99),
                    answering: everyCuratedKey))
        }

        await machine.emergency.cycle()

        #expect(
            await machine.emergencyTelemetry.didFire,
            "the scenario never arranged the episode boundary")
        #expect(
            await machine.latch.isActive,
            "a 60 °C report taken before the episode engaged is not evidence it has passed")
        #expect(machine.safetyLog.lines(containing: "across an episode boundary").count == 1)
        #expect(
            await machine.leases.leaseCount == 0,
            "the cycle held but left a lease live over a machine at 99 °C")
    }

    /// The latch's half of that contract: a release names the episode it judged, and clears
    /// nothing else.
    ///
    /// `cycle()`'s guard establishes that the episode is older than the report; there is one
    /// more suspension point between that decision and the clear landing, and `release()`
    /// would clear whatever it found across it. `release(ifStill:)` compares and clears in
    /// one isolated step instead.
    ///
    /// The second half is why `Episode` carries a sequence rather than being compared whole:
    /// the re-engage below is structurally identical to the episode that ended — same key,
    /// same temperature, same answering set — and the SMC quantises, so an identical `Double`
    /// across a dip and a re-engage is ordinary rather than exotic. Structural equality would
    /// release it.
    ///
    /// Mutation-checked: make `release(ifStill:)` ignore its argument and clear whatever is
    /// holding, and both assertions below go red.
    @Test("A release clears the episode it was judged against, and no other")
    func aReleaseClearsOnlyTheEpisodeItJudged() async throws {
        let latch = ThermalEmergencyLatch()
        let hot = CriticalTemperature(key: smcKey("Tp01"), celsius: 99)
        let keys: Set<SMCKey> = [smcKey("Tp01"), smcKey("Tp09")]

        #expect(await latch.engage(by: hot, answering: keys))
        let judged = try #require(await latch.holding)

        // The episode ends and a new one begins, exactly as it would while a cycle sat in
        // `await latch.release(...)`.
        #expect(await latch.release())
        #expect(await latch.engage(by: hot, answering: keys))
        let live = try #require(await latch.holding)
        // Everything a structural comparison could look at is identical across the boundary.
        // Only the sequence separates them, which is the ABA case stated as an assertion.
        #expect(live.engagedBy == judged.engagedBy)
        #expect(live.keysAnsweringAtEngage == judged.keysAnsweringAtEngage)
        #expect(live.sequence == judged.sequence + 1)

        #expect(
            await latch.release(ifStill: judged) == false,
            "a decision about episode 1 cleared episode 2")
        #expect(await latch.isActive, "the episode nobody judged was released")

        #expect(await latch.release(ifStill: live))
        #expect(await latch.isActive == false)
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
