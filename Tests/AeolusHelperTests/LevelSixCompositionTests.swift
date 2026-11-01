import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The composition builds one level 6 and hands the authority that one (ADR 0014's A6 PR-3
/// amendment).
///
/// Its siblings sit beside the pins they mirror: the driver's level in
/// `EngagementDriverLevelTests`, and the gate it waits on in `ExaminationGateRouteTests`, each
/// beside § 5's. This holds the identity those two read through: the `leaseApplier` the
/// composition stores is the instance `SupervisedFanAuthority` delegates to, so a pin on the
/// stored one is a pin on the one a client reaches.
@Suite("The composition builds one level 6, and the authority holds it", .timeLimit(.minutes(1)))
struct LevelSixCompositionTests {

    private static let applyInProgress = AeolusXPCFault.helperFailed(
        detail: LeaseApplyRules.Detail.applyInProgress)

    /// With an `apply` through the authority held inside its engagement step, an `apply` on the
    /// composition's `leaseApplier`, under the same lease, meets that `apply`'s claim and is
    /// refused before it reads anything. The claim is per instance, so two instances would each
    /// admit one: the second would wait for fan 0's gate instead, which on a `TestClock` runs out
    /// at once, and be answered `releaseInProgress`.
    ///
    /// **Mutation:** in `HelperComposition.init`, hand the authority a second instance, a
    /// `LeaseApplier` built with the same arguments. Run: red, answered `releaseInProgress`.
    @Test("The stored level 6 is the one the authority delegates to")
    func theStoredLevelSixIsTheAuthoritys() async throws {
        let machine = await LevelSixMachine()
        let lease = try await machine.lease()
        let engagement = HopParking()
        await machine.writes.interfere(beforeEngageStep: 1) { await engagement.park() }

        let first = observing { try await machine.apply(rpm: 4_400, under: lease) }
        // Required, not expected: unparked, the apply below would park in the armed hook itself
        // and hold the test to its time limit.
        try #require(
            await yieldUntil("the authority's apply to park") { await engagement.isParked })
        let second = await LevelSixMachine.answer {
            try await machine.helper.leaseApplier.apply(
                [FanSetting(fanIndex: 0, control: .fixed(rpm: 5_000))], leaseID: lease,
                from: machine.holder)
        }
        await engagement.release()
        try await finished("the authority's apply", first)

        #expect(
            second == Self.applyInProgress,
            """
            an apply on the composition's level 6 was answered \(String(describing: second)) \
            while the authority's was in flight: they are not the same instance.
            """)
        #expect(await machine.helper.reclamationWatchdog.lastCommanded(ofFan: 0)?.rpm == 4_400)
    }

    // MARK: - What the composed level 6 reads

    /// Level 6's driver asks the composition's one § 3 latch before it engages: with § 3 latched
    /// after the grant, an `apply` through the authority is refused `thermalEmergencyActive` and
    /// nothing reaches the firmware. A latch of the driver's own would read clear, so it would
    /// engage and command the fan during the emergency; only the applier's check at item 4 would
    /// still refuse the reply.
    ///
    /// **Mutation (G2):** in `HelperComposition.init`, compose level 6's driver with `latch:
    /// ThermalEmergencyLatch()`. Run: red, fan 0 engaged and commanded.
    @Test("Level 6's driver reads the composition's latch, and engages nothing under § 3")
    func theComposedDriverReadsTheComposedLatch() async throws {
        let machine = await LevelSixMachine()
        let lease = try await machine.lease()
        let before = await machine.firmware.attempts.count
        await machine.latchTheThermalEmergency()

        let answer = await LevelSixMachine.answer {
            try await machine.apply(rpm: 4_400, under: lease)
        }

        let writes = await machine.forwardWrites(after: before)
        #expect(writes.isEmpty, "level 6 wrote \(writes) while § 3 was latched")
        #expect(answer == .thermalEmergencyActive, "answered \(String(describing: answer))")
    }

    /// The applier's reply asks the same latch (item 4): with § 3 latching once fan 0's command has
    /// landed, the `apply` is refused `thermalEmergencyActive`, never answered applied.
    ///
    /// **Mutation (G3):** in `HelperComposition.init`, compose the applier with `latch:
    /// ThermalEmergencyLatch()`. Run: red, answered applied.
    @Test("Level 6's reply reads the composition's latch")
    func theComposedReplyReadsTheComposedLatch() async throws {
        let machine = await LevelSixMachine(during: .commandWrite)
        let lease = try await machine.lease()
        await machine.writes.interfere { await machine.latchTheThermalEmergency() }

        let answer = await LevelSixMachine.answer {
            try await machine.apply(rpm: 4_400, under: lease)
        }

        #expect(await machine.writes.didFire, "§ 3 never latched inside the command write")
        #expect(
            answer == .thermalEmergencyActive,
            "an apply § 3 latched under was answered \(String(describing: answer))")
    }

    /// Level 6 asks the plane's own write capability, the seam the lease core and the snapshot
    /// read. A lease granted while the plane reported `.built`, then an `apply` once it reports
    /// `.notBuilt`, which only a test can produce, is refused `writePathNotBuilt` and writes
    /// nothing.
    ///
    /// **Mutation (G6):** in `HelperComposition.init`, compose the applier with a capability
    /// reporter that always answers `.built`. Run: red, fan 0 engaged and commanded.
    @Test("Level 6 reads the plane's write capability")
    func theComposedLevelSixReadsThePlanesCapability() async throws {
        let machine = await LevelSixMachine()
        let lease = try await machine.lease()
        let before = await machine.firmware.attempts.count
        machine.writes.report(.notBuilt)

        let answer = await LevelSixMachine.answer {
            try await machine.apply(rpm: 4_400, under: lease)
        }

        let writes = await machine.forwardWrites(after: before)
        #expect(writes.isEmpty, "level 6 wrote \(writes) on a plane reporting .notBuilt")
        #expect(answer == .manualControlUnavailable(reason: .writePathNotBuilt))
    }

    /// Level 6's driver measures its unlock's poll on the composition's clock: on a `ManualClock`
    /// nobody advances, an engagement waiting for its yield sleeps on that clock, and moving it
    /// lets the `apply` finish applied.
    ///
    /// The clock is moved one poll interval at a time, and only once the driver is seen asleep on
    /// it, with a bounded wait for that between moves. Moved blind, it could pass the unlock's
    /// 3.5 s yield budget before the driver reached its next step, and correct wiring would be
    /// refused `yieldDidNotArrive`.
    ///
    /// **Mutation (G5):** in `HelperComposition.init`, compose level 6's driver with `clock:
    /// SystemMonotonicClock()`. Run: red, no sleeper on the composed clock.
    @Test("Level 6's driver polls on the composition's clock")
    func theComposedDriverPollsOnTheComposedClock() async throws {
        let clock = ManualClock()
        let machine = await LevelSixMachine(unlock: .heldUntilForced(stepsToYield: 1), clock: clock)
        let lease = try await machine.lease()

        let applying = observing { try await machine.apply(rpm: 4_400, under: lease) }
        let polled = await yieldUntil("level 6's poll to sleep on the composed clock") {
            clock.sleepers == 1
        }
        // Each move waits, bounded, for the driver to park on the clock or for the apply to end,
        // and moves only past a parked sleeper. `advance(by:)` ends that sleep before it returns,
        // so the next wait is for the driver's next poll.
        let done = applying.isFinished
        var advances = 0
        while advances < 10 {
            _ = await pollUntil {
                if clock.sleepers == 1 { return true }
                return await done.isSet
            }
            guard clock.sleepers == 1, await !done.isSet else { break }
            clock.advance(by: UnlockLimits.pollInterval)
            advances += 1
        }
        try await finished("the apply", applying)

        #expect(polled, "the engagement's poll did not sleep on the composition's clock")
        #expect(try await machine.firmware.firmwareMode(ofFan: 0) == .manual)
    }
}
