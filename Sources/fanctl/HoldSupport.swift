import Dispatch
import Foundation
import os

/// The three signals that end a `fanctl set` hold in the ordinary way: Ctrl-C, `kill`, and a
/// terminal that closed. A hold ended by one of them still releases its lease and checks the
/// safe state; only SIGKILL and SIGSTOP are beyond that, and the lease's own 30-second lifetime
/// is what covers them.
enum HoldSignal: Sendable, Equatable {
    case interrupt
    case terminate
    case hangup

    static let all: [HoldSignal] = [.interrupt, .terminate, .hangup]

    /// The name a user would type, and what `--json` reports as `signal`.
    var name: String {
        switch self {
        case .interrupt: return "SIGINT"
        case .terminate: return "SIGTERM"
        case .hangup: return "SIGHUP"
        }
    }

    var number: Int32 {
        switch self {
        case .interrupt: return SIGINT
        case .terminate: return SIGTERM
        case .hangup: return SIGHUP
        }
    }
}

/// Delivers a signal to the hold loop by ending the loop's sleep, and by nothing else.
///
/// **Not by cancelling the task.** The release that follows a signal is an XPC call, and a call
/// made from a cancelled task can fail at once for no reason the helper gave: the lease would be
/// left to expire when a Ctrl-C was meant to hand it back. Only the sleep is cancelled, through
/// a task of its own, and the signal is remembered so the loop sees it whenever it next looks
/// (during an XPC call, say) as well as when the sleep ends.
///
/// The first signal wins and later ones change nothing: a second Ctrl-C during the release is
/// ignored, not a different reason.
final class HoldInterrupt: Sendable {

    enum Wake: Equatable, Sendable {
        /// The sleep ran its course.
        case elapsed
        /// A signal arrived, before the sleep or during it.
        case signal(HoldSignal)
        /// The sleep failed with no signal behind it. The loop cannot pace itself without a
        /// working timer, so this ends the hold; it is never treated as time passing.
        case failed
    }

    private struct State {
        var pending: HoldSignal?
        var sleeper: Task<Void, any Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Records `signal` and ends the sleep in progress, if there is one. Callable from any
    /// thread, which is what a signal handler needs.
    func post(_ signal: HoldSignal) {
        let sleeper = state.withLock { state -> Task<Void, any Error>? in
            if state.pending == nil { state.pending = signal }
            return state.sleeper
        }
        sleeper?.cancel()
    }

    /// The signal that has arrived, if one has.
    var pending: HoldSignal? { state.withLock { $0.pending } }

    /// Sleeps for `duration` on `clock`, or until a signal arrives.
    ///
    /// A signal posted before this is called ends it at once: the sleeper is registered and the
    /// pending signal read under one lock, so there is no gap between the two for a signal to
    /// fall into.
    func sleep(for duration: Duration, on clock: SettleClock) async -> Wake {
        let sleeper = Task { try await clock.sleep(duration) }
        let alreadyPending = state.withLock { state -> Bool in
            state.sleeper = sleeper
            return state.pending != nil
        }
        if alreadyPending { sleeper.cancel() }
        let outcome = await sleeper.result
        let signal = state.withLock { state -> HoldSignal? in
            state.sleeper = nil
            return state.pending
        }
        if let signal { return .signal(signal) }
        switch outcome {
        case .success: return .elapsed
        case .failure: return .failed
        }
    }
}

/// Signal handlers that are installed, and how to take them down again.
///
/// A class, and **not `Sendable`**: it holds `DispatchSource`s and is made and used by one
/// command's `run()`, which is the only reason it can be a plain object.
final class SignalSubscription {
    private var sources: [any DispatchSourceSignal]
    private var restores: [() -> Void]

    init(sources: [any DispatchSourceSignal] = [], restores: [() -> Void] = []) {
        self.sources = sources
        self.restores = restores
    }

    /// Stops delivering and puts back the dispositions it found. Safe to call twice.
    func cancel() {
        for source in sources { source.cancel() }
        sources = []
        for restore in restores { restore() }
        restores = []
    }

    /// A subscription that holds nothing, for a suite that has no process to protect.
    static var none: SignalSubscription { SignalSubscription() }
}

/// What `fanctl set` asks of the process it runs in: who its parent is, and how signals reach it.
///
/// Closures, and `Decodable` by hand, for the reasons `HelperConnection` and `SettleClock` give.
/// There is no flag that reaches either, and there must never be one: a signal source the suite
/// can substitute is how every ending is reached without sending this process a signal.
struct HoldEnvironment: Decodable, Sendable {

    /// The parent's process ID, read once at the start and again at every heartbeat. A parent
    /// that exited reparents the process (to launchd, normally), which changes the answer.
    let parentProcessID: @Sendable () -> Int32

    /// Starts delivering SIGINT, SIGTERM and SIGHUP to the handler, and ignores SIGPIPE.
    let installSignals:
        @Sendable (_ deliver: @escaping @Sendable (HoldSignal) -> Void) -> SignalSubscription

    init(
        parentProcessID: @escaping @Sendable () -> Int32,
        installSignals:
            @escaping @Sendable (@escaping @Sendable (HoldSignal) -> Void) -> SignalSubscription
    ) {
        self.parentProcessID = parentProcessID
        self.installSignals = installSignals
    }

    init(from decoder: Decoder) throws {
        self = .production
    }

    static let production = HoldEnvironment(
        parentProcessID: { getppid() },
        installSignals: { deliver in
            var restores: [() -> Void] = []
            // A write to a closed pipe must come back as EPIPE, which ends the hold in an orderly
            // way, rather than kill a process that is holding a lease.
            let previousPipe = signal(SIGPIPE, SIG_IGN)
            restores.append { _ = signal(SIGPIPE, previousPipe) }

            let sources = HoldSignal.all.map { held -> any DispatchSourceSignal in
                let previous = signal(held.number, SIG_IGN)
                restores.append { _ = signal(held.number, previous) }
                let source = DispatchSource.makeSignalSource(
                    signal: held.number, queue: DispatchQueue.global())
                source.setEventHandler { deliver(held) }
                source.resume()
                return source
            }
            return SignalSubscription(sources: sources, restores: restores)
        })
}
