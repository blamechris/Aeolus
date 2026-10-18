import AeolusXPC
import AeolusXPCClient
import Foundation

/// Renews the lease on the heartbeat for as long as a request is outstanding, from the moment
/// the lease was asked for until the hold's own loop takes the schedule over.
///
/// ## Why it exists
///
/// The helper's thirty seconds start **at the grant**, and `apply` may now lawfully take 57
/// seconds for one fan and 109 for two (`HelperClientDeadlines.applyDeadline(naming:)`):
/// each fan's examination gate, a yield, and the undo's turn. A lease renewed only after
/// `apply` and its confirming snapshot would lapse in the middle of an `apply` that was
/// working, and `set` would then say it was holding a lease that had ended, or that the
/// helper had refused a speed it may have applied. `renewLease` is not sequenced behind
/// `apply` (`HelperMessage.sequenced`), so a renewal sent now is answered now.
///
/// ## One schedule, never two
///
/// The schedule is `renewedAt + heartbeat`, the same one `heartbeats` keeps. The keeper is
/// seeded with the instant taken **before `acquireLease` was sent**, which cannot be later
/// than the grant, so every renewal it makes is due no later than the helper's own clock
/// says. When the request has been answered `stop()` returns the instant of the last renewal
/// and the hold's loop starts from it. Nothing renews between the two: `stop()` does not
/// return until the keeper's loop has ended, and a renewal already on the wire is waited for,
/// not abandoned, so the release that follows can never be overtaken by one.
///
/// ## Stopped in a coordinated way
///
/// Only the keeper's **wait** is cancelled. A cancelled task's XPC call can fail at once for
/// no reason the helper gave (`HoldInterrupt` says the same of a signal), and a renewal that
/// failed for that reason would end a lease that was fine. The loop itself is never
/// cancelled; it looks at `stopping` between renewals.
///
/// ## It never retries
///
/// The first renewal that fails is final: the keeper stops renewing and records why. A lease
/// this run cannot show it still holds is lost (`CLAUDE.md` rules 2 and 6), and the run
/// reports it once the request it is waiting on has been answered.
actor LeaseKeeper {

    /// Why the keeper stopped on its own.
    enum Failure: Equatable, Sendable {
        /// A renewal was refused, or went unanswered, with this description.
        case renewal(String)
        /// The wait failed with nothing asking it to stop: the keeper cannot pace itself.
        case timer
    }

    /// What the keeper leaves behind.
    struct Handoff: Equatable, Sendable {
        /// When the last renewal was sent, or when the lease was asked for if none was.
        let renewedAt: ContinuousClock.Instant
        let failure: Failure?
    }

    private let client: HelperClient
    private let clock: SettleClock
    private let leaseID: UUID
    private var renewedAt: ContinuousClock.Instant
    private var failure: Failure?
    private var stopping = false
    private var waiting: Task<Void, any Error>?
    private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - client: The connection every renewal goes over.
    ///   - clock: The clock the schedule is kept on.
    ///   - leaseID: The lease to renew.
    ///   - renewedAt: When `acquireLease` was **sent**, never when it was answered.
    init(
        client: HelperClient, clock: SettleClock, leaseID: UUID,
        renewedAt: ContinuousClock.Instant
    ) {
        self.client = client
        self.clock = clock
        self.leaseID = leaseID
        self.renewedAt = renewedAt
    }

    /// Starts renewing. Returns at once.
    func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    /// Ends the loop, waits for a renewal already sent, and returns the schedule.
    func stop() async -> Handoff {
        stopping = true
        waiting?.cancel()
        await loop?.value
        return Handoff(renewedAt: renewedAt, failure: failure)
    }

    private func run() async {
        while !stopping {
            let now = clock.now()
            let due = renewedAt + SetCommand.heartbeat
            if now < due {
                guard await wait(due - now) else { return }
                continue
            }
            // Stamped before it is sent, as the hold's loop stamps: a slow answer must not
            // make the next one late.
            renewedAt = now
            do {
                _ = try await client.renewLease(id: leaseID)
            } catch {
                failure = .renewal(SetCommand.describe(error))
                return
            }
        }
    }

    /// Whether the wait ran its course. `false` when something asked the keeper to stop, or
    /// when the wait itself failed (recorded).
    ///
    /// **What failed is judged by the error, not by whether a stop was also asked for.** A
    /// cancelled wait is the keeper being stopped. Anything else is a timer that cannot pace
    /// the heartbeat, and it is recorded even if the stop arrived a moment later, so the order
    /// the two reach the keeper in cannot hide it.
    private func wait(_ duration: Duration) async -> Bool {
        let clock = self.clock
        let sleeper = Task { try await clock.waitOnHelper(duration) }
        waiting = sleeper
        if stopping { sleeper.cancel() }
        let outcome = await sleeper.result
        waiting = nil
        if case .failure(let error) = outcome {
            if !(error is CancellationError) || !stopping { failure = .timer }
            return false
        }
        return !stopping
    }
}
