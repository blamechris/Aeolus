import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

@testable import AeolusUI

/// Everything that happened in a lease-driver scene, in the order it reached the ledger, each at
/// the hand-wound clock's instant.
///
/// The fake helper writes a call when it **arrives** and again when it is **answered**. The scene
/// forwards the driver's states here as well, so one wait can say "the state became `lost`, or a
/// second renewal arrived": a mutant that does the wrong thing ends the wait with the evidence
/// rather than hanging it. A state reaches the ledger through a forwarding task, a moment after
/// the driver published it, so states are for waiting on, never for ordering assertions against
/// calls; those are made between calls, which the fake records in the order it handled them.
actor LeaseLedger {

    enum Event: Sendable, Hashable {
        case acquire(LeaseRequest)
        case acquireAnswered
        case renew(UUID)
        case renewAnswered(UUID)
        case release(UUID)
        case releaseAnswered(UUID)
        case apply([FanSetting], lease: UUID)
        case applyAnswered([FanSetting], callerCancelled: Bool)
        case disconnect
        case healthAsked
        case healthPushed(HelperConnectionHealth)
        case state(LeaseDriverState)
        /// A quit was answered, with whether to terminate.
        case terminationReplied(Bool)
        /// A call `LeaseScene.call(_:)` started has returned.
        case callReturned(UUID)
    }

    struct Entry: Sendable, Hashable {
        let event: Event
        let at: ContinuousClock.Instant
    }

    private struct Waiter {
        let condition: @Sendable ([Entry]) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private var log: [Entry] = []
    private var waiters: [UInt64: Waiter] = [:]
    private var issued: UInt64 = 0

    var entries: [Entry] { log }

    func record(_ event: Event, at instant: ContinuousClock.Instant) {
        log.append(Entry(event: event, at: instant))
        let ready = waiters.filter { $0.value.condition(log) }
        for key in ready.keys { waiters[key] = nil }
        for waiter in ready.values { waiter.continuation.resume() }
    }

    /// Suspends until the log satisfies `condition`, or the calling task is cancelled.
    func waitFor(_ condition: @escaping @Sendable ([Entry]) -> Bool) async {
        issued &+= 1
        let id = issued
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || condition(log) {
                    continuation.resume()
                } else {
                    waiters[id] = Waiter(condition: condition, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    private func abandon(_ id: UInt64) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }
}

extension [LeaseLedger.Entry] {

    var acquires: [LeaseRequest] {
        compactMap { if case .acquire(let request) = $0.event { request } else { nil } }
    }

    var renewals: [ContinuousClock.Instant] {
        compactMap { if case .renew = $0.event { $0.at } else { nil } }
    }

    var releases: [UUID] {
        compactMap { if case .release(let id) = $0.event { id } else { nil } }
    }

    var applies: [[FanSetting]] {
        compactMap { if case .apply(let settings, _) = $0.event { settings } else { nil } }
    }

    var states: [LeaseDriverState] {
        compactMap { if case .state(let state) = $0.event { state } else { nil } }
    }

    /// Where the first entry matching `event` sits, if any.
    func index(of event: LeaseLedger.Event) -> Int? {
        firstIndex { $0.event == event }
    }

    /// Where the first entry whose event satisfies `matches` sits, if any.
    func index(where matches: (LeaseLedger.Event) -> Bool) -> Int? {
        firstIndex { matches($0.event) }
    }

    var lost: LeaseLoss? {
        for state in states.reversed() {
            if case .lost(let loss) = state { return loss }
        }
        return nil
    }
}
