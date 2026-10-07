import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import fanctl

/// The safe-state check: the one function `fanctl auto` ends on, and `fanctl set` will end on
/// too. Pure — a scripted reader and a virtual clock stand in for the helper and for time, so
/// the 10-second window is exercised without waiting for it.
@Suite("The safe-state check")
struct SafeStateTests {

    // MARK: - Fixtures

    static let captured = Date(timeIntervalSince1970: 1_790_000_000)

    static func fan(
        _ index: Int,
        mode: FanControlMode = .automatic,
        availability: ManualControlAvailability = .available
    ) -> FanState {
        FanState(
            index: index, actualRPM: .measured(1351), minimumRPM: .measured(1350),
            maximumRPM: .measured(5777), targetRPM: mode == .automatic ? nil : 3000, mode: mode,
            isReclaimedBySystem: false, manualControlAvailability: availability)
    }

    static func snapshot(_ fans: [FanState], lease: Lease? = nil) -> SystemSnapshot {
        SystemSnapshot(
            fans: fans, sensors: [], activeLease: lease, isThermalEmergencyActive: false,
            capturedAt: captured)
    }

    static let lease = Lease(
        holderDescription: "Aeolus.app 0.3.0", expiresAt: captured.addingTimeInterval(30))

    static let automatic = snapshot([fan(0), fan(1)])
    static let leasedManual = snapshot(
        [fan(0, mode: .manualFixed), fan(1)], lease: lease)

    // MARK: - What one snapshot says

    @Test("No lease and every fan automatic is the safe state")
    func automaticIsConfirmed() {
        #expect(SafeState.verdict(for: Self.automatic) == .automatic)
    }

    /// A machine with no fans has nothing to return. The helper reports no fan manual and no
    /// lease, and that is all this verdict states.
    @Test("No fans and no lease is the safe state too")
    func noFansIsConfirmed() {
        #expect(SafeState.verdict(for: Self.snapshot([])) == .automatic)
    }

    /// A lease is a claim on the fans, reported apart from them (`StatusCommand`). One that
    /// exists beside fans reading automatic is two facts, and neither cancels the other.
    ///
    /// **Mutation:** drop `&& snapshot.activeLease == nil` from `SafeState.verdict(for:)`.
    /// Run: red here.
    @Test("A lease beside fans that read automatic is not the safe state")
    func aLeaseIsNotTheSafeState() {
        let snapshot = Self.snapshot([Self.fan(0), Self.fan(1)], lease: Self.lease)
        #expect(SafeState.verdict(for: snapshot) == .notConfirmed)
    }

    @Test("A fan reading manual with no durable reason is not confirmed")
    func aManualFanIsNotConfirmed() {
        for availability: ManualControlAvailability in [
            .available, .unavailable(.releaseInProgress), .unavailable(.handbackUnconfirmed),
            .unavailable(.restoreToAutomaticUnconfirmed),
        ] {
            let snapshot = Self.snapshot([
                Self.fan(0, mode: .manualFixed, availability: availability)
            ])
            #expect(SafeState.verdict(for: snapshot) == .notConfirmed, "\(availability)")
        }
        let curve = Self.snapshot([Self.fan(0, mode: .manualCurve)])
        #expect(SafeState.verdict(for: curve) == .notConfirmed)
    }

    /// Exactly two reasons are durable. Every other reason has a transient reading or an
    /// unrelated one, and treating one as durable turns "wait" into "give up".
    ///
    /// **Mutation:** add `.handbackUnconfirmed` to the durable arm of `SafeState.isDurablyPinned`,
    /// or remove `.foreignManualControl` from it. Run: red on the reason named in the message.
    @Test("Only foreignManualControl and restoreToAutomaticFailed are durable")
    func durableReasons() {
        let reasons: [ManualControlAvailability.Reason] = [
            .writePathNotBuilt, .boundsImplausible, .reclaimedBySystem, .leaseHeldByAnotherClient,
            .selfRenewalNotBuilt, .releaseInProgress, .handbackUnconfirmed,
            .restoreToAutomaticUnconfirmed, .restoreToAutomaticFailed, .systemSleeping,
            .noThermalTelemetry, .supervisorBlind, .foreignManualControl, .unknown("fromTheFuture"),
        ]
        let durable: Set<ManualControlAvailability.Reason> = [
            .restoreToAutomaticFailed, .foreignManualControl,
        ]
        for reason in reasons {
            let snapshot = Self.snapshot([
                Self.fan(0, mode: .manualFixed, availability: .unavailable(reason))
            ])
            let expected: SafeState.Verdict =
                durable.contains(reason) ? .cannotReturn(fans: [0]) : .notConfirmed
            #expect(SafeState.verdict(for: snapshot) == expected, "\(reason.wireValue)")
        }
    }

