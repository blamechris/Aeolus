import Foundation
import os

// Who follows a `LeaseDriver`, and the sending of its states and reports to them (#511).
//
// **Nothing here reads or sets the driver's state**, which is why it can live outside
// `LeaseDriver.swift` with nothing there widened. The driver hands over every value it sends,
// once `transition(to:)` has set the state and minted any floor it sets. `current`, the
// evidence, the ticket epoch and `transition(to:)` stay `private` to the driver, and
// `SnapshotTicket`'s epoch stays `fileprivate`.

/// Every observer of one `LeaseDriver`, and the publishing of its states and reports to them.
///
/// ## Two halves over one set of observers (#541)
///
/// The observers, and the value each kind of stream starts with, are held under a lock by
/// `Followers`, which only this file can name. Two values reach them:
///
/// - **This publisher**, which publishes. The driver keeps its one instance in a `private`
///   stored property, so only `LeaseDriver.swift` can name it, and only on the driver's actor, to
///   which an actor's stored properties are isolated. It is **not `Sendable`** (see the end of this
///   file), so the compiler refuses a task that captures that instance to publish from anywhere
///   else.
/// - **`Streams`**, which only subscribes. It is `Sendable`, so the driver's `nonisolated`
///   `stateUpdates()` and `reportUpdates()` reach it without the actor. Nothing on it publishes,
///   and nothing outside this file can make a publisher from it.
///
/// ## A stream joins and leaves synchronously
///
/// `Followers.stream()` registers the new observer, and yields it the value now, in the closure
/// `AsyncStream` runs inside its initialiser. The stream's termination handler removes it. Both
/// take the lock and neither starts a task, so a stream that ends has left by the time whatever
/// ended it returns, whether it ended at once or after a long read. A stream ends when its last
/// holder drops it, or when the task reading it is cancelled while it waits on the stream. A
/// reader cancelled while busy elsewhere has not ended it yet: its observer is removed at that
/// reader's next `next()`, which returns `nil` at once.
///
/// Before #541 both were tasks that reached the observers on the driver's actor, because they
/// were the actor's state and the streams are asked for from outside it. Nothing ordered the two
/// tasks, so a stream that ended before its registration ran left an observer that nothing would
/// take away (#526). #530 made the removal wait for the registration. With no task, there is no
/// order to keep.
///
/// ## What it keeps
///
/// - **A state goes out with its floor.** `publishStateChange(_:)` is handed the report the
///   driver made for the state, after the floor was minted. It sends that report's state to the
///   state observers and the report itself to the report observers. Nothing here sends a state
///   without the report it belongs to.
/// - **In order, and never coalesced.** Each publication is one `yield` to each observer, in the
///   order the driver asks, into a stream that buffers without bound. So an observer that is slow
///   to read still reads every element, in order.
/// - **Every method that publishes is synchronous**, and runs on the driver's actor, since only
///   the actor can reach this publisher. So a publication runs to its end inside the turn of the
///   driver's actor that asked for it: no other job runs between a state and its report, or
///   between one publication and the next. A suspension here, or a hop to another actor, would let
///   a state go out apart from its floor, or let two publications swap (ADR 0015 D2). The yields
///   are made after the lock is released, and the actor is what keeps two publications' yields
///   apart.
/// - **An observer starts with the value now.** Registering stores the observer and yields it the
///   value now in one step under the lock, and a publication stores its value and takes the
///   observers to yield to in one step under the same lock. So a registration is wholly before a
///   publication or wholly after it. Before: the observer's first element is the value before,
///   and the publication yields it the new one. After: its first is the new value, and the
///   publication, which took its observers first, does not yield to it. Either way its first
///   element is the value at registration, and the next is the next change.
/// - **That value is the driver's report.** `LeaseDriver` starts its publisher with its own
///   report, and every change of `current` or `evidence` is published in the turn that makes it.
///   So between turns of the actor the value here is `LeaseDriver.report`. Pinned for the
///   evidence write in `applyAnswered()` by `LeaseDriverEvidencePublishTests`'
///   `aNewObserverStartsWithTheReportAsTheEvidenceMovesAlone()`: publishing it from a task (B)
///   is red in 5 of 5 debug runs. A registration on another thread can land in the
///   middle of a turn: it starts with the last value stored when it takes the lock, which in a
///   turn that makes several changes is any one of them and not necessarily the value before the
///   turn, and then gets every later one.
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
/// **Pinned by the thread race test, not by the argument.** `LeaseDriverPublisherThreadRaceTests`'
/// `registrationsOnTheirOwnThreadsAreHandedTheChangeAfterTheirFirst()` makes streams of both
/// kinds on four threads of their own while another thread publishes, 1,400 bursts of 32 streams,
/// and requires each stream's second element to be the change published right after its first. It
/// runs on threads, not on the cooperative pool, so it needs no free pool thread beside the
/// publisher. Run, debug, each red in 5 of 5 runs at `total.broken.isEmpty`:
///
/// - **V2:** yield the first value after the lock is released. A publication takes the lock in
///   the gap and yields the next change first, so a stream reads a change and then the one before
///   it.
/// - **C1:** in `Followers.store(_:)`, take the observers in one `withLock` section and set the
///   value in a second. A registration between them is missed by the publication and starts
///   with the old value.
/// - **C2:** the same two sections, setting the value first. A registration between them starts
///   with the new value and is also in the publication's snapshot, so it reads that value twice.
///
/// The window is a few instructions wide: V2 breaks 5 to 16 of 44,800 streams a run. The
/// run-ordering test beside it registers 200 streams, a few of them while the owner publishes,
/// and stayed green under V2 in 10 of 10 debug runs.
/// That `AsyncStream` calls its termination handler outside its own lock is the standard
/// library's, read in its source, and no test pins it.
struct LeaseDriverPublisher {

