import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import os

@testable import AeolusLeaseControl

/// The helper's side of the control connection, for `LeaseDriver`'s suite.
///
/// - **A lease table.** `acquireLease` grants and lists a lease; `renewLease` and `releaseLease`
///   look it up and refuse an unknown one with `.leaseUnknown`, as `LeaseAuthority` does; a
///   refused renewal drops the lease, as an expiry would. A renewal answers the lease with a new
///   `expiresAt`, as the helper's does. `apply` checks the lease after it has worked, as level 6
///   does before it replies.
/// - **Scripted answers**, consumed one per call: at once (the default), after a stretch of the
///   hand-wound clock, parked until the test answers it, refused with a fault, or failed with a
///   client error.
/// - **Parked replies released by hand**, every one of a verb (`answerParked(_:throwing:)`) or
///   the one that parked first (`answerOldestParked(_:throwing:)`), and by `disconnect()`, which
///   answers every call still waiting, parked or delayed, `connectionAbandoned`, and publishes
///   `.idle`, as `HelperClient.disconnect()` does.
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
        /// Answered when the clock reaches the instant the call arrived, plus this.
        case after(Duration)
        /// Answered when the test calls `answerParked(_:throwing:)`, or by `disconnect()`.
        case parked
        /// As `parked`, and a cancelled caller is not answered early: the reply a helper sent
        /// before it heard of the cancellation.
        case parkedThroughCancellation
        /// The helper says no.
        case refuse(AeolusXPCFault)
        /// No answer the client could read.
        case fail(HelperClientError)
    }

    private typealias Parked = CheckedContinuation<Void, any Error>

    enum Verb: Sendable, Hashable {
        case acquire, renew, release, apply
    }

    let clock: HandWoundClock
    let ledger: LeaseLedger
    /// The control connection's health, as the driver's subscriptions see it.
    nonisolated let health = HealthFeed()

    private let start: ContinuousClock.Instant
    private var scripts: [Verb: [Answer]] = [:]
    private var leases: [UUID: Lease] = [:]
    private var parkedCalls: [UInt64: (verb: Verb, continuation: Parked)] = [:]
    private var timers: [UInt64: Task<Void, Never>] = [:]
    private var issued: UInt64 = 0
    private var applying = 0
    private var mostApplying = 0
    private var grantedTimeToLive: TimeInterval?
    /// Whether a call has built the connection `disconnect()` would tear down.
    private var connected = false
    private var renewsAnotherLease = false

    init(clock: HandWoundClock, ledger: LeaseLedger) {
        self.clock = clock
        self.ledger = ledger
        self.start = clock.now
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

    /// Grants the next leases with this TTL rather than the one asked for, as a helper that
    /// clamps would.
    func grant(timeToLive: TimeInterval) {
        grantedTimeToLive = timeToLive
    }

    /// Answers renewals with a lease of another identifier, as a broken helper might.
    func renewAnotherLease() {
        renewsAnotherLease = true
    }

    /// Answers every parked call of `verb`: as the table would have, or with `error`.
    func answerParked(_ verb: Verb, throwing error: (any Error)? = nil) {
        answer(parkedCalls.filter { $0.value.verb == verb }.keys, throwing: error)
    }

    /// Answers one parked call of `verb`, the one that parked first, and leaves any others
    /// parked: as the table would have, or with `error`.
    ///
    /// - Returns: Whether a call of `verb` was parked to answer.
    @discardableResult
    func answerOldestParked(_ verb: Verb, throwing error: (any Error)? = nil) -> Bool {
        // Each call's key is issued as it parks, so the smallest key parked first.
        guard let oldest = parkedCalls.filter({ $0.value.verb == verb }).keys.min() else {
            return false
        }
        answer([oldest], throwing: error)
        return true
    }

    private func answer(_ keys: some Collection<UInt64>, throwing error: (any Error)?) {
        var ready: [Parked] = []
        for key in keys {
            timers.removeValue(forKey: key)?.cancel()
            if let call = parkedCalls.removeValue(forKey: key) { ready.append(call.continuation) }
        }
        for continuation in ready {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    /// Delivers `health` to every live subscription, as `HelperClient` publishes a change.
    func pushHealth(_ value: HelperConnectionHealth) async {
        await ledger.record(.healthPushed(value), at: clock.now)
        health.push(value)
    }

    // MARK: - The control connection

    func acquireLease(_ request: LeaseRequest) async throws -> Lease {
        let arrived = clock.now
        await ledger.record(.acquire(request), at: arrived)
        try await settle(.acquire, arrivedAt: arrived)
        let timeToLive = grantedTimeToLive ?? request.timeToLive
        let lease = Lease(
            holderDescription: request.holderDescription, expiresAt: expiry(after: timeToLive),
            timeToLive: timeToLive, isSelfRenewing: request.isSelfRenewing)
        leases[lease.id] = lease
        await ledger.record(.acquireAnswered, at: clock.now)
        return lease
    }

    func renewLease(id: UUID) async throws -> Lease {
        let arrived = clock.now
        await ledger.record(.renew(id), at: arrived)
        do {
            try await settle(.renew, arrivedAt: arrived)
        } catch let fault as AeolusXPCFault {
            leases[id] = nil
            throw fault
        }
        guard let lease = leases[id] else { throw AeolusXPCFault.leaseUnknown }
        let renewed = Lease(
            id: renewsAnotherLease ? UUID() : lease.id, holderDescription: lease.holderDescription,
            expiresAt: expiry(after: lease.timeToLive), timeToLive: lease.timeToLive,
            isSelfRenewing: lease.isSelfRenewing)
        leases[id] = Lease(
            id: id, holderDescription: lease.holderDescription, expiresAt: renewed.expiresAt,
            timeToLive: lease.timeToLive, isSelfRenewing: lease.isSelfRenewing)
        await ledger.record(.renewAnswered(id), at: clock.now)
        return renewed
    }

    func releaseLease(id: UUID) async throws {
        let arrived = clock.now
        await ledger.record(.release(id), at: arrived)
        try await settle(.release, arrivedAt: arrived)
        guard leases.removeValue(forKey: id) != nil else { throw AeolusXPCFault.leaseUnknown }
        await ledger.record(.releaseAnswered(id), at: clock.now)
    }

    func apply(_ settings: [FanSetting], leaseID: UUID) async throws {
        let arrived = clock.now
        await ledger.record(.apply(settings, lease: leaseID), at: arrived)
        applying += 1
        mostApplying = max(mostApplying, applying)
        defer { applying -= 1 }
        do {
            try await settle(.apply, arrivedAt: arrived)
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
    /// whatever the test pushes while this subscription is live. Each time the driver asks for
    /// the next value is logged, so a test can tell that it has finished with the last one.
    nonisolated func healthUpdates() -> AsyncStream<HelperConnectionHealth> {
        let token = health.subscribe()
        let feed = health
        // Ends the subscription when the driver lets go of the stream without cancelling it, as
        // a watch that returned does: the closure below is released with the stream.
        let lifetime = HealthFeed.Lifetime(feed: feed, token: token)
        return AsyncStream(
            unfolding: {
                _ = lifetime
                await self.ledger.record(.healthAsked, at: self.clock.now)
                return await feed.next(for: token)
            },
            onCancel: { feed.end(token) })
    }

    func disconnect() async {
        await ledger.record(.disconnect, at: clock.now)
        // `HelperClient.disconnect()` publishes `.idle` only when it had a connection, and its
        // health never repeats a value.
        if connected {
            connected = false
            health.push(.idle)
        }
        leases.removeAll()
        let calls = parkedCalls.values
        parkedCalls.removeAll()
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        for call in calls {
            call.continuation.resume(throwing: HelperClientError.connectionAbandoned)
        }
    }

    // MARK: - Answers

    /// Answers a call as scripted. A delay is measured from the instant the call was logged, which
    /// is the instant a test saw it arrive: reading the clock again here could read it after the
    /// test had already moved it on, and push the answer past the instant the test meant.
    private func settle(_ verb: Verb, arrivedAt arrived: ContinuousClock.Instant) async throws {
        // A call builds the connection if there is none, and re-handshakes one the helper
        // interrupted, as `HelperClient` does on its next message: the health is handshaken
        // again. `push` repeats nothing, so on a healthy connection this publishes nothing.
        connected = true
        health.push(.handshaken)
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
            try await park(verb, answeredAt: arrived.advanced(by: duration))
        case .parked:
            try await park(verb)
        case .parkedThroughCancellation:
            try await park(verb, throughCancellation: true)
        case .refuse(let fault):
            throw fault
        case .fail(let failure):
            throw failure
        }
    }

    /// Waits to be answered: by the test, by `disconnect()`, by the clock reaching `deadline` if
    /// one is given, or, unless `throughCancellation`, by the caller's cancellation.
    private func park(
        _ verb: Verb, answeredAt deadline: ContinuousClock.Instant? = nil,
        throughCancellation: Bool = false
    ) async throws {
        issued &+= 1
        let id = issued
        if let deadline {
            let clock = self.clock
            timers[id] = Task {
                do { try await clock.sleep(until: deadline) } catch { return }
                self.answerTimed(id)
            }
        }
        if throughCancellation {
            try await withCheckedThrowingContinuation { (continuation: Parked) in
                parkedCalls[id] = (verb, continuation)
            }
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Parked) in
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

    private func answerTimed(_ id: UInt64) {
        timers[id] = nil
        parkedCalls.removeValue(forKey: id)?.continuation.resume()
    }

    private func cancelParked(_ id: UInt64) {
        timers.removeValue(forKey: id)?.cancel()
        parkedCalls.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    /// A display expiry `timeToLive` after now, on a wall clock that moves with the hand-wound
    /// one.
    private func expiry(after timeToLive: TimeInterval) -> Date {
        let elapsed = start.duration(to: clock.now)
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Date(timeIntervalSince1970: 1_000_000 + seconds + timeToLive)
    }
}
