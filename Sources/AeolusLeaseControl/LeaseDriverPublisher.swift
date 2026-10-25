import Foundation

// Who follows a `LeaseDriver`, and the sending of its states and reports to them (#511).
//
// **Nothing here reads or sets the driver's state**, which is why it can live outside
// `LeaseDriver.swift` with nothing there widened. The driver hands over every value it sends,
// once `transition(to:)` has set the state and minted the floor. `current`, the evidence, the
// ticket epoch and `transition(to:)` stay `private` to the driver, and `SnapshotTicket`'s epoch
// stays `fileprivate`.

/// Every observer of one `LeaseDriver`, and the publishing of its states and reports to them.
///
/// ## Owned by the driver, and used only on its actor
///
/// The driver keeps its one instance in a `private` stored property. So only `LeaseDriver.swift`
/// can name it, and only on the driver's actor, to which an actor's stored properties are
/// isolated. It is **not `Sendable`** (see the end of this file), so the compiler refuses a task
/// that captures that instance to publish from anywhere else.
///
/// **Every method is synchronous.** A publication runs to its end inside the turn of the driver's
/// actor that asked for it, so no other job runs between a state and its report, or between one
/// publication and the next. A suspension here, or a hop to another actor, would let a state go
/// out apart from its floor, or let two publications swap (ADR 0015 D2).
///
/// The type is `internal`, so other code in the module can make an instance of its own. That
/// instance is not the driver's: only closures written in `LeaseDriver.swift` can reach the
/// driver's, so no subscriber of a driver is ever registered with another, and what another
/// publishes reaches none of them.
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
/// - **An observer starts with the value now.** Adding one registers it and yields it the value
///   it is handed in one synchronous step on the driver's actor. No change can come between the
///   two, so its first element is the value at registration, and the next is the next change.
/// - **A stream that ends leaves.** `stream(of:add:remove:)` removes its observer, on the
///   driver's actor, once the stream has terminated.
struct LeaseDriverPublisher {

    private var stateObservers: [UUID: AsyncStream<LeaseDriverState>.Continuation] = [:]
    private var reportObservers: [UUID: AsyncStream<LeaseDriverReport>.Continuation] = [:]

    // MARK: - Publishing

    /// A change of state: `report.state` to every state observer, then `report` to every report
    /// observer. `report` is the one the driver made for the state, with its floor already in it.
    func publishStateChange(_ report: LeaseDriverReport) {
        for observer in stateObservers.values { observer.yield(report.state) }
        for observer in reportObservers.values { observer.yield(report) }
    }

    /// The evidence moved and the state did not, as it does when the last unanswered `apply`
    /// answers after the driver stopped acting: `report` to every report observer, and nothing to
    /// the state observers, which have no new state to see.
    func publishEvidenceChange(_ report: LeaseDriverReport) {
        for observer in reportObservers.values { observer.yield(report) }
    }

    // MARK: - Observers

    /// Adds `observer` as `token`, and yields it `state`, the driver's state now.
    mutating func addStateObserver(
        _ observer: AsyncStream<LeaseDriverState>.Continuation, as token: UUID,
        startingWith state: LeaseDriverState
    ) {
        stateObservers[token] = observer
        observer.yield(state)
    }

    mutating func removeStateObserver(_ token: UUID) {
        stateObservers[token] = nil
    }

    /// Adds `observer` as `token`, and yields it `report`, the driver's report now.
    mutating func addReportObserver(
        _ observer: AsyncStream<LeaseDriverReport>.Continuation, as token: UUID,
        startingWith report: LeaseDriverReport
    ) {
        reportObservers[token] = observer
        observer.yield(report)
    }

    mutating func removeReportObserver(_ token: UUID) {
        reportObservers[token] = nil
    }

    // MARK: - Streams

    /// Registers an observer as a token, and yields it the value now, on the driver's actor.
    typealias Registration<Element: Sendable> =
        @Sendable (isolated LeaseDriver, AsyncStream<Element>.Continuation, UUID) -> Void

    /// A stream of `driver`'s, whose observer `add` registers on the driver's actor and `remove`
    /// takes away there once the stream has terminated.
    ///
    /// The registration is a task of its own, because the driver's streams are asked for from
    /// outside its actor (`stateUpdates()` and `reportUpdates()` are `nonisolated`). `add`
    /// registers and yields the value now in one step, so whichever turn it runs in, the stream
    /// starts with the value then and misses no change after it.
    ///
    /// The termination handler holds the driver weakly. The driver holds the observer, and the
    /// observer holds this handler, so a strong reference would be a cycle.
    static func stream<Element: Sendable>(
        of driver: LeaseDriver, add: @escaping Registration<Element>,
        remove: @escaping @Sendable (isolated LeaseDriver, UUID) -> Void
    ) -> AsyncStream<Element> {
        // Unbounded, so a slow reader drops nothing: every state, and every floor, is delivered.
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let token = UUID()
            continuation.onTermination = { [weak driver] _ in
                guard let driver else { return }
                Task { await remove(driver, token) }
            }
            Task { await add(driver, continuation, token) }
        }
    }
}

/// Not `Sendable`, so the driver's instance cannot leave the driver's actor: a task that captured
/// it to publish from elsewhere is refused at compile time.
@available(*, unavailable)
extension LeaseDriverPublisher: Sendable {}
