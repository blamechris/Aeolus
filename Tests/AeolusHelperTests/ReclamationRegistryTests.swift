import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// `ReclamationWatchdog.Registry` and `HeldFan.judge(_:)` as values: no actor, no plane, no
/// clock, and nothing awaited.
///
/// [#128](https://github.com/blamechris/Aeolus/issues/128)'s third pass moved every synchronous
/// decision § 5 makes over its registry out of the actor, so each can be asserted where it is
/// stated, against a value a test constructs directly. The actor suites still drive the same
/// rules through `cycle()` and the notices, with every interleaving they script; this suite is
/// what says which half of a failure is the bookkeeping and which the orchestration. #366's
/// episode and its given-up lease are tested in this suite too, in
/// `ReclamationRegistryEpisodeTests.swift`, and #368's token is meant to be when it lands.
///
/// Every assertion names the mutation it kills, and each was run.
@Suite("§ 5's registry and per-reading judgement, as values")
struct ReclamationRegistryTests {

    // Internal rather than `private`, for `ReclamationRegistryEpisodeTests.swift` (#366).
    typealias Watchdog = ReclamationWatchdog<ScriptedControlPlane>
    typealias Registry = Watchdog.Registry

    let lease = UUID()
    let other = UUID()

    /// A cycle whose `F0Tg` did not read: divergence on any fan, graced on an uncommanded one.
    let unreadable = FanControlState(
        index: 0, mode: .manual, target: .unreadable(reason: "F0Tg: no answer"),
        actualRPM: .rpm(2_400))

    /// A cycle that converges on both signals against 2,400 RPM commanded, or nothing.
    let converged = FanControlState(
        index: 0, mode: .manual, target: .rpm(2_400), actualRPM: .rpm(2_400))

    /// A cycle whose target reads back the 2,400 commanded while the fan turns at 1,000.
    let short = FanControlState(
        index: 0, mode: .manual, target: .rpm(2_400), actualRPM: .rpm(1_000))

    let target = CommandedTarget(fanIndex: 0, rpm: 2_400)

    /// A registry holding fan 0, and fans 1 and 2 where asked, under `lease`.
    func holding(_ fans: [Int] = [0], under lease: UUID) -> Registry {
        var registry = Registry()
        for fan in fans {
            _ = registry.register(
                lease, fanAt: fan, live: true, since: registry.generation(ofFan: fan))
        }
        return registry
    }

    // MARK: - Registration

    /// **Mutation:** drop `registrations[index, default: 0] == generation` from `register`'s
    /// guard. Run: red.
    @Test("A registration whose fan was released while it asked is refused, and records nothing")
    func aMovedGenerationIsRefused() {
        var registry = Registry()
        let generation = registry.generation(ofFan: 0)
        _ = registry.release(fanAt: 0)

        let registration = registry.register(lease, fanAt: 0, live: true, since: generation)
        #expect(registration == .refused)
        #expect(registry.fans.isEmpty)
        #expect(registry.generation(ofFan: 0) == generation + 1, "a refusal moved the generation")
    }

    /// **Mutation:** drop `live` from `register`'s guard. Run: red.
    @Test("A registration under a lease that is not live is refused")
    func aLeaseThatIsNotLiveIsRefused() {
        var registry = Registry()

        let registration = registry.register(lease, fanAt: 0, live: false, since: 0)
        #expect(registration == .refused)
        #expect(registry.fans.isEmpty)
    }

    /// The terminal action's entry refuses the lease it gives the fan up for, and only that one:
    /// a newer lease's engagement is what holds the fan then.
    ///
    /// **Mutation:** drop `givenUp[index] != lease` from `register`'s guard. Run: red.
    @Test("A registration under the lease being given up is refused while it is")
    func theLeaseBeingGivenUpIsRefused() {
        var registry = holding(under: lease)
        let entered = registry.beginFinalising(fanAt: 0, for: lease)
        let generation = registry.generation(ofFan: 0)

        let sameLease = registry.register(lease, fanAt: 0, live: true, since: generation)
        let newerLease = registry.register(other, fanAt: 0, live: true, since: generation)
        #expect(entered)
        #expect(sameLease == .refused)
        #expect(newerLease == .accepted(replacedEndedLease: true, mayClearTheMark: true))
    }

