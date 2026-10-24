import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

@testable import AeolusUI

/// The helper's side of the control connection, for `LeaseDriver`'s suite.
///
/// - **A lease table.** `acquireLease` grants and lists a lease; `renewLease` and `releaseLease`
///   look it up and refuse an unknown one with `.leaseUnknown`, as `LeaseAuthority` does; a
///   refused renewal drops the lease, as an expiry would. `apply` checks the lease after it has
///   worked, as level 6 does before it replies.
/// - **Scripted answers**, consumed one per call: at once (the default), after a stretch of the
///   hand-wound clock, parked until the test answers it, refused with a fault, or failed with a
///   client error.
/// - **Parked replies released by hand** (`answerParked(_:)`), and by `disconnect()`, which
///   answers every parked call `connectionAbandoned` as `HelperClient.disconnect()` does.
/// - **An event log** (`LeaseLedger`) of each call as it arrives and as it is answered, at the
///   clock's instant.
///
/// Every call suspends at least once, on the actor hop, and a parked or delayed one suspends
/// inside the call, so two `apply`s the driver sent at once really are in flight together here
/// and `mostAppliesAtOnce` sees it.
actor FakeLeaseHelper: HelperLeaseControlling {

    enum Answer: Sendable {
        /// Answered at once, by the lease table.
        case now
        /// Answered when the clock reaches the call's instant plus this.
        case after(Duration)
        /// Answered when the test calls `answerParked(_:)`, or by `disconnect()`.
        case parked
        /// The helper says no.
        case refuse(AeolusXPCFault)
        /// No answer the client could read.
        case fail(HelperClientError)
    }

    enum Verb: Sendable, Hashable {
        case acquire, renew, release, apply
    }

    let clock: HandWoundClock
    let ledger: LeaseLedger

    private var scripts: [Verb: [Answer]] = [:]
    private var leases: [UUID: Lease] = [:]
    private var parkedCalls: [UInt64: (verb: Verb, continuation: CheckedContinuation<Void, any Error>)] =
        [:]
    private var issued: UInt64 = 0
    private var applying = 0
    private var mostApplying = 0
    private var pushedHealth: [HelperConnectionHealth] = []
    private var healthWaiters: [UInt64: CheckedContinuation<HelperConnectionHealth?, Never>] = [:]
    private var subscribed: Set<UUID> = []

    init(clock: HandWoundClock, ledger: LeaseLedger) {
        self.clock = clock
        self.ledger = ledger
    }

    /// The most `apply` calls that were ever in flight here at once.
    var mostAppliesAtOnce: Int { mostApplying }

    /// The leases the table holds now.
    var heldLeases: [UUID: Lease] { leases }

    /// Queues answers for `verb`, used one per call in order; with none left a call is answered
    /// at once.
    func script(_ verb: Verb, _ answers: Answer...) {
        scripts[verb, default: []].append(contentsOf: answers)
    }

    /// Answers every parked call of `verb`, as the table would have answered it.
    func answerParked(_ verb: Verb) {
        let ready = parkedCalls.filter { $0.value.verb == verb }
        for key in ready.keys { parkedCalls[key] = nil }
        for call in ready.values { call.continuation.resume() }
    }

    /// How many calls of `verb` are parked now.
    func parkedCount(_ verb: Verb) -> Int {
        parkedCalls.values.filter { $0.verb == verb }.count
    }

    /// Delivers `health` to the driver's subscription, as `HelperClient` publishes a change.
    func pushHealth(_ health: HelperConnectionHealth) async {
        await ledger.record(.healthPushed(health), at: clock.now)
        if let (key, waiter) = healthWaiters.first {
            healthWaiters[key] = nil
            waiter.resume(returning: health)
        } else {
            pushedHealth.append(health)
        }
    }

    // MARK: - The control connection

    func acquireLease(_ request: LeaseRequest) async throws -> Lease {
        await ledger.record(.acquire(request), at: clock.now)
        try await settle(.acquire)
        let lease = Lease(
            holderDescription: request.holderDescription,
            expiresAt: Date(timeIntervalSince1970: 1_000_000 + request.timeToLive),
            timeToLive: request.timeToLive, isSelfRenewing: request.isSelfRenewing)
        leases[lease.id] = lease
        await ledger.record(.acquireAnswered, at: clock.now)
        return lease
    }

    func renewLease(id: UUID) async throws -> Lease {
        await ledger.record(.renew(id), at: clock.now)
        do {
            try await settle(.renew)
        } catch let fault as AeolusXPCFault {
            leases[id] = nil
            throw fault
        }
        guard let lease = leases[id] else { throw AeolusXPCFault.leaseUnknown }
        await ledger.record(.renewAnswered(id), at: clock.now)
        return lease
    }

    func releaseLease(id: UUID) async throws {
        await ledger.record(.release(id), at: clock.now)
        try await settle(.release)
        guard leases.removeValue(forKey: id) != nil else { throw AeolusXPCFault.leaseUnknown }
        await ledger.record(.releaseAnswered(id), at: clock.now)
    }

    func apply(_ settings: [FanSetting], leaseID: UUID) async throws {
        await ledger.record(.apply(settings, lease: leaseID), at: clock.now)
        applying += 1
        mostApplying = max(mostApplying, applying)
        defer { applying -= 1 }
        do {
            try await settle(.apply)
            guard leases[leaseID] != nil else { throw AeolusXPCFault.leaseUnknown }
        } catch {
            await ledger.record(
                .applyAnswered(settings, callerCancelled: Task.isCancelled), at: clock.now)
            throw error
        }
        await ledger.record(
            .applyAnswered(settings, callerCancelled: Task.isCancelled), at: clock.now)
    }

    /// The value now (`.handshaken`, since the driver subscribes once a grant has arrived), then
    /// whatever the test pushes. Each time the driver asks for the next value is logged, so a test
    /// can tell that it has finished with the last one.
    nonisolated func healthUpdates() -> AsyncStream<HelperConnectionHealth> {
        let token = UUID()
        return AsyncStream(unfolding: { await self.nextHealth(for: token) })
    }

    func disconnect() async {
        await ledger.record(.disconnect, at: clock.now)
        leases.removeAll()
        let calls = parkedCalls.values
        parkedCalls.removeAll()
        for call in calls { call.continuation.resume(throwing: HelperClientError.connectionAbandoned) }
    }

    // MARK: - Answers

    private func settle(_ verb: Verb) async throws {
        let answer: Answer
        if var queued = scripts[verb], !queued.isEmpty {
            answer = queued.removeFirst()
            scripts[verb] = queued
        } else {
            answer = .now
        }
        switch answer {
        case .now:
            return
        case .after(let duration):
            try await clock.sleep(until: clock.now.advanced(by: duration))
        case .parked:
            try await park(verb)
        case .refuse(let fault):
            throw fault
        case .fail(let failure):
            throw failure
        }
    }

    private func park(_ verb: Verb) async throws {
        issued &+= 1
        let id = issued
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    parkedCalls[id] = (verb, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelParked(id) }
        }
    }

    private func cancelParked(_ id: UInt64) {
        parkedCalls.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func nextHealth(for token: UUID) async -> HelperConnectionHealth? {
        await ledger.record(.healthAsked, at: clock.now)
        if subscribed.insert(token).inserted { return .handshaken }
        if !pushedHealth.isEmpty { return pushedHealth.removeFirst() }
        issued &+= 1
        let id = issued
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<HelperConnectionHealth?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    healthWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelHealth(id) }
        }
    }

    private func cancelHealth(_ id: UInt64) {
        healthWaiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}
