import Foundation
import os

/// What a stamped round trip is doing.
///
/// A value of this type is a **read-only description** of a call that is already out. It
/// confers no capability: nothing here can start a round trip, and the selector is only ever
/// the byte `SMCConnection` was about to send.
public enum SMCRoundTripOperation: Sendable, Equatable {
    /// One `IOConnectCallStructMethod`.
    ///
    /// `key` is the four-character code exactly as it went over the wire — not an `SMCKey`.
    /// A `READ_INDEX` call carries key `0`, which is not a key at all, and building a string
    /// per round trip would put an allocation on the hot path of every read. Whatever shows
    /// this to a person shows the raw code beside any friendly label.
    case call(key: FourCharCode, selector: UInt8)
    /// `IOServiceOpen`: the slow path of `SMCConnection.open()`.
    case open
    /// `IOServiceClose`, from `SMCConnection.close()`.
    case close
}

/// A round trip that has begun and not yet returned, as of the moment it was read.
public struct SMCRoundTripInFlight: Sendable, Equatable {
    /// Strictly increasing across the life of one monitor, so two readings with the same
    /// number are the same round trip and a different number is a different one. This is
    /// what lets an observer tell "one call that has not returned" from "many short calls
    /// that happened to be in flight each time I looked".
    public let sequence: UInt64
    public let operation: SMCRoundTripOperation
    /// How long it has been out, measured on the suspending clock: time the machine spent
    /// asleep is not counted (ADR 0012 I3).
    public let age: Duration
}

/// The stamp every SMC round trip leaves while it is in flight (ADR 0012 I1).
///
/// `SMCConnection` is an actor that calls IOKit synchronously inside itself. If that call
/// never returns, the actor is held for good, and nothing that has to go through the actor
/// can ever learn it. This type is the way around that: a lock-guarded record of the call in
/// flight, set immediately before the IOKit call and cleared in a `defer`, that anything can
/// read **without entering the connection**.
///
/// ## What it is, and what it is not
///
/// It is a mechanism for *observing* a round trip that has not returned. It decides nothing:
/// there is no deadline here, no timer, and nothing is abandoned or retried. A watchdog reads
/// `inFlight()` and decides what an age means.
///
/// ## The lock is never held across the call
///
/// `bracket(_:_:)` takes the lock to set the stamp, **releases it**, runs the body, and takes
/// it again to clear. A reader therefore blocks for the length of two tiny critical sections
/// at worst, never for the length of an IOKit call — the one thing a wedge makes unbounded.
/// If the lock were held across the body, the observer meant to detect a stuck call would
/// itself be stuck behind it. `SMCRoundTripMonitorTests.theLockIsNotHeldAcrossTheCall` holds
/// that line.
///
/// ## One slot
///
/// There is one stamp, not a set, because a connection makes one call at a time: it is an
/// actor and every bracketed call is synchronous. **One monitor belongs to one connection.**
/// Two connections sharing a monitor would overwrite each other's stamp, and the first to
/// return would erase the other's — hiding exactly the wedge this exists to show.
///
/// Nothing in the type prevents an overlap by construction, so two things stand guard. In a
/// debug build a bracket that begins while another is in flight **traps** with a message
/// naming the cause. In every build a bracket clears the slot only if the slot still holds
/// *its own* stamp, so when A begins, B begins and A returns first, B's stamp is not erased
/// by A's return. That is defence in depth and not a licence: A's own stamp was already
/// replaced when B began, so an overlap still hides A, and the assertion is how it is found.
///
/// ## How a monitor is reached
///
/// The initialiser is internal. **The only public way to a monitor is
/// `SMCConnection.roundTrips`**, so the monitor a watchdog reads is by construction the one a
/// connection stamps. A public initialiser would let a caller build a monitor that nothing
/// writes to, and a watchdog reading it would see no round trip in flight for ever.
///
/// ## Sendable by construction
///
/// All state is behind an `OSAllocatedUnfairLock<State>`, so the compiler checks `Sendable`
/// rather than being told. An unchecked-sendability annotation is a claim a review has to
/// take on trust; here there is nothing to take on trust.
///
/// ## Cost
///
/// A round trip pays two uncontended unfair-lock operations and one clock read, and so does
/// `fanctl`, on every one. The second clock read, for the age, is paid only by an observer
/// that asks.
public final class SMCRoundTripMonitor: Sendable {

