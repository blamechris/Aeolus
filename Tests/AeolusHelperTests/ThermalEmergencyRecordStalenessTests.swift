import AeolusXPC
import FanKit
import SMCCore
import Testing

@testable import AeolusHelper

/// Split out of `ThermalEmergencyStalenessTests` in
/// [#287](https://github.com/blamechris/Aeolus/issues/287): that suite is about a fact going
/// stale across § 3's read — the episode, or the latch it holds. This one is about the
/// **reading itself** going stale, and the mechanism it lands in is
/// `CriticalTemperatureCache.record(_:since:)` rather than the latch at all.
///
/// Both tests below drive the same window `ThermalEmergencyStalenessTests` does — a real
/// `ThermalEmergency.cycle()`, with `InterferingCriticalTemperatures` landing a second write
/// to the cache while § 3's own 34-key read is still in flight — so they stay siblings of
/// that suite's scenarios rather than unit tests of the cache in isolation.
/// `CriticalTemperatureCacheFlightTests` already covers the same guard reached through the
/// single-flight window directly, and its own doc block says membership there is by
/// mechanism, not by interleaving; these two are here because the interleaving is a cycle's,
/// specifically.
@Suite("The thermal emergency, recording its own reading across a suspension point")
struct ThermalEmergencyRecordStalenessTests {

    // MARK: - The cycle's own recording, across its own read

