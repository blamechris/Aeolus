import os

/// `docs/SAFETY.md` § 5's examination gate: one § 5 examination or one level-6 step per fan at a
/// time ([ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md)'s #383 and A6 amendments).
///
/// ## What it closes
///
/// § 5 reads a fan, suspends, and then judges the reading against the record of what was
/// commanded. A level-6 step that lands inside that window, reported after the read or written
/// before it and reported after the judgement, makes an ordinary step read as a reclamation
/// ([#383](https://github.com/blamechris/Aeolus/issues/383)). § 5 excuses no reading for it. The
/// step and the examination are kept apart instead: under the gate the record at the read is
/// exactly level 6's last write that returned, so the comparison is exact in both orders. The same
/// exclusion keeps a client step out of § 5's re-assert (#381) and two engagements of one fan apart
/// ([#389](https://github.com/blamechris/Aeolus/issues/389)).
///
/// ## Who takes it, and who never does
///
/// § 5 takes it in `cycle()`, before the examination's stamp, and holds it to the examination's
/// last act. Level 6 takes it for each step, in `LeaseApplier`. Nothing else names this type:
/// `EngagementDriver` and `SafetyActorWriter` never take it, because § 5's re-engage runs through
/// them while § 5 holds it, and § 3's writes and every restore never take it, because a hand-back
/// held up by a holder is a hand-back that does not happen. `ExaminationGateRouteTests` holds that
/// by census and `ExaminationGateRestoreTests` by behaviour. Lock order is the gate before a
/// scheduler turn, never the reverse: the gate is taken before any read, and nothing that holds a
/// turn names it.
///
/// ## Not an actor
///
/// `leave(_:)` is synchronous so that the `defer` in the frame that entered can call it; an actor's
/// release would need an `await`, which a `defer` cannot make. The state sits behind an
/// `OSAllocatedUnfairLock`, as `PlaneWriteLedger` and `GateWaitMonitor` keep theirs, and holds only
/// Sendable values. The lock is held for one transition on `Lanes` and never across a resumption:
/// a continuation is resumed after the lock is let go.
///
/// ## Bounded, and decided once
///
/// Every wait is bounded by the gate's own constant for its party, never by a parameter. Whether a
/// wait was granted, ran out or was cancelled is decided once, under the lock, by whichever of
/// `leave(_:)`, the wait's timer and its cancellation handler reaches it first; the others find
/// it decided and do nothing. That bookkeeping is `Lanes`, a value type tested as a value.
final class FanExaminationGate: Sendable {

    /// How long § 5 waits for a fan's gate: `stepWait`, `lawfulHold` and `examinationMargin`, 32 s.
    ///
    /// The last step queued ahead of § 5 is granted within `stepWait` of § 5 arriving, or refused,
    /// and may then hold for `lawfulHold`. The margin covers that step's timer waking late, and the
    /// actor hops inside a hold. A wait that runs out means the contract was broken; or the helper
    /// is outside ADR 0012's design point, where G's own alarm can fire for a queue that is moving;
    /// or the wait spanned a system sleep, which this clock counts (ADR 0007; unverified here).
    /// Each costs a `.fault` and an examination without the gate, whose re-assert stands down and
    /// writes nothing away from automatic control; a false divergence there still marks the fan
    /// for a cycle and spends an attempt, and at the budget takes the terminal action.
    static let examinationWait: Duration = stepWait + lawfulHold + examinationMargin

    /// The longest a step that keeps A6's contract holds a fan's gate at ADR 0012's design point,
    /// 30 s: three scheduler turns, or `UnlockLimits.yieldBudget` and two. An engagement's first
    /// step and its one retry, then the driver's undo or the command; or its last poll, then its
    /// undo or its command. A re-apply holds one turn.
    ///
    /// A turn is its wait at the scheduler's gate plus several stamped round trips, and ADR 0012
    /// ends the helper for neither: D bounds one round trip, and G only logs. G exceeds the longest
    /// legal wait plus the longest write turn at the design point for every curated set
    /// (`WatchdogLimitsTests`), so G stands for a turn. This is the design point, not ADR 0012's
    /// enforcement: held to what ends the helper, a turn could last two § 3 gaps (ADR 0014's A6
    /// PR-2 amendment).
    static let lawfulHold: Duration = max(
        UnlockLimits.yieldBudget + WatchdogLimits.gateWaiterAlarm * 2,
        WatchdogLimits.gateWaiterAlarm * 3)

