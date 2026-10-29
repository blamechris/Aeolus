import Foundation
import os

/// `HelperClient`'s connection health, and every stream that follows it (#541).
///
/// ## Why this is not the actor's state
///
/// `healthUpdates()` is `nonisolated`, so that a caller can open a stream without awaiting the
/// client. While the observers were the actor's state, that stream reached them through two
/// tasks, one to register and one to remove, and two tasks reach an actor in no set order. A
/// stream that ended before its registration ran left an observer that nothing would take away
/// (#532), and #533 made the removal wait for the registration.
///
/// Here the observers, and the value a new one starts with, are held under a lock that any
/// thread may take. `HealthObservers.stream()` registers in the closure `AsyncStream` runs inside
/// its initialiser, and the stream's termination handler removes. Neither starts a task, so a
/// stream that ends has left by the time whatever ended it returns, and there is no order to
/// keep. A stream ends when its last holder drops it, or when the task reading it is cancelled
/// while it waits on the stream. A reader cancelled while busy elsewhere has not ended it yet: its
/// observer is removed at that reader's next `next()`, which returns `nil` at once.
///
/// ## Two halves over one set of observers
///
/// - **This signal**, which publishes and reads the value now. `HelperClient` keeps its one
///   instance in a `private` stored property, so only `HelperClient.swift` can name it, and only
///   on the client's actor, to which an actor's stored properties are isolated. It is **not
///   `Sendable`** (see below), so the compiler refuses a task that captures it to publish from
///   anywhere else. Every publication therefore runs on the actor, one at a time, as it did when
///   the state was the actor's own.
/// - **`Streams`**, which only subscribes. It is `Sendable`, so `healthUpdates()` reaches it
///   without the actor. Nothing on it publishes, and nothing outside this file can make a signal
///   from it.
///
/// ## What it keeps
///
/// - **A value equal to the one now is not published.** `publish(_:)` compares and stores under
///   the lock, so a stream never sees the same value twice in a row.
/// - **In order, once each.** Each publication is one `yield` to each observer, into a stream that
///   buffers without bound. The yields are made after the lock is released; the actor, which runs
///   one publication to its end before the next, is what keeps two publications' yields apart.
/// - **An observer starts with the value now.** Registering stores the observer and yields it the
///   value now in one step under the lock, and a publication stores its value and takes the
///   observers to yield to in one step under the same lock. So a registration is wholly before a
///   publication or wholly after it. Its first element is the value at registration, and the next
///   is the next change.
///
/// ## The one yield made under the lock
///
/// The first value is yielded inside the lock, because a registration and a publication are two
/// writers to one new stream. If the first value went out after the lock was released, a
/// publication could take the lock in between, find the new observer, and yield it the next value
/// ahead of its first. That yield cannot wake anything or call back: the stream is still inside
/// `AsyncStream`'s initialiser, so it has no reader, and the yield appends to its buffer. Nor does
/// `AsyncStream` call the termination handler from inside its own lock: `cancel()`, `finish()`
/// and its storage's `deinit` call it after releasing that lock, so the lock here is never taken
/// inside the stream's.
///
/// **Pinned by the thread race test, not by the argument.** `HealthSignalThreadRaceTests`'
/// `registrationsOnTheirOwnThreadsAreHandedTheValueAfterTheirFirst()` makes streams on four
/// threads of their own while another thread publishes, 1,400 bursts of 32 streams, and requires
/// each stream's second element to be the value published right after its first. It runs on
/// threads, not on the cooperative pool, so it needs no free pool thread beside the publisher.
/// Run, debug, each red in 5 of 5 runs at `total.broken.isEmpty`:
///
/// - **V2:** yield the first value after the lock is released. A publication takes the lock in
///   the gap and yields the next value first, so a stream reads a value and then the one before
///   it.
/// - **C1:** in `HealthObservers.store(_:)`, take the observers in one `withLock` section and set
///   the value in a second. A registration between them is missed by the publication and starts
///   with the old value.
/// - **C2:** the same two sections, setting the value first. A registration between them starts
///   with the new value and is also in the publication's snapshot, so it reads that value twice.
///
/// The window is a few instructions wide: in the two sweeps of 5 debug runs that measured it, V2
/// broke 10 to 24 of 44,800 streams a run. That is what those sweeps broke, not a property of the
/// window: other runs fell outside it (a review's broke 8, and 6 and 40 on a pool of one thread).
/// The run-ordering test beside it registers 200 streams, a few of them while the owner
/// publishes, and stayed green under V2 in 10 of 10 debug runs.
/// That `AsyncStream` calls its termination handler outside its own lock is the standard
/// library's, read in its source, and no test pins it.
struct HealthSignal {

