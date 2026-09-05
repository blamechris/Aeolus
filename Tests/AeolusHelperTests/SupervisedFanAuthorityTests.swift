import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The privilege boundary's own type, driven **only** through `helper.authority`.
///
/// ## Why this suite exists, in the words of the review that demanded it
///
/// `HelperRestorerTests` composes the same graph and drives `helper.leases` directly, which
/// tests the restorer wire and says nothing at all about the type the listener is handed. An
/// adversarial pass proved the gap by mutation: replacing `acquireLease`'s forward with a
/// literal `.writePathNotBuilt` throw, emptying `connectionDidInvalidate`, deleting
/// `releaseEveryLease()` from `restoreAllToAutomatic`, deleting the `heldLease`
/// authorisation from `apply`, and reordering `snapshot()` to read the lease before the
/// machine **all left the whole suite green**. The only coverage `SupervisedFanAuthority`
/// had was the hardware-gated test whose `#expect(throws: .writePathNotBuilt)` a literal
/// satisfies by construction.
///
/// That is the same defect in the same shape as #163 itself — a mechanism wired to nothing,
/// with a test that cannot tell. So every test below reaches the lease core through
/// `helper.authority` and asserts on `helper.leases`, and each names the mutation that turns
/// it red.
///
/// ## The plane answers `.built`, deliberately
///
/// `ScriptedControlPlane.writeCapability` is `.built`, so `LeaseAuthority.acquireLease`
/// clears its first gate and a lease can actually be granted here. On real hardware today
/// `SMCFanControlPlane` answers `.notBuilt` and nothing below is reachable —
/// `HelperHardwareTests` covers that end, and the two together are the whole of the gate:
/// the seam decides, and neither answer is a literal in this file.
///
/// The supervisors are not started, for `HelperRestorerTests`' reason: three 1 Hz loops over
/// the same scripted firmware would move the registries these tests assert on.
@Suite("The helper's supervised authority", .timeLimit(.minutes(1)))
struct SupervisedFanAuthorityTests {

    /// A composed helper with fan 0 in both safety registries and the restorer bound, which
    /// is the state the daemon is in once `bringUp()` has run and E3 has engaged a fan.
    private static func engaged(
        writes: ScriptedControlPlane.WriteBehaviour = .honoured
    ) async throws -> HelperComposition<ScriptedControlPlane> {
        let helper = HelperRestorerTests.composed(writes: writes)
        await helper.bindSafetyRegistries()
        try await HelperRestorerTests.engage(fan: 0, in: helper)
        return helper
    }

    private static func bothRegistries(
        of helper: HelperComposition<ScriptedControlPlane>
    ) async -> (reclamation: Set<Int>, thermal: Set<Int>) {
        (
            await helper.reclamationWatchdog.fansUnderManualControl,
            await helper.thermalEmergency.fansUnderManualControl
        )
    }

    // MARK: - Acquisition

    /// A grant asked of the authority reaches the lease table.
    ///
    /// The assertion is on `helper.leases`, not on the returned `Lease`, because a forward
    /// that fabricated a value would satisfy the latter. What is being tested is that the
    /// authority and the lease core are the same mechanism.
    ///
    /// **Mutation:** replace the body of `SupervisedFanAuthority.acquireLease` with
    /// `throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)`. Run: red.
    @Test("A lease acquired through the authority is a lease the core holds")
    func acquiringThroughTheAuthorityReachesTheLeaseCore() async throws {
        let helper = try await Self.engaged()

        let lease = try await helper.authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())