    /// What § 5's bound allows past `stepWait` and `lawfulHold`: 1 s, for two things no SMC
    /// deadline bounds. Timers wake late: a step granted at the instant its own wait ran out, the
    /// grant winning that tie, starts its hold later than the bound allows for. And the actor hops
    /// inside a hold are not round trips: level 6's registration with § 5, its entitlement's latch
    /// and lease-core questions, its ramp reset and its report; and the driver's entitlement around
    /// every step, its registration with § 3 and its after-check. Both are assumed and unmeasured;
    /// run 1 measures them (ADR 0014 D8). With no margin, that tie ran § 5's wait out as a lawful
    /// hold ended: one `.fault`, and an examination without the gate.
    static let examinationMargin: Duration = .seconds(1)

    /// How long level 6 waits for a fan's gate before its step is refused: 1 s.
    ///
    /// `UnlockLimits.yieldBudget` plus this stays under `HelperClientDeadlines.gatedVerb`'s 5 s,
    /// leaving room for the envelope read, the command write and its report. Provisional:
    /// [#325](https://github.com/blamechris/Aeolus/issues/325) measures the round trips it rests
    /// on.
    static let stepWait: Duration = .seconds(1)

    /// Who is waiting: § 5 or level 6. Only an examination's wait that runs out remembers the
    /// holder it ran out against.
    enum Party: Sendable, Hashable {
        case examination
        case step
    }

    /// How a wait ended.
    enum Outcome: Sendable, Hashable {
        /// The entrant holds the gate.
        case granted
        /// The wait reached its bound, or found the holder an earlier examination outwaited.
        case expired
        /// The entrant's task was cancelled while it waited. Not an expiry.
        case withdrawn
    }

    /// What an entrant has once its wait is over.
    ///
    /// Minted only here: the initialiser is `fileprivate`, so nothing outside this file can forge
    /// one, and `leave(_:)` releases only a pass that holds.
    struct Pass: Sendable, Equatable {
        /// The fan whose gate this is.
        let fan: Int
        /// Whether this pass holds the fan's gate. One that does not releases nothing.
        let isHeld: Bool
        /// Whether the wait ran out at its bound, or found the holder an earlier examination
        /// outwaited and did not wait at all. An examination past the bound writes nothing away
        /// from automatic control. A cancelled wait is not past it.
        let isPastTheBound: Bool
        fileprivate let ticket: UInt64

        fileprivate init(fan: Int, ticket: UInt64, outcome: Outcome) {
            self.fan = fan
            self.ticket = ticket
            isHeld = outcome == .granted
            isPastTheBound = outcome == .expired
        }
    }

    /// What a suspended entrant is resumed through.
    private typealias Resumption = CheckedContinuation<Outcome, Never>

    private struct State: Sendable {
        var lanes = Lanes()
        /// The continuation of every entrant that has suspended and is not yet decided.
        var parked: [UInt64: Resumption] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let clock: any MonotonicClock
    private let log: SafetyLog

    /// `clock` is the composition's, the one the lease core and the engagement driver measure on.
    init(clock: any MonotonicClock, log: SafetyLog = SafetyLog()) {
        self.clock = clock
        self.log = log
    }

    // MARK: - Entering and leaving

    /// § 5's entry, waiting at most `examinationWait`. Always returns a pass: one that holds, one
    /// past the bound, which examines without the gate and writes nothing away from automatic
    /// control, or one whose wait was cancelled, which also examines without it.
    func enterForExamination(fanAt fan: Int) async -> Pass {
        await enter(fanAt: fan, as: .examination, within: Self.examinationWait)
    }

    /// Level 6's entry, waiting at most `stepWait`.
    ///
    /// - Returns: a pass that holds, or `nil` past the bound or when the wait was cancelled: the
    ///   step is refused, and nothing writes without the gate.
    func enterForStep(fanAt fan: Int) async -> Pass? {
        let pass = await enter(fanAt: fan, as: .step, within: Self.stepWait)
        return pass.isHeld ? pass : nil
    }

    /// Releases `pass`, granting the fan's gate to its next waiter. Synchronous, so the `defer` in
    /// the frame that entered can call it, and idempotent: a pass that does not hold, one already
    /// left included, releases nothing, because `Lanes.leave(_:fanAt:)` releases only the ticket
    /// that holds, and a ticket that never held never will.
    func leave(_ pass: Pass) {
        let next = state.withLock { state -> Resumption? in
            guard let granted = state.lanes.leave(pass.ticket, fanAt: pass.fan) else { return nil }
            return state.parked.removeValue(forKey: granted)
        }
        next?.resume(returning: .granted)
    }

    // MARK: - Diagnostics

    /// How many entrants are waiting for `fan`'s gate now.
    func waiting(onFan fan: Int) -> Int { state.withLock { $0.lanes.waiting(onFan: fan) } }

    /// Whether `fan`'s gate is held now.
    func isHeld(fanAt fan: Int) -> Bool { state.withLock { $0.lanes.isHeld(fanAt: fan) } }

