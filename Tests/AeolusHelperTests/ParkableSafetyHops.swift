import Foundation
import Testing

@testable import AeolusHelper

/// One of § 5's hops held open on a continuation: the parking `ParkableHeldLeases`,
/// `ParkableThermalLatch` and `ParkableReclamationLedger` share (#344, #380).
///
/// A double asks the real actor first and parks here after it has answered, so the answer § 5
/// resumes with is a true one about the instant it was asked, and whatever the test does while it
/// is held lands between that actor answering and § 5 resuming: the return leg of the hop, which
/// is the suspension a reentrant actor is exposed to. It suspends on a continuation and blocks no
/// cooperative-pool thread, which is what failed in a CI runner stall (#344's lesson), and
/// cancelling the parked task resumes it, so `finished(_:_:)`'s cancel ends a scenario rather
/// than leaving it parked for the rest of the process.
///
/// One hop at a time. Each double arms the hop it parks and disarms it on the first call that
/// parks, so a second park while one is held is a defect in the scenario, and is recorded as one
/// rather than overwriting the held continuation and leaving it parked for good.
actor HopParking {
    private var parked: CheckedContinuation<Void, Never>?
    private var cancelled = false

    /// Whether a hop is being held open now.
    var isParked: Bool { parked != nil }

    /// Lets the held hop go. Nothing happens when none is held.
    func release() {
        parked?.resume()
        parked = nil
    }

    /// Holds the caller here until `release()`, or until its task is cancelled.
    func park() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if cancelled || parked != nil {
                    if parked != nil { Issue.record("a second hop parked while one was held") }
                    continuation.resume()
                } else {
                    parked = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        cancelled = true
        release()
    }
}

/// § 3's latch, with § 5's next question about it held open once armed (#380).
///
/// The seam `diverged(_:fanAt:heldUnder:)`'s precedence check needed. `currentRuling()` asks
/// through `ThermalLatchRole`; this answers from the real latch and then parks, so a scenario can
/// land a registration, a release or a report between the latch answering and § 5 resuming. Only
/// § 5's own questions come here: the engagement driver and § 3 hold the real latch, so the bit
/// they read and set is the one this reads.
actor ParkableThermalLatch: ThermalLatchRole {
    private let latch: ThermalEmergencyLatch
    private let parking = HopParking()
    private var armed = false

    /// The answers given, in order, parked or not.
    private(set) var answers: [Bool] = []

    init(_ latch: ThermalEmergencyLatch) {
        self.latch = latch
    }

    /// Holds the next answer open until `release()`.
    func parkNextAnswer() { armed = true }

    /// Whether an answer is being held open now.
    var isParked: Bool {
        get async { await parking.isParked }
    }

    /// Lets the held answer go.
    func release() async { await parking.release() }

    var isActive: Bool {
        get async {
            let answer = await latch.isActive
            answers.append(answer)
            if armed {
                armed = false
                await parking.park()
            }
            return answer
        }
    }
}

/// § 5's ledger, with its next call of one kind held open once armed (#380).
///
/// The seam `diverged(_:fanAt:heldUnder:)`'s reclamation report needed, and the one A6's gate
/// lands a level-6 report in. Each call reaches the real ledger first, so the mark or the clear
/// has landed and the answer is the ledger's own, and then parks if it is the armed kind. The
/// snapshot's reads and a test's assertions go to the real ledger, which holds what § 5 wrote.
actor ParkableReclamationLedger: ReclamationLedgerRole {

    /// Which of the role's three calls to hold open.
    enum Hop: Sendable, Hashable {
        case markReclaimed
        case markSupervisorBlind
        case clearReclaimed
    }

    /// One call § 5 made, and what the ledger answered.
    struct Call: Sendable, Hashable {
        let hop: Hop
        let fan: Int
        let changed: Bool
    }

    private let ledger: ReclamationLedger
    private let parking = HopParking()
    private var armed: Hop?

    /// Every call § 5 made, in order, parked or not.
    private(set) var calls: [Call] = []

    init(_ ledger: ReclamationLedger) {
        self.ledger = ledger
    }

    /// Holds the next call of kind `hop` open until `release()`.
    func parkNext(_ hop: Hop) { armed = hop }

    /// Whether a call is being held open now.
    var isParked: Bool {
        get async { await parking.isParked }
    }

    /// Lets the held call go.
    func release() async { await parking.release() }

    func markReclaimed(fanAt index: Int) async -> Bool {
        let changed = await ledger.markReclaimed(fanAt: index)
        return await answered(Call(hop: .markReclaimed, fan: index, changed: changed))
    }

    @discardableResult
    func markSupervisorBlind(fanAt index: Int) async -> Bool {
        let changed = await ledger.markSupervisorBlind(fanAt: index)
        return await answered(Call(hop: .markSupervisorBlind, fan: index, changed: changed))
    }

    func clearReclaimed(fanAt index: Int) async -> Bool {
        let changed = await ledger.clearReclaimed(fanAt: index)
        return await answered(Call(hop: .clearReclaimed, fan: index, changed: changed))
    }

    /// Records `call`, parks it if it is the armed kind, and returns the ledger's answer.
    private func answered(_ call: Call) async -> Bool {
        calls.append(call)
        if armed == call.hop {
            armed = nil
            await parking.park()
        }
        return call.changed
    }
}