        #expect(
            await helper.leases.leaseCount == 1,
            """
            the authority answered a grant the lease core knows nothing about, so the TTL \
            loop is counting down on an empty table while a client believes it holds a fan.
            """)
        #expect(await helper.leases.activeLease()?.id == lease.id)
    }

    // MARK: - Renewal and release

    /// Renewal moves the deadline, and release empties the table and both registries.
    ///
    /// The asserted field is `expiresAt`, and it moves on the **real wall clock**:
    /// `LeaseAuthority` derives it from its injected `wallClock()`, which
    /// `HelperComposition` does not override, while only `deadline` is taken from the
    /// injected `clock`. So the advance below separates the two *deadlines*; it is not what
    /// makes this assertion able to fail, and deleting it leaves the suite green. What makes
    /// it able to fail is that a renewal which merely *authorised* — returning the record it
    /// found rather than extending it — returns the record's original `expiresAt`, which is
    /// not greater than its own.
    ///
    /// That the renewed **deadline** is the one expiry honours is
    /// `LeaseExpiryTests.renewalRestartsTheTimeToLive`'s, against the lease core directly.
    /// This test's subject is the forward: that the authority reaches that core at all.
    ///
    /// **Mutation:** replace `renewLease`'s forward with
    /// `try await leases.heldLease(id: id, from: connection).asLease()`. Run: red on the
    /// deadline. **Mutation:** empty the body of `SupervisedFanAuthority.releaseLease`.
    /// Run: red on the count and on both registries.
    @Test("Renewing extends the deadline and releasing empties the table and the registries")
    func renewingAndReleasingReachTheLeaseCore() async throws {
        let clock = TestClock()
        let helper = HelperRestorerTests.composed(clock: clock)
        await helper.bindSafetyRegistries()
        try await HelperRestorerTests.engage(fan: 0, in: helper)
        let connection = ConnectionID()
        let lease = try await helper.authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)

        clock.advance(by: .seconds(10))
        let renewed = try await helper.authority.renewLease(id: lease.id, from: connection)

        #expect(renewed.id == lease.id, "renewal issued a different lease")
        #expect(
            renewed.expiresAt > lease.expiresAt,
            """
            the authority's renewal did not move the deadline, so a client heartbeating \
            correctly still loses its fans at the original TTL.
            """)

        try await helper.authority.releaseLease(id: lease.id, from: connection)

        #expect(await helper.leases.leaseCount == 0, "the released lease is still in the table")
        let registries = await Self.bothRegistries(of: helper)
        #expect(
            registries.reclamation.isEmpty,
            "§ 5 is still watching a fan whose lease was released through the authority")
        #expect(
            registries.thermal.isEmpty,
            "§ 3 still lists a fan whose lease was released through the authority")
    }

    // MARK: - Connection death

    /// A dead connection tears its leases down and is tombstoned, through the authority.
    ///
    /// This is the teardown path a client cannot ask for and cannot decline, and it is the
    /// one the listener drives — `HelperConnectionSession` calls `connectionDidInvalidate`
    /// on whatever `FanAuthority` it was given. An authority whose implementation is empty
    /// is a helper in which `kill -9` leaves the fans exactly where they were, which is the
    /// failure `docs/SAFETY.md` opens with.
    ///
    /// **Mutation:** empty the body of `SupervisedFanAuthority.connectionDidInvalidate`.
    /// Run: red on the count, the tombstone, and both registries.
    @Test("An invalidated connection loses its leases and is tombstoned")
    func connectionDeathReachesTheLeaseCore() async throws {
        let helper = try await Self.engaged()
        let connection = ConnectionID()
        _ = try await helper.authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)

        await helper.authority.connectionDidInvalidate(connection)

        #expect(
            await helper.leases.leaseCount == 0,
            "a dead client still holds a lease, so nothing will hand its fan back")
        #expect(
            await helper.leases.holdsTombstone(for: connection),
            """
            no tombstone was recorded, so a grant already in flight on the dead connection \
            can still bind a lease to it — which is #95.
            """)
        let registries = await Self.bothRegistries(of: helper)
        #expect(registries.reclamation.isEmpty, "§ 5 is still watching a dead client's fan")
        #expect(registries.thermal.isEmpty, "§ 3 still lists a dead client's fan")
    }

    // MARK: - The panic verb

    /// § 7's panic verb drops every lease and hands the fans back.
    ///
    /// **Mutation:** delete `await leases.releaseEveryLease()` from
    /// `SupervisedFanAuthority.restoreAllToAutomatic`, leaving only the log line. Run: red —
    /// which is the point, because the mutant still logs *"restored all to automatic"* and a
    /// test reading the log would agree with it.
    @Test("The panic verb drops every lease and hands its fans back")
    func restoreAllToAutomaticReachesTheLeaseCore() async throws {
        let helper = try await Self.engaged()
        _ = try await helper.authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())

        try await helper.authority.restoreAllToAutomatic(from: ConnectionID())

        #expect(
            await helper.leases.leaseCount == 0,
            "the panic verb returned without dropping a lease")
        #expect(
            await helper.reclamationWatchdog.fansUnderManualControl.isEmpty,
            """
            § 5 is still watching a fan the panic path handed back, so its next cycle reads \
            that fan as reclaimed by the operating system.
            """)
    }

    // MARK: - apply: authorises, then refuses

    /// `apply` authorises before it refuses, so a client debugging its own lease handling is
    /// told *which* thing is wrong.
    ///
    /// A blanket `.writePathNotBuilt` for every input would hide `.leaseUnknown`,
    /// `.leaseNotHeldByThisConnection` and `.leaseExpired` behind one answer, and would also
    /// mean the authorisation is not there to be in front of the write on the day E3 adds
    /// one. That is the whole reason the check is written before a body that cannot use it.
    ///
    /// **Mutation:** delete `_ = try await leases.heldLease(id: leaseID, from: connection)`.
    /// Run: red — the unknown lease is answered `.writePathNotBuilt`.
    @Test("Applying with an unknown lease is refused as unknown, not as unwritable")
    func applyAuthorisesBeforeItRefuses() async throws {
        let helper = try await Self.engaged()

        await #expect(throws: AeolusXPCFault.leaseUnknown) {
            try await helper.authority.apply([], leaseID: UUID(), from: ConnectionID())
        }
    }

    /// A **held** lease over a seam that can write is still refused, and the refusal names
    /// the build.
    ///
    /// This is the assertion that stands behind removing the authority's stored
    /// `FanWriteCapabilityReporting`: `apply` refuses because there is no control loop in
    /// that type, not because the seam said `.notBuilt`. `ScriptedControlPlane` answers
    /// `.built`, so a capability-sourced refusal would have to say something else here.
    /// Without this test the deleted property and the doc comment that contradicted it were
    /// indistinguishable from a working gate.
    ///
    /// **Mutation:** make `apply` return normally after the authorisation, as E3 eventually
    /// will. Run: red — which is the reminder that E3 owns replacing this test, not
    /// deleting it.
    @Test("Applying with a held lease is refused even when the seam can write")
    func supervisedApplyRefusesEvenWhenTheSeamCanWrite() async throws {
        let helper = try await Self.engaged()
        #expect(
            helper.plane.writeCapability == .built,
            "this test is vacuous unless the seam under the helper really can write")
        let connection = ConnectionID()
        let lease = try await helper.authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
        ) {
            try await helper.authority.apply(
                [FanSetting(fanIndex: 0, control: .fixed(rpm: 2_400))],
                leaseID: lease.id,
                from: connection)
        }
    }

    // MARK: - The snapshot's ordering

    /// The lease is read **after** the machine, so a lease that lapses during the reads is
    /// reported as gone rather than as live.
    ///
    /// `CLAUDE.md` rule 6 is the whole of it: a client shown a lease that has already stopped
    /// holding the fans acts on it. `LeaseAuthority.activeLease()` sweeps lapsed leases
    /// first, so the order of the two reads inside `snapshot()` decides which side of the
    /// sweep the client's answer comes from — and the difference is only observable if time
    /// passes *inside* the machine read. That is what `ClockAdvancingProvider` is for, and it
    /// is why `HelperComposition.init` takes a clock at all.
    ///
    /// The first snapshot is not scaffolding: it asserts the lease is reported while it is
    /// live, so that the second assertion is about the sweep rather than about a lease the
    /// authority never reported at all.
    ///
    /// **Mutation:** in `SupervisedFanAuthority.snapshot()`, hoist the lease read above the
    /// machine read — `let lease = await leases.activeLease()` before
    /// `let machine = try await reading.snapshot()`. Run: red.
    @Test("The lease is read after the machine, so one lapsing mid-read is reported gone")
    func theLeaseIsReadAfterTheMachineNotBefore() async throws {
        let clock = TestClock()
        let provider = ClockAdvancingProvider(
            wrapping: fanProvider(fanCount: 1), advancing: clock)
        let helper = HelperRestorerTests.composed(clock: clock, snapshotProvider: provider)
        await helper.bindSafetyRegistries()
        let lease = try await helper.authority.acquireLease(
            LeaseFixture.request(fans: [0], timeToLive: 30), from: ConnectionID())

        #expect(
            try await helper.authority.snapshot().activeLease?.id == lease.id,
            "a live lease is not being reported at all, so the sweep below proves nothing")

        // The next read of the machine takes longer than the lease has left.
        await provider.arm(advancing: .seconds(60))
        let snapshot = try await helper.authority.snapshot()

        #expect(
            snapshot.activeLease == nil,
            """
            the snapshot reports a lease that lapsed while its own fan values were being \
            read. The fans in this very snapshot are back on automatic control, and the \
            client is being told something is holding them.
            """)
        #expect(await helper.leases.leaseCount == 0, "the lapsed lease was never swept")
    }
}

