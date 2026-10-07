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

    @Test("A fan reading manual, with no reason or a pending one, is not confirmed")
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

    // MARK: - What a fan's availability makes of its mode

    typealias Reason = ManualControlAvailability.Reason

    /// **Every reason, in the class it was ruled into.** Written out as three literals rather
    /// than derived from the code under test, so that moving a reason between classes in
    /// `SafeState.clearance(of:)` is a disagreement with this table and not a self-consistent
    /// edit. `everyReasonIsClassifiedOnce` holds the table to the vocabulary.
    ///
    /// - `durable`: waiting will not change it → 9, whatever the mode reads.
    /// - `pending`: the helper has not established the fan's mode, or a restore is outstanding
    ///   → 8, whatever the mode reads. `supervisorBlind` is here and not above: a blind fan's
    ///   state is unknown, not manual.
    /// - `silent`: about manual control being granted, not about the fan → the mode decides.
    static let durable: [Reason] = [.foreignManualControl, .restoreToAutomaticFailed]
    static let pending: [Reason] = [
        .releaseInProgress, .handbackUnconfirmed, .restoreToAutomaticUnconfirmed, .supervisorBlind,
        .systemSleeping, .unknown("fromTheFuture"),
    ]
    static let silent: [Reason] = [
        .writePathNotBuilt, .boundsImplausible, .leaseHeldByAnotherClient, .selfRenewalNotBuilt,
        .noThermalTelemetry, .reclaimedBySystem,
    ]

    /// The modes a fan can read.
    static let modes: [FanControlMode] = [.automatic, .manualFixed, .manualCurve]

    private static func one(_ reason: Reason?, reading mode: FanControlMode) -> SystemSnapshot {
        snapshot([fan(0, mode: mode, availability: reason.map { .unavailable($0) } ?? .available)])
    }

    @Test("The three classes cover all fourteen reasons, each exactly once")
    func everyReasonIsClassifiedOnce() {
        let all = Self.durable + Self.pending + Self.silent
        #expect(all.count == 14)
        #expect(Set(all).count == 14)
        // `Reason.init(wireValue:)` is total, so a reason the vocabulary grows is not in this
        // table until someone puts it here; the exhaustive switch in `clearance(of:)` is what
        // stops the code compiling until it has been decided.
        let known: Set<String> = [
            "writePathNotBuilt", "boundsImplausible", "reclaimedBySystem",
            "leaseHeldByAnotherClient", "selfRenewalNotBuilt", "releaseInProgress",
            "handbackUnconfirmed", "restoreToAutomaticUnconfirmed", "restoreToAutomaticFailed",
            "systemSleeping", "noThermalTelemetry", "supervisorBlind", "foreignManualControl",
            "fromTheFuture",
        ]
        #expect(Set(all.map(\.wireValue)) == known)
    }

    /// **Mutation:** move any reason out of `durable` in `SafeState.clearance(of:)` — for each of
    /// the two, into `pending` and into `silent`. Run: red, naming the reason and the mode.
    @Test("A durable reason is 9 whatever mode the fan reads")
    func durableReasonsAreNineWhateverTheModeReads() {
        for reason in Self.durable {
            for mode in Self.modes {
                #expect(
                    SafeState.verdict(for: Self.one(reason, reading: mode))
                        == .cannotReturn(fans: [0]),
                    "\(reason.wireValue) / \(mode)")
            }
        }
    }

    /// **Mutation:** move any reason out of `pending` — each of the six, into `durable` and into
    /// `silent`. Run: red, naming the reason and the mode.
    @Test("A pending reason is 8 whatever mode the fan reads")
    func pendingReasonsAreEightWhateverTheModeReads() {
        for reason in Self.pending {
            for mode in Self.modes {
                #expect(
                    SafeState.verdict(for: Self.one(reason, reading: mode)) == .notConfirmed,
                    "\(reason.wireValue) / \(mode)")
            }
        }
    }

    /// **Mutation:** move any reason out of `silent` — each of the six, into `durable` and into
    /// `pending`. Run: red, naming the reason and the mode.
    @Test("A silent reason lets the mode decide")
    func silentReasonsLetTheModeDecide() {
        for reason in Self.silent {
            #expect(
                SafeState.verdict(for: Self.one(reason, reading: .automatic)) == .automatic,
                "\(reason.wireValue) / automatic")
            for mode in [FanControlMode.manualFixed, .manualCurve] {
                #expect(
                    SafeState.verdict(for: Self.one(reason, reading: mode)) == .notConfirmed,
                    "\(reason.wireValue) / \(mode)")
            }
        }
    }

    @Test("A fan with no reason beside it lets the mode decide")
    func anAvailableFanLetsTheModeDecide() {
        #expect(SafeState.verdict(for: Self.one(nil, reading: .automatic)) == .automatic)
        #expect(SafeState.verdict(for: Self.one(nil, reading: .manualFixed)) == .notConfirmed)
        #expect(SafeState.verdict(for: Self.one(nil, reading: .manualCurve)) == .notConfirmed)
    }

    /// **Today's real helper:** every fan reports `writePathNotBuilt`, and none of them is held.
    /// `fanctl auto` against it must still be able to say the helper reports the safe state.
    ///
    /// **Mutation:** move `.writePathNotBuilt` into `pending` or `durable`. Run: red.
    @Test("writePathNotBuilt on every fan, all automatic, no lease, is the safe state")
    func theShippingHelperIsTheSafeState() {
        let snapshot = Self.snapshot([
            Self.fan(0, availability: .unavailable(.writePathNotBuilt)),
            Self.fan(1, availability: .unavailable(.writePathNotBuilt)),
        ])
        #expect(SafeState.verdict(for: snapshot) == .automatic)
    }

    /// The helper reports an unreadable `F<n>Md` as `automatic` (#178), and on Intel the register
    /// does not exist. A durable reason beside that mode is a fan the helper has not cleared,
    /// and reading the mode alone said exit 0 with no restore sent.
    ///
    /// **Mutation:** compute `pinned` in `SafeState.verdict(for:)` over the fans whose mode is not
    /// automatic only. Run: red.
    @Test("A durable reason beside a mode of automatic is not the safe state")
    func aDurableReasonCountsWhateverTheModeReads() {
        let snapshot = Self.snapshot([
            Self.fan(0, mode: .automatic, availability: .unavailable(.foreignManualControl)),
            Self.fan(1),
        ])
        #expect(SafeState.verdict(for: snapshot) == .cannotReturn(fans: [0]))
    }

    /// One cleared fan does not clear another.
    ///
    /// **Mutation:** in `SafeState.verdict(for:)`, replace `allSatisfy(isCleared)` with
    /// `contains(where: isCleared)`, or drop the `clearance` test from `isCleared`. Run: red.
    @Test("A fan the helper has not cleared keeps the rest from being the safe state")
    func oneUnclearedFanIsEnough() {
        let blind = Self.snapshot([
            Self.fan(0), Self.fan(1, availability: .unavailable(.supervisorBlind)),
        ])
        #expect(SafeState.verdict(for: blind) == .notConfirmed)
        let withLease = Self.snapshot(
            [Self.fan(0), Self.fan(1, availability: .unavailable(.handbackUnconfirmed))],
            lease: Self.lease)
        #expect(SafeState.verdict(for: withLease) == .notConfirmed)
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
        let automaticPin = Self.snapshot(
            [Self.fan(0, availability: .unavailable(.restoreToAutomaticFailed))],
            lease: Self.lease)
        #expect(SafeState.verdict(for: automaticPin) == .cannotReturn(fans: [0]))
    }

    /// **Order.** A pending reason and a durable one: 9 wins, and names only the durable fan.
    @Test("9 names only the durable fans, beside pending ones")
    func nineNamesOnlyTheDurableFans() {
        let snapshot = Self.snapshot([
            Self.fan(0, availability: .unavailable(.supervisorBlind)),
            Self.fan(1, availability: .unavailable(.foreignManualControl)),
            Self.fan(2, mode: .manualFixed, availability: .unavailable(.releaseInProgress)),
        ])
        #expect(SafeState.verdict(for: snapshot) == .cannotReturn(fans: [1]))
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