    /// How many entrants this gate has ever had, for tests and diagnostics.
    var entrants: UInt64 { state.withLock { $0.lanes.entrants } }

    /// Whether nothing is held, waiting, parked or decided and not yet taken.
    var isIdle: Bool { state.withLock { $0.lanes.isEmpty && $0.parked.isEmpty } }

    // MARK: - The wait

    private func enter(fanAt fan: Int, as party: Party, within bound: Duration) async -> Pass {
        switch state.withLock({ $0.lanes.arrive(fanAt: fan, as: party) }) {
        case .granted(let ticket):
            return Pass(fan: fan, ticket: ticket, outcome: .granted)
        case .outwaited(let ticket):
            return Pass(fan: fan, ticket: ticket, outcome: .expired)
        case .queued(let ticket):
            let outcome = await wait(ticket, fanAt: fan, within: bound)
            return Pass(fan: fan, ticket: ticket, outcome: outcome)
        }
    }

    /// Waits for `ticket`'s turn, its bound, or its task's cancellation, whichever reaches the
    /// lock first. The slot was reserved at arrival, so a decision made before the entrant
    /// suspends is kept for it rather than lost: an expiry or a cancellation that lands first is
    /// still the one decision.
    private func wait(_ ticket: UInt64, fanAt fan: Int, within bound: Duration) async -> Outcome {
        let deadline = clock.now + bound
        // The timer is cancelled however the wait ends. A clock that honours that ends its sleep
        // at once; one that does not wakes later to a ticket already decided, and does nothing.
        // So the two cancellation guards below are defence, not behaviour: removing either leaves
        // the wait decided as before, and no test claims them (ADR 0014's A6 PR-2 amendment).
        let timer = Task { [clock] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                // Cancelled, the timer ends without deciding. A clock that throws for any other
                // reason ends the wait as its bound would, rather than leaving it to a grant that
                // may never come.
                if !Task.isCancelled { self.decide(ticket, fanAt: fan, .expired) }
                return
            }
            guard !Task.isCancelled else { return }
            self.decide(ticket, fanAt: fan, .expired)
        }
        defer { timer.cancel() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: Resumption) in
                let decided = state.withLock { state -> Outcome? in
                    if let outcome = state.lanes.suspend(ticket, fanAt: fan) { return outcome }
                    state.parked[ticket] = continuation
                    return nil
                }
                if let decided { continuation.resume(returning: decided) }
            }
        } onCancel: {
            decide(ticket, fanAt: fan, .withdrawn)
        }
    }

    /// Ends `ticket`'s wait with `outcome`, unless it was decided already.
    ///
    /// The outwaited holder is logged before the parked examination is resumed, both outside the
    /// lock, so what that examination does next comes after the line, and so does anything that
    /// watches it end.
    private func decide(_ ticket: UInt64, fanAt fan: Int, _ outcome: Outcome) {
        let (withdrawal, parked) = state.withLock { state -> (Withdrawal, Resumption?) in
            let withdrawal = state.lanes.withdraw(ticket, fanAt: fan, because: outcome)
            return (withdrawal, withdrawal.resumes ? state.parked.removeValue(forKey: ticket) : nil)
        }
        if withdrawal.outwaitedHolder {
            log.examinationGateOutwaited(fan: fan, after: Self.examinationWait)
        }
        parked?.resume(returning: outcome)
    }
}

// MARK: - The bookkeeping, as a value

extension FanExaminationGate {

    /// What `Lanes.arrive(fanAt:as:)` did with an entrant.
    enum Arrival: Sendable, Hashable {
        /// The gate was free: the entrant holds it.
        case granted(UInt64)
        /// An examination found the holder an earlier examination outwaited, and does not wait.
        case outwaited(UInt64)
        /// The entrant waits, last in the fan's line.
        case queued(UInt64)
    }

    /// What `Lanes.withdraw(_:fanAt:because:)` did.
    struct Withdrawal: Sendable, Hashable {
        /// Whether the entrant had suspended and must be resumed with the outcome now. `false`
        /// when the outcome was kept for it to take when it suspends, or when it had been decided
        /// already and nothing changed.
        let resumes: Bool
        /// Whether this was an examination's wait running out, which records the holder.
        let outwaitedHolder: Bool
    }

