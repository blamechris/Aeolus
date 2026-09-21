import FanKit
import Testing

@testable import AeolusHelper

/// § 3's owed read-back of fans whose handback the firmware accepted
/// ([#295](https://github.com/blamechris/Aeolus/issues/295)), driven through `ThermalMachine`.
///
/// Two families. The first is **staleness across the read**: `GatedHandbackReadBack` parks the
/// read so a test can engage or hand back the fan while it is out, which a double with no
/// suspension point could not represent. The second is **where the read runs**: only on a
/// sighted cycle with the latch clear that did not fire — never on a blind, firing or latched
/// cycle — asserted against the requests the gate recorded, which counts calls made rather
/// than calls that finished.
///
/// The firmware under every fan here reads automatic (`FanCondition.nominal`), so a read that
/// is let through would clear the fan. That is deliberate: each test is about a read that must
/// **not** be acted on, or must not happen, and a firmware that answered "manual" would keep
/// the fan for the wrong reason.
@Suite("The thermal emergency's read-back of accepted handbacks", .timeLimit(.minutes(1)))
struct ThermalEmergencyHandbackTests {

    // MARK: - It never registers

    /// Marking a fan § 3 holds no permit for does nothing.
    ///
    /// Owed ⊆ registered is the invariant everything else leans on: an owed entry for an
    /// unregistered fan is a read issued about nothing, and a registration minted from a
    /// handback would be a bridge for a fan § 3 was never given — such as one startup
    /// reconciliation handed back, which ADR 0011 declines to contest.
    ///
    /// **Mutation:** delete `guard engagedFans[index] != nil else { return }` from
    /// `ThermalEmergency.handbackAccepted(fanAt:)`. Run: red — fan 1 is owed before the cycle,
    /// and the cycle reads it (the read then clears it, so the post-cycle owed check alone
    /// would not see the mutant).
    @Test("An accepted handback of an unregistered fan registers nothing")
    func anAcceptedHandbackNeverRegisters() async throws {
        let machine = ThermalMachine(stages: [.at(44)])
        await machine.emergency.handbackAccepted(fanAt: 1)
        #expect(
            await machine.emergency.fansOwedHandbackReadBack.isEmpty,
            "an accepted handback marked a fan § 3 holds no permit for")

        await machine.emergency.cycle()

