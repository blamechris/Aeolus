import AeolusXPC
import FanKit
import Testing

@testable import AeolusHelper

/// `docs/SAFETY.md` § 3, driven entirely through #100's `ScriptedControlPlane`.
///
/// No hardware. The rows that need a real fan to actually reach maximum belong to E5.6
/// ([#104](https://github.com/blamechris/Aeolus/issues/104)) and execute during E3/E4
/// bring-up; everything below is about what the mechanism *decides* and *writes*, which is
/// exactly what a scripted firmware can answer.
@Suite("The thermal emergency override")
struct ThermalEmergencyTests {

    // MARK: - § 8 does not throttle § 3

    /// **The mutation check ADR 0007's conflict 4 asks for.**
    ///
    /// The arithmetic, live rather than quoted: this machine's fan sits at 1800 RPM under a
    /// lease and its declared maximum is 5777, so a governed ramp at § 8's 200 RPM/s cap
    /// would take the number asserted below — twenty seconds with a CPU package above its
    /// ceiling, one safety mechanism throttling another.
    ///
    /// The emergency instead issues **one** `commandTarget`. Point
    /// `ThermalEmergency.writer` at a `GovernedFanWriter` — the whole of "removing the
    /// ramp-governor bypass" — and this test goes red on the count, not on a comment.
    /// `RampGovernorTests.aFullScaleRampIsAStaircase` shows what it would become.
    @Test("The emergency reaches maximum in one write, not a 20-second ramp")
    func theEmergencyReachesMaximumInOneWrite() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(96)])
        try await machine.lease(fans: [0])
        await machine.plane.advance()

        await machine.emergency.cycle()

        let writes: [ScriptedControlPlane.Attempt] = await machine.writes
        let commands = writes.filter { attempt in
            if case .commandTarget = attempt { return true }
            return false
        }
        #expect(commands == [.commandTarget(fan: 0, rpm: 5_777)])

        let secondsIfGoverned = RampGovernor().secondsToTraverse(from: 1_800, toward: 5_777)
        #expect(secondsIfGoverned > 19)
        #expect(commands.count == 1, "one write, not \(Int(secondsIfGoverned.rounded())) of them")
    }

    /// Max first, then automatic — and the order is the mechanism, not a preference. The
    /// maximum write is a fail-safe bridge across however long the OS takes to re-assume
    /// control; automatic is the destination.
    @Test("Both writes are observed, in order: maximum then restore")
    func bothWritesAreObservedInOrder() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(96)])
        try await machine.lease(fans: [0])
        await machine.plane.advance()

        await machine.emergency.cycle()

        let writes: [ScriptedControlPlane.Attempt] = await machine.writes
        #expect(writes == [.commandTarget(fan: 0, rpm: 5_777), .restoreToAutomatic(.fan(0))])
    }

    /// The failure asymmetry at the branch where it decides something. A firmware that
    /// refuses the bridge is exactly the machine that most needs the restore attempted.
    ///
    /// Delete the second `do`/`catch` in `bridgeToMaximumThenRelease(_:)` — or make it
    /// conditional on the first one succeeding — and this goes red.
    @Test("A refused maximum write does not skip the restore")
    func aRefusedMaximumStillRestores() async throws {
        let machine = ThermalMachine(
            stages: [.at(44), .at(96, writes: .refused(reason: "firmware said no"))])
        try await machine.lease(fans: [0])
        await machine.plane.advance()

        await machine.emergency.cycle()

        let writes: [ScriptedControlPlane.Attempt] = await machine.writes
        #expect(writes == [.commandTarget(fan: 0, rpm: 5_777), .restoreToAutomatic(.fan(0))])
        #expect(await machine.latch.isActive)
    }

    // MARK: - The ceiling, at the boundary

    /// `>` and not `>=`. The ceiling is the highest safe temperature rather than the lowest
    /// unsafe one, which is how `ThermalCeiling` already spells the comparison. Driven to
    /// *exactly* the ceiling and to the smallest representable step above it, because "well
    /// above" and "well below" would pass on an off-by-one in either direction.
    @Test("Exactly at the ceiling does not fire; the next representable value does")
    func theCeilingBoundaryIsExact() async throws {
        let atCeiling = ThermalMachine(stages: [.at(44), .at(ThermalCeiling.cpuCelsius)])
        try await atCeiling.lease(fans: [0])
        await atCeiling.plane.advance()
        await atCeiling.emergency.cycle()
        #expect(await atCeiling.latch.isActive == false)
        let atCeilingWrites: [ScriptedControlPlane.Attempt] = await atCeiling.writes
        #expect(atCeilingWrites.isEmpty)

        let justAbove = ThermalMachine(
            stages: [.at(44), .at(ThermalCeiling.cpuCelsius.nextUp)])
        try await justAbove.lease(fans: [0])
        await justAbove.plane.advance()
        await justAbove.emergency.cycle()
        #expect(await justAbove.latch.isActive)
    }

    /// The margin boundary, driven the same way. `<=` releases, so exactly the threshold
    /// lets go and the smallest step above it does not.
    @Test("The latch holds until temperature falls to the margin, exactly")
    func theLatchHoldsToTheMarginBoundary() async throws {
        let threshold = ThermalCeiling.cpuCelsius - ThermalCeiling.releaseHysteresisCelsius
        #expect(threshold == 90)

        let stillHot = ThermalMachine(stages: [.at(44), .at(96), .at(threshold.nextUp)])
        try await stillHot.lease(fans: [0])
        await stillHot.plane.advance()
        await stillHot.emergency.cycle()
        await stillHot.plane.advance()
        await stillHot.emergency.cycle()
        #expect(await stillHot.latch.isActive, "a reading above the margin must not release")

        let cooled = ThermalMachine(stages: [.at(44), .at(96), .at(threshold)])
        try await cooled.lease(fans: [0])
        await cooled.plane.advance()
        await cooled.emergency.cycle()
        await cooled.plane.advance()
        await cooled.emergency.cycle()
        #expect(await cooled.latch.isActive == false)
    }

    /// Between the ceiling and the margin is the band the hysteresis exists for: hot enough
    /// that letting go would be premature, cool enough that firing again would be wrong.
    @Test("A reading inside the hysteresis band neither releases nor re-fires")
    func theHysteresisBandHolds() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(96), .at(93)])
        try await machine.lease(fans: [0])
        await machine.plane.advance()
        await machine.emergency.cycle()
        let afterFiring: [ScriptedControlPlane.Attempt] = await machine.writes

        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(await machine.latch.isActive)
        let afterHolding: [ScriptedControlPlane.Attempt] = await machine.writes
        #expect(afterHolding == afterFiring, "no second round of writes")
    }

    // MARK: - The lease

    /// Whole, not per-fan surgery. A client left holding a lease over a subset it can no
    /// longer command would be told it has control it does not have — `CLAUDE.md` rule 6,
    /// reached by bookkeeping instead of by a write.
    @Test("The whole lease covering an affected fan is revoked")
    func theWholeLeaseIsRevoked() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(96)])
        try await machine.lease(fans: [0, 1])
        #expect(await machine.leases.leaseCount == 1)
        await machine.plane.advance()

        await machine.emergency.cycle()

        #expect(await machine.leases.leaseCount == 0)
        #expect(await machine.restorer.causes == [.thermalEmergency])
        #expect(await machine.restorer.restoredFans == [Set([0, 1])])
    }

    /// Resuming is a fresh `acquireLease`, and it is refused while the latch holds — with a
    /// fault case E2 already shipped, so `AeolusXPCVersion` does not move.
    ///
    /// Without this the emergency would hand the fans straight back to the workload that
    /// overheated the machine, on a cycle bounded only by how fast the client retries.
    @Test("A revoked holder asking again while latched is refused, never re-granted")
    func aRevokedHolderIsNotSilentlyReGranted() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(96)])
        let connection = ConnectionID()
        try await machine.lease(fans: [0], from: connection)
        await machine.plane.advance()
        await machine.emergency.cycle()

        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            _ = try await machine.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: connection)
        }
        #expect(await machine.leases.leaseCount == 0)
    }

    /// The control for the refusal above: once the latch lets go, the same request is
    /// granted. Without it, "refused" would be consistent with the fixture being broken.
    @Test("Once the latch releases, a lease is granted again")
    func aReleasedLatchGrantsAgain() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(96), .at(60)])
        try await machine.lease(fans: [0])
        await machine.plane.advance()
        await machine.emergency.cycle()
        await machine.plane.advance()
        await machine.emergency.cycle()
        #expect(await machine.latch.isActive == false)

        let lease = try await machine.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(lease.holderDescription == "test client")
    }

    /// The latch is engaged whether or not anything is leased. A machine above its ceiling
    /// is not a machine to grant a *new* lease on, and the refusal is the whole point.
    @Test("Firing with nothing under manual control still latches")
    func firingWithNoLeaseStillLatches() async throws {
        let machine = ThermalMachine(stages: [.at(96)])

        await machine.emergency.cycle()

        #expect(await machine.latch.isActive)
        let writes: [ScriptedControlPlane.Attempt] = await machine.writes
        #expect(writes.isEmpty, "there was nothing to take back")
        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            _ = try await machine.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    // MARK: - The failure asymmetry

    /// A cycle that could not read is **never** a reason to release. Delete the
    /// `latch.isActive` branch in `cycleSawNothing(_:)` — or let an unreadable cycle fall
    /// through to the release comparison — and this goes red.
    @Test("An unreadable cycle never releases the latch")
    func anUnreadableCycleNeverReleases() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(96), .blind()])
        try await machine.lease(fans: [0])
        await machine.plane.advance()
        await machine.emergency.cycle()
        #expect(await machine.latch.isActive)

        await machine.plane.advance()
        await machine.emergency.cycle()

        #expect(await machine.latch.isActive)
    }

    /// The other half: a single unreadable cycle does not *fire* either. Firing on a
    /// transient would take the fans from a client on one missed read; persistent read
    /// failure is divergence and belongs to
    /// [#126](https://github.com/blamechris/Aeolus/issues/126).
    @Test("An unreadable cycle does not fire on its own")
    func anUnreadableCycleDoesNotFire() async throws {
        let machine = ThermalMachine(stages: [.at(44), .blind()])
        try await machine.lease(fans: [0])
        await machine.plane.advance()

        await machine.emergency.cycle()

        #expect(await machine.latch.isActive == false)
        let writes: [ScriptedControlPlane.Attempt] = await machine.writes
        #expect(writes.isEmpty)
        #expect(await machine.leases.leaseCount == 1)
    }

    // MARK: - The ceiling is tunable downward only

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

    // MARK: - The contract does not move

    /// Every refusal § 3 raises is a fault case E2 already shipped. ADR 0007 promised no
    /// version bump for the whole of E5, and this is the assertion that keeps the promise
    /// checkable in the change that consumes the vocabulary.
    @Test("AeolusXPCVersion is unchanged by the thermal emergency")
    func theProtocolVersionIsUnchanged() {
        #expect(AeolusXPCVersion.current == 1)
    }
}