    /// **Mutation:** make `register` report `replacedEndedLease: false` always. Run: red.
    @Test("Replacing another lease's record is reported, and nothing else is")
    func replacingAnEndedLeasesRecordIsReported() {
        var registry = Registry()

        let first = registry.register(lease, fanAt: 0, live: true, since: 0)
        let again = registry.register(lease, fanAt: 0, live: true, since: 1)
        let replacing = registry.register(other, fanAt: 0, live: true, since: 2)
        #expect(first == .accepted(replacedEndedLease: false, mayClearTheMark: true))
        #expect(again == .accepted(replacedEndedLease: false, mayClearTheMark: true))
        #expect(replacing == .accepted(replacedEndedLease: true, mayClearTheMark: true))
        #expect(registry.isHeld(0, under: other))
        #expect(registry.isHeld(0, under: lease) == false, "presence was taken for identity")
    }

    /// #180's rule: registering a fan again under the same lease rearms nothing.
    ///
    /// **Mutation:** make `HeldFan.registering(_:over:)` return `HeldFan(lease: lease)` always.
    /// Run: red.
    @Test("A same-lease re-registration keeps the record's counters")
    func aSameLeaseReRegistrationKeepsItsCounters() throws {
        var registry = holding(under: lease)
        let judged = registry.judge(unreadable, ofFan: 0)
        let failures = registry.recordReadFailure(ofFan: 0)
        registry.spendReassertAttempt(2, ofFan: 0)
        _ = registry.command(target, ofFan: 0)

        let generation = registry.generation(ofFan: 0)
        let accepted = registry.register(lease, fanAt: 0, live: true, since: generation)
        let record = try #require(registry.record(ofFan: 0))

        #expect(judged != nil)
        #expect(failures == 1)
        #expect(accepted == .accepted(replacedEndedLease: false, mayClearTheMark: true))
        #expect(record.commanded == target)
        #expect(record.uncommandedDivergentCycles == 1)
        #expect(record.consecutiveReadFailures == 1)
        #expect(record.reassertAttempts == 2)
    }

    // MARK: - Release and the terminal action

    /// **Mutation (a):** delete the generation bump from `release(fanAt:)`. Run: red.
    /// **Mutation (b):** make `release(fanAt:)` return `true`. Run: red.
    @Test("A release forgets the fan, moves its generation, and allows a clear only when it may")
    func aReleaseMovesTheGenerationAndAnswersTheMark() {
        var registry = holding(under: lease)
        let generation = registry.generation(ofFan: 0)

        let ordinary = registry.release(fanAt: 0)
        #expect(ordinary)
        #expect(registry.fans.isEmpty)
        #expect(registry.generation(ofFan: 0) == generation + 1)

        // While the terminal action gives the fan up, its release notice keeps the mark (#346),
        // and once it has, the next release clears again.
        registry = holding(under: lease)
        let entered = registry.beginFinalising(fanAt: 0, for: lease)
        let duringTheHandBack = registry.release(fanAt: 0)
        registry.endFinalising(fanAt: 0)
        let afterwards = registry.release(fanAt: 0)
        #expect(entered)
        #expect(duringTheHandBack == false, "a release erased the kept mark")
        #expect(afterwards)
    }

    /// **Mutation (a):** drop the other-lease check from `beginFinalising(fanAt:for:)`. Run:
    /// red. **Mutation (b):** delete its generation bump. Run: red.
    @Test("The terminal action's entry refuses another lease's record, and moves the generation")
    func theTerminalEntryChecksIdentityAndMovesTheGeneration() {
        var registry = holding(under: other)
        let generation = registry.generation(ofFan: 0)

        let refusedEntry = registry.beginFinalising(fanAt: 0, for: lease)
        #expect(refusedEntry == false)
        #expect(registry.generation(ofFan: 0) == generation, "a refused entry moved the mark")
        let unmarked = registry.register(lease, fanAt: 0, live: true, since: generation)
        #expect(
            unmarked == .accepted(replacedEndedLease: true, mayClearTheMark: true),
            "a refused entry left the lease it named marked as being given up")