    /// Every fan's line, and every outcome decided before its entrant suspended. A value: each
    /// transition is synchronous and closure-free, the gate makes each one under its lock, and a
    /// test drives every interleaving of grant, expiry and cancellation deterministically.
    ///
    /// Each fan has its own lane, created when the first entrant arrives and deleted when it is
    /// idle. A lane has at most one holder and serves its waiters first in, first out, whichever
    /// party each is. An entrant's place is taken at arrival, not when it suspends, so an outcome
    /// decided in between is kept in `decided` and taken by the one suspension that follows:
    /// every ticket queued is resumed or kept exactly once, and a withdrawal of a ticket that is
    /// neither queued nor kept changes nothing.
    struct Lanes: Sendable {
        private var issued: UInt64 = 0
        private var lanes: [Int: Lane] = [:]
        private var decided: [UInt64: Outcome] = [:]

        /// How many entrants have arrived, ever.
        var entrants: UInt64 { issued }

        /// Whether no lane exists and no outcome is kept.
        var isEmpty: Bool { lanes.isEmpty && decided.isEmpty }

        /// How many entrants are waiting for `fan`'s gate.
        func waiting(onFan fan: Int) -> Int { lanes[fan]?.waiters.count ?? 0 }

        /// Whether `fan`'s gate is held.
        func isHeld(fanAt fan: Int) -> Bool { lanes[fan]?.holder != nil }

        /// An entrant arrives for `fan`'s gate as `party`, and is given the next ticket.
        mutating func arrive(fanAt fan: Int, as party: Party) -> Arrival {
            issued &+= 1
            let ticket = issued
            var lane = lanes[fan] ?? Lane()
            defer { lanes[fan] = lane }
            guard let holder = lane.holder else {
                lane.holder = ticket
                return .granted(ticket)
            }
            if party == .examination, lane.outwaited == holder { return .outwaited(ticket) }
            lane.waiters.append(Waiter(ticket: ticket, party: party))
            return .queued(ticket)
        }

        /// The entrant holding `ticket` suspends.
        ///
        /// - Returns: the outcome decided before it suspended, which it takes now, or `nil` when
        ///   it is still waiting and is marked as suspended, to be resumed by the decision.
        mutating func suspend(_ ticket: UInt64, fanAt fan: Int) -> Outcome? {
            if let outcome = decided.removeValue(forKey: ticket) { return outcome }
            guard let at = lanes[fan]?.waiters.firstIndex(where: { $0.ticket == ticket }) else {
                // Unreachable: a queued ticket is queued or decided until it suspends. The answer
                // that writes nothing is the one given if it is ever reached.
                return .expired
            }
            lanes[fan]?.waiters[at].suspended = true
            return nil
        }

        /// The holder of `ticket` leaves `fan`'s gate, and the next waiter is granted it.
        ///
        /// - Returns: the ticket granted, when that entrant has suspended and must be resumed;
        ///   `nil` when nothing was granted, the ticket does not hold, or the grant was kept for an
        ///   entrant still to suspend.
        mutating func leave(_ ticket: UInt64, fanAt fan: Int) -> UInt64? {
            guard var lane = lanes[fan], lane.holder == ticket else { return nil }
            defer { lanes[fan] = lane.isIdle ? nil : lane }
            if lane.outwaited == ticket { lane.outwaited = nil }
            lane.holder = nil
            guard !lane.waiters.isEmpty else { return nil }
            let next = lane.waiters.removeFirst()
            lane.holder = next.ticket
            guard next.suspended else {
                decided[next.ticket] = .granted
                return nil
            }
            return next.ticket
        }

        /// Ends `ticket`'s wait for `fan`'s gate with `outcome`, `.expired` or `.withdrawn`, if it
        /// is still waiting. An examination's expiry records the holder it ran out against, so
        /// later examinations against that holder do not wait.
        mutating func withdraw(
            _ ticket: UInt64, fanAt fan: Int, because outcome: Outcome
        ) -> Withdrawal {
            guard var lane = lanes[fan],
                let at = lane.waiters.firstIndex(where: { $0.ticket == ticket })
            else { return Withdrawal(resumes: false, outwaitedHolder: false) }
            defer { lanes[fan] = lane }
            let waiter = lane.waiters.remove(at: at)
            let outwaits = outcome == .expired && waiter.party == .examination
            if outwaits { lane.outwaited = lane.holder }
            if !waiter.suspended { decided[ticket] = outcome }
            return Withdrawal(resumes: waiter.suspended, outwaitedHolder: outwaits)
        }
    }

    /// One fan's line: who holds its gate, who waits, and the holder an examination outwaited.
    private struct Lane: Sendable {
        var holder: UInt64?
        var waiters: [Waiter] = []
        /// The holder an examination's wait ran out against, until it leaves.
        var outwaited: UInt64?

        var isIdle: Bool { holder == nil && waiters.isEmpty }
    }

    /// One entrant waiting in a lane.
    private struct Waiter: Sendable {
        let ticket: UInt64
        let party: Party
        /// Whether its continuation is parked, so a decision resumes it rather than being kept.
        var suspended = false
    }
}