        #expect(await machine.emergency.fansOwedHandbackReadBack.isEmpty)
        #expect(await machine.emergency.fansUnderManualControl.isEmpty)
        #expect(await machine.handbackReadBack.requests.isEmpty)
    }

    /// A fan the reader leaves out of its answer is treated as unreadable: kept, and owed.
    ///
    /// `HandbackReadingBack` promises every fan asked about is in the answer, and a conformer
    /// that breaks that promise must not be read as "automatic". The firmware under fan 0
    /// reads automatic here, so only the fallback decides the outcome.
    ///
    /// **Mutation:** in `ThermalEmergency.readBackAcceptedHandbacks()`, change
    /// `readings[fan] ?? .unreadable(detail: …)` to `readings[fan] ?? .automatic`. Run: red —
    /// fan 0 is forgotten on an answer that never mentioned it.
    @Test("A fan missing from the read-back's answer is kept")
    func aFanMissingFromTheAnswerIsKept() async throws {
        let machine = ThermalMachine(stages: [.at(44)])
        try await machine.engageManualControl(fan: 0)
        await machine.emergency.handbackAccepted(fanAt: 0)
        await machine.handbackReadBack.omit([0])

        await machine.emergency.cycle()

        #expect(await machine.handbackReadBack.requests == [[0]], "the read was never issued")
        #expect(
            await machine.emergency.fansUnderManualControl == [0],
            "§ 3 forgot a fan the read-back said nothing about")
        #expect(await machine.emergency.fansOwedHandbackReadBack == [0])
        #expect(
            machine.safetyLog.levels(containing: "the read-back did not answer for it")
                == [.notice])
    }

    /// A second handback of a fan that still reads manual is reported again.
    ///
    /// "Once per handback" is the logging rule, and a new acceptance is a new handback: the
    /// firmware was asked again and said yes again, and a fan still manual after *that* is a
    /// second fact worth a line. `handbackAccepted(fanAt:)` builds a fresh `OwedReadBack`,
    /// whose `reported` set starts empty.
    ///
    /// **Mutation:** in `ThermalEmergency.handbackAccepted(fanAt:)`, carry the old set over —
    /// `OwedReadBack(generation: handbackGeneration, reported: handbackOwed[index]?.reported
    /// ?? [])`. Run: red on `stillManual == [.fault, .fault]`.
    @Test("A fan still manual after a second accepted handback is reported again")
    func aReAcceptedHandbackIsReportedAfresh() async throws {
        let machine = ThermalMachine(stages: [.at(44)], fans: [0: .held(at: 2_400)])
        try await machine.engageManualControl(fan: 0)

        await machine.emergency.handbackAccepted(fanAt: 0)
        await machine.emergency.cycle()
        await machine.emergency.handbackAccepted(fanAt: 0)
        await machine.emergency.cycle()

        let stillManual = machine.safetyLog.levels(containing: "still reads manual")
        #expect(
            stillManual == [.fault, .fault],
            "a second accepted handback of a still-manual fan was not reported")
        #expect(await machine.emergency.fansOwedHandbackReadBack == [0])
    }

    // MARK: - Staleness across the read

    /// A read asked for one handback must not clear a newer one.
    ///
    /// The sequence: fan 0 engaged, handed back and accepted (generation 1); a cycle's read is
    /// parked; fan 0 is engaged again and handed back again (generation 2); the parked read
    /// comes back automatic. That answer is about a moment before the second engagement, and
    /// the second handback has not been read at all — so fan 0 stays registered and owed.
    /// The next cycle's read is about generation 2 and does clear it, which shows the entry is
    /// not stuck.
    ///
    /// **Mutation:** in `ThermalEmergency.readBackAcceptedHandbacks()`, change
    /// `guard var owed = handbackOwed[fan], owed.generation == generation` to
    /// `guard var owed = handbackOwed[fan]`. Run: red — fan 0 is forgotten on the stale read.
    @Test("A read taken before a newer handback does not clear it")
    func aStaleReadDoesNotClearANewerHandback() async throws {
        let machine = ThermalMachine(stages: [.at(44)])
        try await machine.engageManualControl(fan: 0)
        await machine.emergency.handbackAccepted(fanAt: 0)

        await machine.handbackReadBack.hold()
        let cycle = observing { await machine.emergency.cycle() }
        #expect(
            await yieldUntil("the read-back to park") { await machine.handbackReadBack.held == 1 })

        try await machine.engageManualControl(fan: 0)
        await machine.emergency.handbackAccepted(fanAt: 0)
        await machine.handbackReadBack.open()
        _ = try await finished("the cycle holding the stale read", cycle)

        #expect(
            await machine.emergency.fansUnderManualControl == [0],
            "a read describing the fan before its second engagement cleared the second handback")
        #expect(await machine.emergency.fansOwedHandbackReadBack == [0])

        await machine.emergency.cycle()
        #expect(await machine.emergency.fansUnderManualControl.isEmpty)
        #expect(await machine.handbackReadBack.requests == [[0], [0]])
    }

    /// A fan engaged again while its read is out is held again, and owes nothing.
    ///
    /// Without a second handback there is no newer generation to protect it — what protects it
    /// is that engaging drops the owed entry, so the read comes back to find nothing to clear.
    /// And a later cycle issues no read for it at all: it is held, not handed back.
    ///
    /// **Mutation:** delete `handbackOwed[fan.index] = nil` from
    /// `ThermalEmergency.manualControlEngaged(_:)`. Run: red — the parked read comes back
    /// automatic and forgets a fan that was engaged after it was asked for.
    @Test("A fan engaged again while its read is out stays held and owes nothing")
    func reEngagingDropsTheOwedReadBack() async throws {
        let machine = ThermalMachine(stages: [.at(44)])
        try await machine.engageManualControl(fan: 0)
        await machine.emergency.handbackAccepted(fanAt: 0)

        await machine.handbackReadBack.hold()
        let cycle = observing { await machine.emergency.cycle() }
        #expect(
            await yieldUntil("the read-back to park") { await machine.handbackReadBack.held == 1 })

        try await machine.engageManualControl(fan: 0)
        await machine.handbackReadBack.open()
        _ = try await finished("the cycle holding the stale read", cycle)

        #expect(
            await machine.emergency.fansUnderManualControl == [0],
            "a read asked for before the fan was engaged again forgot the engagement")
        #expect(await machine.emergency.fansOwedHandbackReadBack.isEmpty)

        await machine.emergency.cycle()
        #expect(
            await machine.handbackReadBack.requests == [[0]],
            "§ 3 read back a fan that is held, not handed back")
        #expect(await machine.emergency.fansUnderManualControl == [0])
    }

    // MARK: - Where the read runs

    /// A cycle that could not read its critical temperatures issues no owed read.
    ///
    /// **Mutation:** add `await readBackAcceptedHandbacks()` as the first statement of
    /// `ThermalEmergency.cycleSawNothing(_:)`. Run: red — one request recorded on a blind
    /// cycle.
    @Test("A blind cycle issues no owed read")
    func aBlindCycleIssuesNoRead() async throws {
        let machine = ThermalMachine(stages: [.blind()])
        try await machine.engageManualControl(fan: 0)
        await machine.emergency.handbackAccepted(fanAt: 0)

        await machine.emergency.cycle()

        #expect(await machine.handbackReadBack.requests.isEmpty)
        #expect(await machine.emergency.fansOwedHandbackReadBack == [0])
        #expect(await machine.emergency.fansUnderManualControl == [0])
    }

    /// A cycle that fires issues no owed read: it bridges the fan instead, and forgets it.
    ///
    /// **Mutation:** in `ThermalEmergency.cycle()`, hoist `await readBackAcceptedHandbacks()`
    /// above `if hottest.celsius > ceilingCelsius` so it runs on every unlatched cycle. Run:
    /// red — one request recorded on the firing cycle. (Running it *after* `fire` is not a
    /// visible mutation: `fire` has already forgotten every owed fan, so the guard returns.)
    @Test("A firing cycle issues no owed read, and bridges the owed fan")
    func aFiringCycleIssuesNoRead() async throws {
        let machine = ThermalMachine(stages: [.at(96)])
        try await machine.engageManualControl(fan: 0)
        await machine.emergency.handbackAccepted(fanAt: 0)

        await machine.emergency.cycle()

        #expect(await machine.handbackReadBack.requests.isEmpty)
        #expect(await machine.writes.contains(.commandTarget(fan: 0, rpm: 5_777)))
        #expect(await machine.emergency.fansOwedHandbackReadBack.isEmpty)
        #expect(await machine.emergency.fansUnderManualControl.isEmpty)
    }

    /// A latched cycle issues no owed read — here the one that releases the latch, the only
    /// latched path that does not take back everything registered first.
    ///
    /// The fan is engaged and handed back while § 3 holds, after the firing cycle, so it is
    /// still owed when the cool cycle releases. That cycle must not read; the next one, with
    /// the latch clear, does.
    ///
    /// **Mutation:** add `await readBackAcceptedHandbacks()` inside the
    /// `if hottest.celsius <= releaseThresholdCelsius, await latch.release(ifStill: episode)`
    /// block of `ThermalEmergency.cycle()`, before its `return`. Run: red — one request
    /// recorded on the releasing cycle.
    @Test("A latched cycle issues no owed read")
    func aLatchedCycleIssuesNoRead() async throws {
        let machine = ThermalMachine(stages: [.at(96), .at(44)])
        await machine.emergency.cycle()
        #expect(await machine.latch.isActive, "the scenario needs § 3 holding")

        try await machine.engageManualControl(fan: 0)
        await machine.emergency.handbackAccepted(fanAt: 0)
        await machine.plane.advance()

        await machine.emergency.cycle()
        #expect(await machine.latch.isActive == false, "the cool cycle should have released")
        #expect(
            await machine.handbackReadBack.requests.isEmpty,
            "§ 3 read back a fan on a cycle that was latched when it began")
        #expect(await machine.emergency.fansOwedHandbackReadBack == [0])

        await machine.emergency.cycle()
        #expect(await machine.handbackReadBack.requests == [[0]])
        #expect(await machine.emergency.fansUnderManualControl.isEmpty)
    }
}
