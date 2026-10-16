import Testing

@testable import AeolusHelper

/// The examination gate's bookkeeping as a value: every interleaving of a grant, an expiry and a
/// cancellation, driven deterministically, with no clock and no task.
///
/// `FanExaminationGate` makes each of these transitions under its lock and resumes whatever a
/// transition names after letting the lock go, so what is decided, and that it is decided once, is
/// all here. `FanExaminationGateTests` drives the same rules through the gate's waits.
@Suite("The examination gate's lanes, as values")
struct FanExaminationGateLanesTests {

    typealias Lanes = FanExaminationGate.Lanes

    /// Arrives as `party` and returns the ticket, whatever the arrival was.
    private static func arrive(
        _ lanes: inout Lanes, fan: Int = 0, as party: FanExaminationGate.Party = .step
    ) -> UInt64 {
        switch lanes.arrive(fanAt: fan, as: party) {
        case .granted(let ticket), .outwaited(let ticket), .queued(let ticket): return ticket
        }
    }

    /// Arrives, expecting to wait, and suspends.
    private static func queueAndSuspend(
        _ lanes: inout Lanes, fan: Int = 0, as party: FanExaminationGate.Party = .step,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> UInt64 {
        let arrival = lanes.arrive(fanAt: fan, as: party)
        guard case .queued(let ticket) = arrival else {
            Issue.record("\(arrival) did not wait", sourceLocation: sourceLocation)
            return 0
        }
        #expect(lanes.suspend(ticket, fanAt: fan) == nil, sourceLocation: sourceLocation)
        return ticket
    }

    /// **Mutation:** in `Lanes.arrive(fanAt:as:)`, grant when the lane has no waiters rather than
    /// when it has no holder. Run: red on the second arrival.
    @Test("One holder per fan, and each fan's gate is its own")
    func oneHolderPerFan() {
        var lanes = Lanes()
        #expect(lanes.arrive(fanAt: 0, as: .step) == .granted(1))
        #expect(lanes.arrive(fanAt: 0, as: .examination) == .queued(2), "two held fan 0 at once")
        #expect(lanes.arrive(fanAt: 1, as: .examination) == .granted(3), "fan 1 waited on fan 0")
        #expect(lanes.waiting(onFan: 0) == 1)
        #expect(lanes.waiting(onFan: 1) == 0)
    }

    /// Waiters are served in the order they arrived, whichever party each is.
    ///
    /// **Mutation:** in `Lanes.leave(_:fanAt:)`, serve the newest waiter —
    /// `lane.waiters.removeLast()`. Run: red on every grant after the first.
    @Test("Waiters are granted first in, first out, across both parties")
    func waitersAreServedInOrder() {
        var lanes = Lanes()
        let holder = Self.arrive(&lanes)
        let first = Self.queueAndSuspend(&lanes, as: .examination)
        let second = Self.queueAndSuspend(&lanes, as: .step)
        let third = Self.queueAndSuspend(&lanes, as: .examination)

        #expect(lanes.leave(holder, fanAt: 0) == first)
        #expect(lanes.leave(first, fanAt: 0) == second)
        #expect(lanes.leave(second, fanAt: 0) == third)
        #expect(lanes.leave(third, fanAt: 0) == nil)
        #expect(lanes.isEmpty, "an idle lane was kept")
    }

    /// A grant decided before its entrant suspended is kept for it, and taken when it suspends.
    ///
    /// **Mutation:** in `Lanes.leave(_:fanAt:)`, drop `decided[next.ticket] = .granted`. Run: red
    /// on the suspension's answer.
    @Test("A grant made before the waiter suspends is kept for it")
    func aGrantBeforeSuspensionIsKept() {
        var lanes = Lanes()
        let holder = Self.arrive(&lanes)
        let waiter = Self.arrive(&lanes)

        #expect(lanes.leave(holder, fanAt: 0) == nil, "nothing is parked to resume yet")
        #expect(lanes.suspend(waiter, fanAt: 0) == .granted, "the grant was lost")
        #expect(lanes.isHeld(fanAt: 0))
        #expect(lanes.leave(waiter, fanAt: 0) == nil)
        #expect(lanes.isEmpty)
    }

    /// A grant and an expiry at the same instant: whichever reaches the lanes first is the answer,
    /// and the other changes nothing — in both orders.
    ///
    /// **Mutation:** in `Lanes.withdraw(_:fanAt:because:)`, end a wait already granted — before the
    /// `guard`, `if lanes[fan]?.holder == ticket { lanes[fan]?.holder = nil }`. Run: red on the
    /// holder after the expiry in the first order.
    @Test("A grant and an expiry at the same instant are decided once, either way round")
    func grantAndExpiryAreDecidedOnce() {
        var granted = Lanes()
        let holder = Self.arrive(&granted)
        let waiter = Self.queueAndSuspend(&granted)
        #expect(granted.leave(holder, fanAt: 0) == waiter)
        #expect(
            granted.withdraw(waiter, fanAt: 0, because: .expired)
                == FanExaminationGate.Withdrawal(resumes: false, outwaitedHolder: false),
            "an expiry after the grant was acted on")
        #expect(granted.isHeld(fanAt: 0), "the expiry took back a gate already granted")
        #expect(Self.queueAndSuspend(&granted) != 0, "the granted waiter no longer holds")

        var expired = Lanes()
        let incumbent = Self.arrive(&expired)
        let late = Self.queueAndSuspend(&expired)
        #expect(
            expired.withdraw(late, fanAt: 0, because: .expired)
                == FanExaminationGate.Withdrawal(resumes: true, outwaitedHolder: false))
        #expect(expired.leave(incumbent, fanAt: 0) == nil, "an expired waiter was granted")
        #expect(expired.isEmpty)
    }

    /// A cancelled waiter is never granted: suspended or not when its cancellation lands.
    ///
    /// **Mutation:** in `Lanes.withdraw(_:fanAt:because:)`, read the waiter instead of removing it
    /// — `let waiter = lane.waiters[at]`. Run: red on both grants.
    @Test("A cancelled waiter is never granted")
    func aCancelledWaiterIsNeverGranted() {
        var suspended = Lanes()
        let holder = Self.arrive(&suspended)
        let waiter = Self.queueAndSuspend(&suspended)
        #expect(suspended.withdraw(waiter, fanAt: 0, because: .withdrawn).resumes)
        #expect(suspended.leave(holder, fanAt: 0) == nil, "the cancelled waiter was granted")
        #expect(suspended.isEmpty)

        var arriving = Lanes()
        let incumbent = Self.arrive(&arriving)
        let early = Self.arrive(&arriving)
        #expect(arriving.withdraw(early, fanAt: 0, because: .withdrawn).resumes == false)
        #expect(arriving.leave(incumbent, fanAt: 0) == nil, "the cancelled arrival was granted")
        #expect(arriving.suspend(early, fanAt: 0) == .withdrawn)
        #expect(arriving.isEmpty)
    }

    /// Leaving with a ticket that does not hold releases nothing, a second leave included.
    ///
    /// **Mutation:** in `Lanes.leave(_:fanAt:)`, drop `lane.holder == ticket` from the `guard`.
    /// Run: red on both.
    @Test("Leaving a pass that does not hold is a no-op")
    func leavingWithoutHoldingIsANoOp() {
        var lanes = Lanes()
        let holder = Self.arrive(&lanes)
        let waiter = Self.queueAndSuspend(&lanes)

        #expect(lanes.leave(waiter, fanAt: 0) == nil, "a waiter's leave released the holder")
        #expect(lanes.waiting(onFan: 0) == 1)
        #expect(lanes.leave(holder, fanAt: 0) == waiter)
        #expect(lanes.leave(holder, fanAt: 0) == nil, "a second leave released the next holder")
        #expect(lanes.isHeld(fanAt: 0))
    }

    /// An examination whose wait ran out remembers the holder, and later examinations against that
    /// holder do not wait; a step still does, and the memory goes when the holder leaves. A step's
    /// own expiry records nothing.
    ///
    /// **Mutation (a):** delete `if outwaits { lane.outwaited = lane.holder }`. Run: red on the
    /// second examination. **(b):** record the holder for a step's expiry too — `let outwaits =
    /// outcome == .expired`. Run: red on the examination after the step's expiry.
    @Test("An outwaited holder is remembered until it leaves, by examinations only")
    func anOutwaitedHolderIsRemembered() {
        var lanes = Lanes()
        let stuck = Self.arrive(&lanes)
        let first = Self.queueAndSuspend(&lanes, as: .examination)
        #expect(lanes.withdraw(first, fanAt: 0, because: .expired).outwaitedHolder)

        #expect(lanes.arrive(fanAt: 0, as: .examination) == .outwaited(3), "it waited again")
        let step = Self.queueAndSuspend(&lanes, as: .step)
        #expect(lanes.leave(stuck, fanAt: 0) == step)
        #expect(
            lanes.arrive(fanAt: 0, as: .examination) == .queued(5),
            "the memory outlived the holder it was about")

        var steps = Lanes()
        _ = Self.arrive(&steps)
        let refused = Self.queueAndSuspend(&steps, as: .step)
        #expect(steps.withdraw(refused, fanAt: 0, because: .expired).outwaitedHolder == false)
        #expect(steps.arrive(fanAt: 0, as: .examination) == .queued(3), "a step outwaited")
    }

    /// **The gate prototype's first gap.** A cancellation that lands after the wait has run out
    /// leaves nothing behind, whether the entrant had suspended or not: the first decision stands
    /// and the second finds nothing to change. The prototype kept such a cancellation in a set for
    /// a suspension that had already happened, and the ticket stayed there for good.
    ///
    /// **Mutation:** the prototype's shape — in `Lanes.withdraw(_:fanAt:because:)`'s `else`, keep
    /// a cancellation for a ticket that does not hold: `if outcome == .withdrawn,
    /// lanes[fan]?.holder != ticket { decided[ticket] = .withdrawn }`. Run: red on `isEmpty`, both
    /// ways round.
    @Test("A cancellation after an expiry leaves no ticket behind")
    func aCancellationAfterAnExpiryLeavesNothing() {
        var suspended = Lanes()
        let holder = Self.arrive(&suspended)
        let waiter = Self.queueAndSuspend(&suspended)
        #expect(suspended.withdraw(waiter, fanAt: 0, because: .expired).resumes)
        #expect(suspended.withdraw(waiter, fanAt: 0, because: .withdrawn).resumes == false)
        #expect(suspended.leave(holder, fanAt: 0) == nil)
        #expect(suspended.isEmpty, "a ticket outlived its wait")

        var arriving = Lanes()
        let incumbent = Self.arrive(&arriving)
        let early = Self.arrive(&arriving)
        #expect(arriving.withdraw(early, fanAt: 0, because: .expired).resumes == false)
        #expect(arriving.withdraw(early, fanAt: 0, because: .withdrawn).resumes == false)
        #expect(arriving.suspend(early, fanAt: 0) == .expired, "the second decision won")
        #expect(arriving.leave(incumbent, fanAt: 0) == nil)
        #expect(arriving.isEmpty, "a ticket outlived its wait")
    }
}