/// A `SensorProvider` that moves a `TestClock` forward once, in the middle of a read.
///
/// The only way to make "the machine is read first" observable. Every other seam in the
/// helper puts the clock outside the read, where both statement orders produce the same
/// answer — which is exactly why the reordering mutation survived every test in the
/// repository until this one.
///
/// **Armed explicitly, and spent once.** `LeaseAuthority.acquireLease` enumerates the fans
/// through this same provider, so a double that advanced on every read would lapse the lease
/// during the grant that created it and the test would pass for the wrong reason.
actor ClockAdvancingProvider: SensorProvider {

    nonisolated let identifier = "clock-advancing"

    private let wrapped: FakeSensorProvider
    private let clock: TestClock
    private var pending: Duration?

    init(wrapping wrapped: FakeSensorProvider, advancing clock: TestClock) {
        self.wrapped = wrapped
        self.clock = clock
    }

    /// Advances the clock by `duration` during the next read, and only that one.
    func arm(advancing duration: Duration) {
        pending = duration
    }

    var isAvailable: Bool {
        get async { await wrapped.isAvailable }
    }

    func readAll() async throws -> [SensorReading] {
        advanceIfArmed()
        return try await wrapped.readAll()
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        advanceIfArmed()
        return try await wrapped.read(keys: keys)
    }

    private func advanceIfArmed() {
        guard let duration = pending else { return }
        pending = nil
        clock.advance(by: duration)
    }
}