    private let states: Followers<LeaseDriverState>
    private let reports: Followers<LeaseDriverReport>

    /// The half of this publisher that only subscribes, for the driver's `nonisolated` streams.
    let streams: Streams

    /// A publisher whose streams start with `report` until the first publication.
    init(startingWith report: LeaseDriverReport) {
        let states = Followers(startingWith: report.state)
        let reports = Followers(startingWith: report)
        self.states = states
        self.reports = reports
        streams = Streams(states: states, reports: reports)
    }

    // MARK: - Publishing

    /// A change of state: `report.state` to every state observer, then `report` to every report
    /// observer. `report` is the one the driver made for the state, with any floor it sets in it.
    func publishStateChange(_ report: LeaseDriverReport) {
        for observer in states.store(report.state) { observer.yield(report.state) }
        for observer in reports.store(report) { observer.yield(report) }
    }

    /// The evidence moved and the state did not, as it does when the last unanswered `apply`
    /// answers after the driver stopped acting or let go of a lease (ADR 0015 D5): `report` to
    /// every report observer, and nothing to the state observers, which have no new state to see.
    func publishEvidenceChange(_ report: LeaseDriverReport) {
        for observer in reports.store(report) { observer.yield(report) }
    }

    // MARK: - Streams

    /// The streams of one publisher's observers: `Sendable`, and able only to subscribe.
    struct Streams: Sendable {
        fileprivate let states: Followers<LeaseDriverState>
        fileprivate let reports: Followers<LeaseDriverReport>

        /// A stream of every state from the one now.
        func stateUpdates() -> AsyncStream<LeaseDriverState> { states.stream() }

        /// A stream of every report from the one now.
        func reportUpdates() -> AsyncStream<LeaseDriverReport> { reports.stream() }

        /// How many observers of each kind are registered now, for the suite. The suite reaches
        /// a driver's instance by reflection, so this adds nothing to the driver.
        var observerCounts: (states: Int, reports: Int) { (states.count, reports.count) }
    }
}

/// Not `Sendable`, so the driver's instance cannot leave the driver's actor: a task that captured
/// it to publish from elsewhere is refused at compile time.
///
/// Without this the compiler would infer `Sendable`, since every member is, and a `nonisolated`
/// method of the driver could then publish. Pinned by
/// `scripts/lending-probes/refused-lease-driver-publisher-publish.swift`, which `check.sh` runs
/// in CI: with this extension deleted, the probe compiles and `check.sh` is red, 1 of 1. No test
/// sees it.
@available(*, unavailable)
extension LeaseDriverPublisher: Sendable {}

/// The observers of one kind of stream, and the value a new one starts with, under one lock.
///
/// Private to this file, so a publisher and its `Streams` are the only ways to reach one.
private final class Followers<Element: Sendable>: Sendable {

    private struct State {
        var current: Element
        var observers: [UUID: AsyncStream<Element>.Continuation] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(startingWith value: Element) {
        state = OSAllocatedUnfairLock(initialState: State(current: value))
    }

    /// A stream that starts with the value now, registered before this returns and removed by
    /// the time whatever ends it returns (a reader cancelled while busy elsewhere has not ended
    /// it: see "A stream joins and leaves synchronously").
    ///
    /// The termination handler is set after the observer is registered. Nothing can end the
    /// stream between the two: this closure runs inside `AsyncStream`'s initialiser, before
    /// anyone holds the stream, and nothing here calls `finish()`.
    ///
    /// The handler holds this object weakly. This object holds the observer, and the observer
    /// holds the handler, so a strong reference would be a cycle that kept the observers alive
    /// after their driver for as long as a stream stayed open. The handler holds nothing else, so
    /// nothing a stream holds reaches the driver.
    ///
    /// Pinned by `LeaseDriverStreamTerminationTests.theObserversAreFreedWithTheirDriver()`:
    /// writing the handler's `[weak self]` as `[self]` (A) leaves these observers alive after the
    /// driver is freed, red in 5 of 5 debug runs, and the only red among the 10 tests of
    /// `LeaseDriverStreamTerminationTests`, `LeaseDriverPublisherTests`,
    /// `LeaseDriverPublisherThreadRaceTests`, `LeaseDriverEvidencePublishTests` and
    /// `LeaseDriverPublishOrderTests`.
    func stream() -> AsyncStream<Element> {
        // Unbounded, so a slow reader drops nothing: every state, and every floor, is delivered.
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

    /// Stores `value` as the value now, and returns every observer registered before it, for the
    /// publisher to yield `value` to once the lock is released.
    func store(_ value: Element) -> [AsyncStream<Element>.Continuation] {
        state.withLock { state in
            state.current = value
            return Array(state.observers.values)
        }
    }

    /// How many observers are registered now.
    var count: Int { state.withLock { $0.observers.count } }
}