    /// 9 outranks everything else: a durable pin is the one outcome retrying cannot change,
    /// and a lease beside it must not hide it behind a code that says "wait".
    ///
    /// **Mutation:** add `&& snapshot.activeLease == nil` to the pinned check in
    /// `SafeState.verdict(for:)`. Run: red.
    @Test("A durable pin outranks a lease")
    func aPinOutranksALease() {
        let snapshot = Self.snapshot(
            [
                Self.fan(0, mode: .manualFixed),
                Self.fan(1, mode: .manualFixed, availability: .unavailable(.foreignManualControl)),
            ], lease: Self.lease)
        #expect(SafeState.verdict(for: snapshot) == .cannotReturn(fans: [1]))
    }

    /// "Reads automatic" is the helper's own `mode`, as `docs/CLI.md` words exit 0. A fan the
    /// helper reports automatic is not "still manual", whatever else it says about it.
    @Test("A fan that reads automatic is never counted as pinned")
    func automaticModeIsNeverPinned() {
        let snapshot = Self.snapshot([
            Self.fan(0, mode: .automatic, availability: .unavailable(.foreignManualControl))
        ])
        #expect(SafeState.verdict(for: snapshot) == .automatic)
    }

    // MARK: - The window

    @Test("The window is ten seconds, polled every second, and a whole number of polls")
    func theWindowIsTenSecondsAtOneSecond() {
        #expect(SafeState.window == .seconds(10))
        #expect(SafeState.pollInterval == .seconds(1))
        #expect(
            SafeState.window.components.seconds % SafeState.pollInterval.components.seconds == 0)
        #expect(SafeState.window.components.attoseconds == 0)
    }

    /// Already safe on the first read: no wait at all.
    ///
    /// **Mutation:** delete the early `return` on `.automatic` in `SafeState.settle`. Run: red —
    /// it sleeps and reads eleven times.
    @Test("A first read that is safe returns at once, without sleeping")
    func settlesImmediately() async {
        let script = Script([.read(Self.automatic)])
        let time = VirtualTime()

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .automatic)
        #expect(settlement.polls == 1)
        #expect(settlement.interruption == nil)
        #expect(settlement.snapshot == Self.automatic)
        #expect(time.sleeps.isEmpty)
    }

    /// Polled every second, and stopped the moment it reads safe.
    ///
    /// **Mutation:** change `pollInterval` to `.seconds(2)`. Run: red on the sleeps.
    @Test("It polls once a second and stops at the first safe reading")
    func settlesAfterThreePolls() async {
        let script = Script([
            .read(Self.leasedManual), .read(Self.leasedManual), .read(Self.leasedManual),
            .read(Self.automatic),
        ])
        let time = VirtualTime()

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .automatic)
        #expect(settlement.polls == 4)
        #expect(settlement.snapshot == Self.automatic)
        #expect(time.sleeps == [.seconds(1), .seconds(1), .seconds(1)])
        #expect(script.reads == 4, "it read past the first safe snapshot")
    }

    /// Exactly the window: eleven reads at 0, 1, … 10 s, ten one-second sleeps, and then it
    /// stops. Both off-by-one neighbours fail here: a tenth-second short and a poll too many.
    ///
    /// **Mutation:** change `clock.now() >= deadline` to `clock.now() > deadline` in
    /// `SafeState.settle` (twelve reads), and separately change `window` to `.seconds(5)` or
    /// `.seconds(20)`. Run: red on the counts and on the elapsed time.
    @Test("A fan that never settles is read for exactly ten seconds, then reported")
    func neverSettles() async {
        let script = Script([.read(Self.leasedManual)], repeating: true)
        let time = VirtualTime()

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .notConfirmed)
        #expect(settlement.polls == 11)
        #expect(script.reads == 11)
        #expect(time.sleeps == Array(repeating: .seconds(1), count: 10))
        #expect(time.elapsed == .seconds(10))
        #expect(settlement.snapshot == Self.leasedManual)
        #expect(settlement.interruption == nil)
    }

    /// The pin is classified from the last reading, at the end — a transient reason that
    /// clears to a durable one is judged by what it ended as.
    @Test("The verdict at the end of the window is the last reading's")
    func theLastReadingDecides() async {
        let pinned = Self.snapshot([
            Self.fan(0, mode: .manualFixed, availability: .unavailable(.restoreToAutomaticFailed))
        ])
        let script = Script([.read(Self.leasedManual), .read(pinned)], repeating: true)
        let time = VirtualTime()

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .cannotReturn(fans: [0]))
        #expect(settlement.snapshot == pinned)
    }

    // MARK: - When the helper stops answering

    /// A read that fails ends the wait with what was last read, and never reports safe: the
    /// helper stopped answering, and that is not an observation of automatic.
    ///
    /// **Mutation:** return `.automatic` from the `catch` around the read in
    /// `SafeState.settle`. Run: red on the verdict.
    @Test("A read that fails stops the wait, keeps the last snapshot, and is never safe")
    func aFailedReadIsAnInterruption() async {
        let script = Script([
            .read(Self.leasedManual), .read(Self.leasedManual), .fail(HelperClientTestError.gone),
        ])
        let time = VirtualTime()

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .notConfirmed)
        #expect(settlement.polls == 2)
        #expect(settlement.snapshot == Self.leasedManual)
        #expect(settlement.interruption as? HelperClientTestError == .gone)
        #expect(time.sleeps.count == 2, "it kept polling after the helper stopped answering")
    }

    @Test("A failure on the very first read leaves no snapshot to show")
    func aFirstReadFailureHasNoSnapshot() async {
        let script = Script([.fail(HelperClientTestError.gone)])
        let settlement = await SafeState.settle(reading: script.next, clock: VirtualTime().clock)

        #expect(settlement.verdict == .notConfirmed)
        #expect(settlement.polls == 0)
        #expect(settlement.snapshot == nil)
        #expect(settlement.interruption != nil)
    }

    /// A cancelled wait is not a settled one.
    ///
    /// **Mutation:** `try?` the `clock.sleep` call in `SafeState.settle`. Run: red — the
    /// cancelled sleep is ignored and the loop runs on.
    @Test("A wait that is cancelled stops, and is never safe")
    func aCancelledSleepIsAnInterruption() async {
        let script = Script([.read(Self.leasedManual)], repeating: true)
        let time = VirtualTime(failingSleepWith: CancellationError())

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .notConfirmed)
        #expect(settlement.interruption is CancellationError)
        #expect(script.reads == 1)
    }

    // MARK: - The production clock

    /// The shipping clock is monotonic and really waits; the virtual one above proves nothing
    /// about either.
    ///
    /// **A lower bound only.** A sleep cannot return early, so "at least this long" holds on
    /// any machine; "no more than" does not. This test once also asserted an upper bound of
    /// five seconds and failed on CI at 7.4 s, because 60 ms of sleep is queued behind
    /// everything else the runner is doing — the wall-clock-upper-bound defect of
    /// [#97](https://github.com/blamechris/Aeolus/issues/97) and
    /// [#250](https://github.com/blamechris/Aeolus/issues/250). What the upper bound would have
    /// caught, a `sleep` that waits forever, hangs this test instead of passing it.
    @Test("The production clock waits for the duration it is given, on ContinuousClock")
    func productionClockWaits() async throws {
        let clock = SettleClock.production
        let before = clock.now()
        try await clock.sleep(.milliseconds(60))
        let elapsed = clock.now() - before
        #expect(elapsed >= .milliseconds(55), "slept \(elapsed)")
    }
}