    /// The clock the monitor ages a round trip on. **This one line is the clock family.**
    ///
    /// `SuspendingClock` stops while the machine sleeps; `ContinuousClock` does not. A call in
    /// flight across a sleep would age by the whole sleep on the latter and be killed as a
    /// wedge on wake, so the watchdog's per-round-trip bound is measured on the former
    /// (ADR 0012 I3). The test that pins this asserts on the type, not on a clock it built.
    typealias MeasuringClock = SuspendingClock
    typealias Instant = MeasuringClock.Instant

    private struct Stamp: Sendable {
        let sequence: UInt64
        let operation: SMCRoundTripOperation
        let began: Instant
    }

    private struct State: Sendable {
        /// Round trips begun, ever. A stamp's sequence is this value after the increment, so
        /// the first round trip of a monitor is sequence 1 and 0 is never a stamp.
        var issued: UInt64 = 0
        var current: Stamp?
        var lastBegun: SMCRoundTripOperation?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The monitor's own notion of "now". Read in `inFlight()`: no instant is ever handed to
    /// a caller, so no caller can mint one on a different clock and compare it against ours.
    private let now: @Sendable () -> Instant

    convenience init() {
        self.init(clock: MeasuringClock())
    }

    /// Test seam: a clock the test can move. Internal, so no client can age a stamp on a
    /// clock of its own.
    init<C: Clock>(clock: C) where C.Instant == Instant {
        self.now = { clock.now }
    }

    /// The round trip in flight, or `nil` if none is.
    ///
    /// Safe to call from any thread, including while the connection is wedged: it takes the
    /// stamp lock for the length of a copy, and never touches the connection. **Not from a
    /// signal handler** — the lock is an `os_unfair_lock`, which is not async-signal-safe, and
    /// a handler that interrupted a bracket on this thread would try to take a lock it holds.
    ///
    /// The age is computed here, from this monitor's clock, at the moment of the call — not
    /// when the stamp was taken. "Now" is read **after** the stamp is copied out, so it can
    /// never precede the stamp's own start and the age is never negative.
    public func inFlight() -> SMCRoundTripInFlight? {
        guard let stamp = state.withLock({ $0.current }) else { return nil }
        return SMCRoundTripInFlight(
            sequence: stamp.sequence,
            operation: stamp.operation,
            age: stamp.began.duration(to: now()))
    }

    /// How many round trips have begun on this monitor. Test seam: a hardware test asserts
    /// that N keys cost exactly N (warm) or 2N (cold) calls. Internal, because nothing that
    /// is not a test has a reason to count them.
    var issuedCount: UInt64 {
        state.withLock { $0.issued }
    }

    /// The operation of the most recent round trip to **begin**, whether or not it has since
    /// returned. Test seam, beside `issuedCount`: the stamp's value is what a verdict will
    /// name, so a test has to be able to read what a real call stamped after it is gone.
    var lastBegunOperation: SMCRoundTripOperation? {
        state.withLock { $0.lastBegun }
    }

    /// Runs `body` — the IOKit call — with `operation` stamped as in flight.
    ///
    /// Set, release, run, clear: the lock is held only for the two bookkeeping steps. The
    /// clear is in a `defer`, so a body that throws leaves nothing behind; a stamp left by a
    /// call that failed would read as a wedge that never ended. It clears only its own stamp.
    ///
    /// In a debug build this traps if another round trip is in flight (see "One slot").
    @discardableResult
    func bracket<Value>(
        _ operation: SMCRoundTripOperation, _ body: () throws -> Value
    ) rethrows -> Value {
        try run(operation, enforcingOneSlot: true, body)
    }

    /// Test seam: `bracket` without the debug trap, so a test can drive the overlap the trap
    /// exists to forbid and assert what every build does when it happens. Nothing but a test
    /// has a reason to call this.
    @discardableResult
    func bracketAllowingOverlapForTesting<Value>(
        _ operation: SMCRoundTripOperation, _ body: () throws -> Value
    ) rethrows -> Value {
        try run(operation, enforcingOneSlot: false, body)
    }

    private func run<Value>(
        _ operation: SMCRoundTripOperation, enforcingOneSlot: Bool, _ body: () throws -> Value
    ) rethrows -> Value {
        let began = now()
        let sequence = state.withLock { state -> UInt64 in
            assert(
                !enforcingOneSlot || state.current == nil,
                "overlapping round-trip brackets: one monitor belongs to one connection, and a "
                    + "connection makes one call at a time (ADR 0012 I1)")
            state.issued += 1
            state.current = Stamp(sequence: state.issued, operation: operation, began: began)
            state.lastBegun = operation
            return state.issued
        }
        defer {
            state.withLock { state in
                if state.current?.sequence == sequence { state.current = nil }
            }
        }
        return try body()
    }
}