        let before = registry.generation(ofFan: 0)
        let entered = registry.beginFinalising(fanAt: 0, for: lease)
        let inFlight = registry.register(other, fanAt: 0, live: true, since: before)
        #expect(entered)
        #expect(registry.generation(ofFan: 0) == before + 1)
        #expect(
            inFlight == .refused,
            "a registration already in flight resumed accepted after the entry (C3)")
    }

    /// **Mutation:** replace `held = held.filter { $0.value.lease != lease }` in
    /// `dropLease(_:sparing:)` with `held[index] = nil`. Run: red.
    @Test("Dropping a lease returns its other fans, sorted, and removes every record of it")
    func droppingALeaseRemovesEveryRecordOfIt() {
        var registry = holding([2, 0, 1], under: lease)
        _ = registry.register(other, fanAt: 3, live: true, since: 0)

        let siblings = registry.dropLease(lease, sparing: 0)
        #expect(siblings == [1, 2])
        #expect(registry.fans == [3])
    }

    /// **Mutation:** drop the identity check from `forget(fanAt:ifUnder:)`. Run: red.
    @Test("Forgetting a fan for one lease leaves another lease's record alone")
    func forgettingChecksIdentity() {
        var registry = holding(under: other)

        let forAnotherLease = registry.forget(fanAt: 0, ifUnder: lease)
        #expect(forAnotherLease == false)
        #expect(registry.isHeld(0, under: other))
        let forItsOwn = registry.forget(fanAt: 0, ifUnder: other)
        #expect(forItsOwn)
        #expect(registry.fans.isEmpty)
    }

    // MARK: - One readable cycle

    /// **Mutation:** add `uncommandedDivergentCycles = 0` to `HeldFan.judge(_:)`'s converged
    /// branch. Run: red. **Mutation:** delete its `reassertAttempts = 0`. Run: red.
    @Test("A converged cycle does not refill the grace, and resets the dwell and the attempts")
    func convergenceNeverRefillsTheGrace() {
        var fan = Watchdog.HeldFan(lease: lease)
        let graced = fan.judge(unreadable)
        fan.actualDwellCycles = 3
        fan.reassertAttempts = 2

        let judged = fan.judge(converged)
        #expect(graced != .converged)
        #expect(judged == .converged)
        #expect(fan.uncommandedDivergentCycles == 1, "a converged cycle refilled the grace")
        #expect(fan.actualDwellCycles == 0)
        #expect(fan.reassertAttempts == 0)
    }

    /// Driven to the budget, and the expectation derived per cycle, so it holds at every value of
    /// `blindCyclesBeforeDivergence`.
    ///
    /// **Mutation (a):** delete `judge`'s `guard uncommandedDivergentCycles <
    /// ReclamationLimits.blindCyclesBeforeDivergence`. Run: red. **Mutation (b):** report
    /// `firstCycle: true` on every graced cycle. Run: red.
    @Test("The grace says so on its first cycle, and runs out on its budget")
    func theGraceRunsOutOnItsBudget() {
        var fan = Watchdog.HeldFan(lease: lease)
        let divergence = ReclamationDivergence.targetUnreadable(reason: "F0Tg: no answer")

        for cycle in 1...ReclamationLimits.blindCyclesBeforeDivergence {
            let expected: Watchdog.Judgement =
                cycle < ReclamationLimits.blindCyclesBeforeDivergence
                ? .graced(divergence, firstCycle: cycle == 1) : .diverged(divergence)
            let judged = fan.judge(unreadable)
            #expect(judged == expected, "cycle \(cycle)")
        }
    }

    /// **Mutation:** delete `actualDwellCycles = 0` from `HeldFan.command(_:)`. Run: red.
    @Test("The secondary signal counts its dwell, and a fresh command starts it again")
    func aFreshCommandRestartsTheDwell() {
        var fan = Watchdog.HeldFan(lease: lease)
        _ = fan.command(target)

        let first = fan.judge(short)
        let second = fan.judge(short)
        _ = fan.command(target)
        let afterTheCommand = fan.judge(short)
        #expect(first == .short(actual: 1_000, commanded: 2_400, dwell: 1))
        #expect(second == .short(actual: 1_000, commanded: 2_400, dwell: 2))
        #expect(afterTheCommand == .short(actual: 1_000, commanded: 2_400, dwell: 1))
    }

    /// **Mutation:** delete `actualDwellCycles = 0` at the top of `HeldFan.judge(_:)`'s primary
    /// branch. Run: red.
    @Test("A primary divergence restarts the secondary signal's dwell")
    func aPrimaryDivergenceRestartsTheDwell() {
        var fan = Watchdog.HeldFan(lease: lease)
        _ = fan.command(target)

        _ = fan.judge(short)
        _ = fan.judge(short)
        let diverged = fan.judge(unreadable)
        let afterwards = fan.judge(short)
        #expect(diverged == .diverged(.targetUnreadable(reason: "F0Tg: no answer")))
        #expect(afterwards == .short(actual: 1_000, commanded: 2_400, dwell: 1))
    }

    // MARK: - Behaviour `main` never asserted

    /// The other half of `cycleCouldNotSee`'s count: without it, blind cycles that are not
    /// consecutive add up to the escalation. `ReclamationWatchdogTests`'
    /// `alternatingBlindnessNeverEscalates` drives the same rule through the actor.
    ///
    /// **Mutation:** make `Registry.resetReadFailures(ofFan:)` do nothing. Run: red.
    @Test("A readable cycle after blind ones zeroes the read-failure count")
    func resettingReadFailuresZeroesTheCount() throws {
        var registry = holding(under: lease)
        _ = registry.recordReadFailure(ofFan: 0)
        let failures = registry.recordReadFailure(ofFan: 0)
        registry.resetReadFailures(ofFan: 0)
        let record = try #require(registry.record(ofFan: 0))

        #expect(failures == 2)
        #expect(record.consecutiveReadFailures == 0)
    }

    /// `commanded` only. The re-assert's write never reset the dwell, before #128 or since: the
    /// primary branch that reaches the re-assert has already zeroed it. Resetting it here as well
    /// would be a behaviour change, so the test pins the dwell where it stood.
    ///
    /// **Mutation (a):** make `Registry.recordReassertedTarget(_:decidedOn:ofFan:)` return `true`
    /// having recorded nothing. **(b):** make it `return held[index]?.command(target) ?? true`,
    /// which resets the dwell too. Run: red on each. Recorded over the target it was decided on,
    /// as `reassert` records it (#381).
    @Test("A re-asserted target is recorded, and leaves the dwell where it stands")
    func aReassertedTargetIsRecordedAndLeavesTheDwell() throws {
        var registry = holding(under: lease)
        _ = registry.command(target, ofFan: 0)
        _ = registry.judge(short, ofFan: 0)
        _ = registry.judge(short, ofFan: 0)
        let written = CommandedTarget(fanIndex: 0, rpm: 2_200)

        _ = registry.recordReassertedTarget(written, decidedOn: target, ofFan: 0)
        let record = try #require(registry.record(ofFan: 0))
        #expect(record.commanded == written)
        #expect(record.actualDwellCycles == 2)
    }

    /// **Mutation:** in `HeldFan.refundReassertAttempt()`, replace `max(0, reassertAttempts - 1)`
    /// with `reassertAttempts - 1`. Run: red.
    @Test("A refund gives back one attempt, and never goes below zero")
    func aRefundFloorsAtZero() throws {
        var registry = holding(under: lease)
        registry.spendReassertAttempt(1, ofFan: 0)

        registry.refundReassertAttempt(ofFan: 0)
        let afterOne = try #require(registry.record(ofFan: 0)).reassertAttempts
        registry.refundReassertAttempt(ofFan: 0)
        let afterTwo = try #require(registry.record(ofFan: 0)).reassertAttempts
        #expect(afterOne == 0)
        #expect(afterTwo == 0, "a refund below zero hands the fan an extra attempt")
    }

    /// Twelve fans registered out of order. The assertion holds for a sorted answer whatever
    /// order the dictionary's keys come out in, and that order is seeded per process — so an
    /// unsorted answer matches with probability 1 in 12!, and fails in practice on every run.
    /// With two or three fans it could pass by chance.
    ///
    /// **Mutation:** make `fansInOrder` return `Array(held.keys)`. Run: red.
    @Test("The fans are examined in index order, whatever order they were registered in")
    func theFansAreInIndexOrder() {
        let registrationOrder = [7, 2, 11, 0, 9, 4, 1, 10, 5, 3, 8, 6]
        let registry = holding(registrationOrder, under: lease)

        #expect(registry.fansInOrder == Array(0...11))
        #expect(registry.fans == Set(registrationOrder))
    }
}