    /// A cycle must not overwrite a blindness recorded **while it was reading**.
    ///
    /// [#280](https://github.com/blamechris/Aeolus/issues/280). The other tests in this suite
    /// are about a fact going stale across the cycle's read; this one is about the *reading
    /// itself* going stale, and the mechanism it lands in is `CriticalTemperatureCache`.
    ///
    /// The scenario is the daemon's, step for step. § 3's cycle takes its 34-key read of a
    /// healthy machine. While that read is in flight a client's grant finds the cache expired,
    /// reads for itself, and **fails** — the SMC has stopped answering — so a blindness is
    /// recorded. The cycle then resumes holding a report of the machine *as it was before it
    /// stopped answering*, and records it. Without a comparison that sighting displaces the
    /// blindness, and every `acquireLease` for the next `maxAge` is granted on the strength of
    /// a reading taken before the machine went dark. That is ADR 0010 D3's named unsafe
    /// direction, reached by the one writer the supersession guard did not cover.
    ///
    /// The discriminator is the **grant**, not a counter: a cache that kept the blindness
    /// refuses, and a cache that let the sighting through grants. Both serve from memory, so
    /// `readsIssued` is 0 either way and cannot tell them apart.
    ///
    /// ## The two advances are what make `beganReading()`'s *placement* an assertion
    ///
    /// This is the lesson `aFlightDoesNotOverwriteWhatWasRecordedWhileItWasAway` paid for, in
    /// the mirror position. On a frozen `TestClock` every instant compares equal, so the guard
    /// holds for the right answer and for the wrong one alike, and moving
    /// `let readingStart = await sightings.beganReading()` below the read leaves the whole
    /// repository green while making the comparison a no-op in the daemon.
    ///
    /// Advancing on **both sides** of § 3's record puts the blindness strictly between the
    /// cycle's start and its resume: `1ms >= 0ms` holds for the true start, and `1ms >= 2ms`
    /// fails for a stamp taken after the read. Strictly between, rather than equal to the
    /// start, because `>=`'s boundary is
    /// `aFlightDoesNotOverwriteWhatWasRecordedWhileItWasAway`'s to own — this test is about
    /// *which instant* is compared, not about which way the tie breaks. Two milliseconds
    /// total, well inside `maxAge`, because `aStaleSightingIsNotServed` owns the age bound.
    ///
    /// **Mutation (M10):** move `let readingStart = await sightings.beganReading()` in
    /// `ThermalEmergency.cycle()` from above the read to immediately before the
    /// `record(.sighted(report), since:)` call. Run: red here, and green everywhere else in
    /// the repository — which is what the two advances are for.
    ///
    /// **Mutation (M11):** drop the comparison — replace the body of
    /// `CriticalTemperatureCache.record(_:since:)` with a bare `record(sighting)`, which is
    /// how the cycle's recording was written before #280. Run: red.
    @Test("A cycle does not overwrite a blindness recorded during its own read")
    func aCycleDoesNotOverwriteABlindnessRecordedDuringItsRead() async throws {
        let machine = ThermalMachine(stages: [.at(44)])

        // Fired after § 3's read has taken its reading and before `cycle()` resumes to record
        // it — the whole of the window #280 is about.
        // Bound outside the closure rather than captured in a list: both are reference types
        // and `Sendable`, so this is the same capture with none of the formatting argument.
        let clock = machine.clock
        let sightings = machine.sightings
        await machine.emergencyTelemetry.interfere {
            clock.advance(by: .milliseconds(1))
            await sightings.recordAsASetupStep(
                .blind(FanControlPlaneError.readFailed(detail: "stale port")))
            clock.advance(by: .milliseconds(1))
        }

        await machine.emergency.cycle()

        #expect(
            await machine.emergencyTelemetry.didFire,
            "the blindness never landed inside the cycle's read — this scenario proves nothing")
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .noThermalTelemetry)
        ) {
            try await machine.acquireWithoutEngaging(fans: [0])
        }
        #expect(
            await machine.sightings.readsIssued == 0,
            "the grant read for itself, so this proves nothing about what the cache held")
        #expect(
            await machine.latch.holding == nil,
            "44 °C is an idle machine: this scenario is about the cycle's success path")
    }

    /// The same comparison, in the case where **both** outcomes are sightings.
    ///
    /// `aCycleDoesNotOverwriteABlindnessRecordedDuringItsRead` above pins the direction that
    /// is a safety defect — a sighting displacing a blindness grants leases on a helper
    /// found unable to see. This pins the direction that is a **staleness** defect, and
    /// nothing did: narrowing the guard to
    /// `if let recorded, case .blind = recorded.sighting, recorded.at >= start.instant`
    /// leaves the entire 1,634-test suite green. Run, not reasoned — the whole suite passed.
    ///
    /// What that mutation costs is the bound ADR 0010 states in its headline: the cycle's
    /// reading, taken at `t0`, is restamped at `t0 + the read` and then served for a full
    /// `maxAge` from there, so a grant can be answered from a reading close to **two** cycle
    /// periods old while both documents promise one. No lease is wrongly granted — both
    /// records are sightings — which is exactly why it needs its own test rather than
    /// riding on the one above.
    ///
    /// The discriminator is the **temperature**. § 3 reads a 44 °C machine; a fresher
    /// reading of 60 °C lands while that read is in flight; the cache must serve 60. Under
    /// the mutation it serves 44, which is the stale reading the bound forbids.
    /// `readsIssued == 0` is the control: it proves the answer came from memory rather than
    /// from a re-read that would have returned 44 legitimately.
    ///
    /// **Mutation (M13):** add `case .blind = recorded.sighting,` to the `.sighted` branch's
    /// condition in `CriticalTemperatureCache.record(_:since:)`. Run: red here, and green
    /// across the whole repository before this test existed.
    @Test("A cycle does not restamp its own reading over a fresher one")
    func aCycleDoesNotOverwriteAFresherSighting() async throws {
        let machine = ThermalMachine(stages: [.at(44)])
        let fresher = try CriticalTemperatureReport(
            readings: [CriticalTemperature(key: smcKey("Tp01"), celsius: 60)],
            unreadableKeys: [])

        let clock = machine.clock
        let sightings = machine.sightings
        await machine.emergencyTelemetry.interfere {
            clock.advance(by: .milliseconds(1))
            await sightings.recordAsASetupStep(.sighted(fresher))
            clock.advance(by: .milliseconds(1))
        }

        await machine.emergency.cycle()

        #expect(
            await machine.emergencyTelemetry.didFire,
            "the fresher reading never landed inside the cycle's read — this proves nothing")
        let served = try await machine.sightings.sighting()
        #expect(
            served.readings.map(\.celsius) == [60],
            "the cycle restamped its own older reading over the fresher one")
        #expect(
            await machine.sightings.readsIssued == 0,
            "the answer came from a fresh read, so it says nothing about what was held")
    }
}