// MARK: - Doubles

/// Why a scripted read failed.
enum HelperClientTestError: Error, Equatable {
    case gone
    case runaway
    case exhausted
}

/// A reader that answers from a list. Not an actor and not async-shared: `settle` calls it
/// from one task, in order.
final class Script: Sendable {
    enum Step: Sendable {
        case read(SystemSnapshot)
        case fail(any Error)
    }

    /// A loop that never ends under a virtual clock would hang the suite instead of failing
    /// it, so a script that is read this many times fails instead of answering.
    static let runaway = 100

    private let steps: [Step]
    private let repeatsLast: Bool
    private let position = OSAllocatedUnfairLock(initialState: 0)

    init(_ steps: [Step], repeating: Bool = false) {
        self.steps = steps
        self.repeatsLast = repeating
    }

    var reads: Int { position.withLock { $0 } }

    @Sendable func next() async throws -> SystemSnapshot {
        let index = position.withLock { value -> Int in
            defer { value += 1 }
            return value
        }
        if index >= Self.runaway { throw HelperClientTestError.runaway }
        // Past the end of a script that does not repeat, a loop that should have stopped is
        // read as a failure the assertions can name, not as an out-of-range trap that takes
        // the rest of the suite down with it.
        if !repeatsLast && index >= steps.count { throw HelperClientTestError.exhausted }
        let step = steps[repeatsLast ? min(index, steps.count - 1) : index]
        switch step {
        case .read(let snapshot): return snapshot
        case .fail(let error): throw error
        }
    }
}

/// Time that moves only when something sleeps, by exactly as much as it slept — so the whole
/// window is walked in microseconds, and a loop that stops at the wrong moment shows up as a
/// wrong count rather than a slow test.
final class VirtualTime: Sendable {
    private struct State {
        var elapsed = Duration.zero
        var sleeps: [Duration] = []
    }

    private let origin = ContinuousClock.now
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let failure: (any Error)?

    init(failingSleepWith failure: (any Error)? = nil) {
        self.failure = failure
    }

    var elapsed: Duration { state.withLock { $0.elapsed } }
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    var clock: SettleClock {
        SettleClock(
            now: { [origin, state] in origin + state.withLock { $0.elapsed } },
            sleep: { [state, failure] duration in
                if let failure { throw failure }
                state.withLock {
                    $0.elapsed += duration
                    $0.sleeps.append(duration)
                }
            })
    }
}
