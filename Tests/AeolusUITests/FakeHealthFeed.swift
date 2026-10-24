import AeolusXPCClient
import Foundation
import os

/// The control connection's health, for the fake's subscriptions.
///
/// Each subscription starts with the health now and then sees each change while it is live, and
/// a value equal to the health now is not a change, as `HelperClient` publishes. A subscription
/// ends the moment its consumer is cancelled, synchronously, or when its consumer lets go of the
/// stream, so `live` says whether the driver still watches.
///
/// **Stricter than `HelperClient` in one way:** ending a subscription drops any value still
/// queued for it, where a real `AsyncStream` may still deliver a value it buffered before the
/// cancel. The driver's correctness never rests on that: `LeaseDriver.lose(_:_:)` ignores a lease
/// that is not the one held.
final class HealthFeed: Sendable {

    private typealias Waiter = CheckedContinuation<HelperConnectionHealth?, Never>

    /// Ends a subscription when the stream holding it is released.
    final class Lifetime: Sendable {
        let feed: HealthFeed
        let token: UUID

        init(feed: HealthFeed, token: UUID) {
            self.feed = feed
            self.token = token
        }

        deinit { feed.end(token) }
    }

    private struct Subscription: Sendable {
        var first: HelperConnectionHealth?
        var queue: [HelperConnectionHealth] = []
        var waiter: Waiter?
    }

    private struct State: Sendable {
        var current: HelperConnectionHealth = .handshaken
        var subscriptions: [UUID: Subscription] = [:]
        var liveWatchers: [UUID: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

        mutating func satisfiedWatchers() -> [CheckedContinuation<Void, Never>] {
            let count = subscriptions.count
            let ready = liveWatchers.filter { $0.value.count == count }
            for key in ready.keys { liveWatchers[key] = nil }
            return ready.values.map(\.continuation)
        }
    }

    private enum Next {
        case now(HelperConnectionHealth?)
        case waiting
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many subscriptions are live now.
    var live: Int { state.withLock { $0.subscriptions.count } }

    func subscribe() -> UUID {
        let token = UUID()
        state.withLock { $0.subscriptions[token] = Subscription(first: $0.current) }
        return token
    }

    func next(for token: UUID) async -> HelperConnectionHealth? {
        await withCheckedContinuation { (continuation: Waiter) in
            let next = state.withLock { all -> Next in
                guard var subscription = all.subscriptions[token] else { return .now(nil) }
                defer { all.subscriptions[token] = subscription }
                if let first = subscription.first {
                    subscription.first = nil
                    return .now(first)
                }
                if !subscription.queue.isEmpty { return .now(subscription.queue.removeFirst()) }
                subscription.waiter = continuation
                return .waiting
            }
            if case .now(let value) = next { continuation.resume(returning: value) }
        }
    }

    func end(_ token: UUID) {
        let (waiter, watchers) = state.withLock { all in
            let waiter = all.subscriptions.removeValue(forKey: token)?.waiter
            return (waiter, all.satisfiedWatchers())
        }
        waiter?.resume(returning: nil)
        for watcher in watchers { watcher.resume() }
    }

    /// Publishes `value` to every live subscription, unless it is the health now.
    func push(_ value: HelperConnectionHealth) {
        let waiters = state.withLock { all -> [Waiter] in
            guard value != all.current else { return [] }
            all.current = value
            var woken: [Waiter] = []
            for token in all.subscriptions.keys {
                if let waiter = all.subscriptions[token]?.waiter {
                    all.subscriptions[token]?.waiter = nil
                    woken.append(waiter)
                } else {
                    all.subscriptions[token]?.queue.append(value)
                }
            }
            return woken
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    /// Suspends until exactly `count` subscriptions are live, or the calling task is cancelled.
    func untilLive(_ count: Int) async {
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { all -> Bool in
                    if Task.isCancelled || all.subscriptions.count == count { return true }
                    all.liveWatchers[token] = (count, continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let watcher = state.withLock { $0.liveWatchers.removeValue(forKey: token) }
            watcher?.continuation.resume()
        }
    }
}