    private let observers: HealthObservers

    /// The half of this signal that only subscribes, for `healthUpdates()`.
    let streams: Streams

    /// A signal whose value is `health` until the first publication.
    init(startingWith health: HelperConnectionHealth) {
        let observers = HealthObservers(startingWith: health)
        self.observers = observers
        streams = Streams(observers: observers)
    }

    /// The value now.
    var current: HelperConnectionHealth { observers.current }

    /// Makes `health` the value now and yields it to every observer, unless it is the value now
    /// already.
    func publish(_ health: HelperConnectionHealth) {
        guard let observers = observers.store(health) else { return }
        for observer in observers { observer.yield(health) }
    }

    /// The streams of one signal's observers: `Sendable`, and able only to subscribe.
    struct Streams: Sendable {
        fileprivate let observers: HealthObservers

        /// A stream of every value from the one now.
        func updates() -> AsyncStream<HelperConnectionHealth> { observers.stream() }

        /// How many observers are registered now, for the suite. The suite reaches a client's
        /// instance by reflection, so this adds nothing to `HelperClient`.
        var observerCount: Int { observers.count }
    }
}

/// Not `Sendable`, so the client's instance cannot leave the client's actor: a task that captured
/// it to publish from elsewhere is refused at compile time.
///
/// Without this the compiler would infer `Sendable`, since every member is, and a `nonisolated`
/// method of the client could then publish. Pinned by
/// `scripts/lending-probes/refused-health-signal-publish.swift`, which `check.sh` runs in CI:
/// with this extension deleted, the probe compiles and `check.sh` is red, 1 of 1. No test sees
/// it.
@available(*, unavailable)
extension HealthSignal: Sendable {}

/// The observers of one client's health, and the value a new one starts with, under one lock.
///
/// Private to this file, so a signal and its `Streams` are the only ways to reach one.
private final class HealthObservers: Sendable {

    typealias Observer = AsyncStream<HelperConnectionHealth>.Continuation

    private struct State {
        var current: HelperConnectionHealth
        var observers: [UUID: Observer] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(startingWith health: HelperConnectionHealth) {
        state = OSAllocatedUnfairLock(initialState: State(current: health))
    }

    var current: HelperConnectionHealth { state.withLock { $0.current } }

    /// A stream that starts with the value now, registered before this returns and removed by
    /// the time whatever ends it returns (a reader cancelled while busy elsewhere has not ended
    /// it: see "Why this is not the actor's state").
    ///
    /// The termination handler is set after the observer is registered. Nothing can end the
    /// stream between the two: this closure runs inside `AsyncStream`'s initialiser, before
    /// anyone holds the stream, and nothing in this client calls `finish()`.
    ///
    /// The handler holds this object weakly. This object holds the observer, and the observer
    /// holds the handler, so a strong reference would be a cycle that kept the observers alive
    /// after their client for as long as a stream stayed open. The handler holds nothing else, so
    /// nothing a stream holds reaches the client, and a connection-owning actor is never kept
    /// alive by a stream somebody forgot to end.
    ///
    /// Pinned by `HelperClientHealthStreamTests.theObserversAreFreedWithTheClient()`: writing the
    /// handler's `[weak self]` as `[self]` (A) leaves these observers alive after the client is
    /// freed, red in 5 of 5 debug runs, and the only red among the 7 tests of
    /// `HelperClientHealthStreamTests`, `HealthSignalTests` and `HealthSignalThreadRaceTests`.
    func stream() -> AsyncStream<HelperConnectionHealth> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let token = UUID()
            state.withLock { state in
                state.observers[token] = continuation
                continuation.yield(state.current)
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { $0.observers[token] = nil }
            }
        }
    }

    /// Stores `health` as the value now and returns every observer registered before it, for the
    /// signal to yield `health` to once the lock is released, or `nil` if `health` is the value
    /// now already.
    func store(_ health: HelperConnectionHealth) -> [Observer]? {
        state.withLock { state in
            guard health != state.current else { return nil }
            state.current = health
            return Array(state.observers.values)
        }
    }

    /// How many observers are registered now.
    var count: Int { state.withLock { $0.observers.count } }
}
