import AeolusLeaseControl
import AeolusXPC
import AeolusXPCClient
import Foundation

/// The app's one reader of helper snapshots, and the judge of whether the last one may still
/// be rendered.
///
/// [ADR 0006](../../../docs/ADR/0006-single-smc-reader.md) is the policy: while the connection
/// is `.handshaken` and the latest snapshot is within its bound, the app renders that snapshot
/// and stops reading the SMC for anything it carries. `authority()` is that decision, and it
/// has three answers rather than two, because the ADR allows direct reads in a build with a
/// helper only while the helper is absent, unapproved, refused, version-mismatched or
/// unreachable:
///
/// - `.fresh`: render the snapshot.
/// - `.readDirectly(why)`: no claim, and the app reads the SMC itself.
/// - `.awaitHelper(why)`: no claim, and the app reads **nothing** — the connection is being
///   made, or is handshaken and its first answer in this episode has not come yet, or its last
///   answer in this episode has outlived its bound. Reading the SMC then would put a discovery
///   walk of every key beside the helper's own, until the helper answers.
///
/// ## One per app
///
/// The main window, the menu bar and the Settings window each own a `PollingViewModel`, and
/// all three share this object. Three sources would be three `snapshot` streams of ~138 KB a
/// second each into a root daemon (ADR 0006's measured figure). `start()` and `stop()` count
/// the consumers that want it, so closing the window does not stop the menu bar's snapshots.
///
/// ## One request at a time, and none ever cancelled
///
/// The request loop sends `snapshot`, waits for its answer, pauses, and sends the next. There
/// is never a second request in flight, because there is never a second loop: `start()` makes
/// one only when none exists, and a loop that is waiting for a reply when its last consumer
/// leaves finishes that wait before it ends.
///
/// **Nothing here cancels a request.** `stop()`, `retrySoon()` and `readSoon()` cancel only the
/// pause between requests. A request outstanding at `stop()` is left to finish, and its answer
/// is **kept**: it is a real reply, stamped when it arrived, and the freshness bound decides
/// whether anything may render it later. A `start()` that arrives while it is outstanding does
/// not send another; the loop that sent it carries on once it is answered. Each request also
/// runs in its own unstructured task, so even a cancelled loop could not cancel it.
///
/// That is #419's rule for the read side. `HelperClient` keeps a cancelled caller's sequenced
/// message in flight with its deadline running (`InFlightMessages`), so a view that cancelled
/// and re-sent a `snapshot` behind a wedged `apply` would pile up orphans, each adding a whole
/// deadline before the live read's own began. And **no SwiftUI `.task` owns this await**:
/// SwiftUI cancels a `.task` when its view disappears, which is exactly the cancellation this
/// type exists not to make. Views call `start()` and `stop()`; the loop's task belongs to this
/// object.
///
/// ## Only a snapshot from this handshaken episode is ever rendered
///
/// The connection's episode advances every time this object sees its health **leave**
/// `.handshaken`. A request is stamped with the episode it was sent in, and its reply may be
/// rendered only while that is still the episode. So once the helper process is replaced —
/// `.interrupted`, then a fresh `hello` publishing `.handshaken` again before the next reply —
/// nothing the dead process said is shown as current, however young it is: its lease, its
/// modes and its emergency flag all went with it (`HelperConnectionHealth.interrupted`). A reply
/// that straddles a departure is dropped the same way. The stamp is taken at send rather than
/// at arrival for exactly that case, and it is not "the health at send": the first handshake
/// happens inside the first request, so the health then is `.idle`.
///
/// **A failure does not outlive the next handshake** (#501). The episode moves only on a
/// departure, so a request that failed between a departure and the next handshake — or before
/// the first handshake of all, while the helper was not yet approved — carries the episode that
/// handshake belongs to. Left in place, it would license direct reads from the handshake until
/// that handshake's own request was answered, beside a helper that has just answered `hello`. So
/// hearing a handshake retires a failure recorded before it, and the source waits
/// (`.awaitHelper(.awaitingSnapshot)`) for the answer the handshake's request brings. A failure
/// recorded after the handshake reads directly, as any failure does. The episode is not moved
/// on a handshake instead: the request it was made in was stamped before it, so its reply —
/// the first good one — would be dropped.
///
/// ## Fresh is measured from arrival, on a clock that does not stop in sleep
///
/// A snapshot is fresh for `refreshInterval + HelperClientDeadlines.gatedVerb`, measured from
/// the instant its reply reached this object. The bound is one pause plus one full deadline:
/// if the helper wedges on the next request, `HelperClient` gives up on it at `gatedVerb`, and
/// by then this snapshot has already gone stale rather than outliving the wedge. The interval is
/// read **live**, on every cycle and every judgement, so the bound follows a change at once in
/// either direction. A pause already under way is cut short once the preference has held still
/// for `intervalSettleDelay` (`refreshIntervalDidChange()`), so the cadence follows within that
/// and one round trip.
///
/// **`SystemSnapshot.capturedAt` is never compared against.** It is the helper's wall clock,
/// which can jump, and an age read off it would make a snapshot fresh forever after a clock
/// change. Age is measured on a `ContinuousClock`-shaped clock instead, chosen over
/// `SuspendingClock` because it keeps counting while the Mac sleeps: a snapshot from before
/// sleep must be stale after wake, not fresh for another few seconds of awake time.
///
/// ## A failed request is backed off, never retried in a loop
///
/// Each failure doubles the pause before the next request, up to `retryCeiling`, and a reply
/// resets it. `HelperClient` never retries on its own, because a client reconnecting to a
/// mach name launchd is restarting a daemon behind is a boot-loop amplifier; a fixed one-second
/// cadence against an absent or refusing helper would be that amplifier at the caller's level.
/// `retrySoon()` ends a backoff early when the user has just done something that may have
/// fixed it — approving the helper, or coming back to the app — and starts the count again. A
/// changed refresh interval ends one too, and keeps the count (`refreshIntervalDidChange()`).
///
/// ## No client at all in a build with no helper
///
/// `AppComposition` builds a `HelperClient` only for a bundle that ships a helper
/// (`HelperEmbedding.embedded`). A `Monitor` build — and a damaged bundle — gets a source with
/// no reader, whose `authority()` always says why nothing is tracked.
///
/// ## The lease driver sees every reply, on a ticket taken before the read
///
/// In a build with a helper the source reports each read to the lease driver through a
/// `HelperSnapshotObserver`: the ticket before the request's task exists, and every successful
/// reply after it is recorded. See that type for why, and for what is judged. The ticket is kept
/// beside the reply it was taken for, and `.fresh` carries it, so a consumer can tell whether the
/// snapshot was read after the driver last let go (ADR 0015 D2, D5). The source holds no policy
/// about it: it neither compares tickets nor withholds a snapshot for one.
///
/// ## A read soon after the driver stops acting
///
/// Automatic is claimed only from a snapshot read after the driver's latest floor, minted when it
/// stops acting or, beside a held lease, when it lets go of one (ADR 0015 D5), and the next
/// ordinary read can be a minute away. `readSoon()` cuts an ordinary pause, by the path a settled
/// interval change takes, so the user's own Auto reads selected within about one round trip.
@MainActor
public final class HelperSnapshotSource {

    /// What a consumer may render right now, and whether it may read the SMC itself.
    public enum Authority: Sendable, Hashable {
        /// A snapshot from this handshaken episode, within its bound. `receivedAt` is this
        /// process's wall clock when the reply arrived, for a "last updated" label only.
        /// `readWith` is the lease driver's ticket for the read that brought it, taken before the
        /// request was sent, or `nil` from a source with no observer.
        case fresh(SystemSnapshot, receivedAt: Date, readWith: LeaseDriver.SnapshotTicket?)
        /// Nothing may be claimed about control, and the consumer reads the SMC itself:
        /// ADR 0006's fallback.
        case readDirectly(ControlNotTracked)
        /// Nothing may be claimed about control, and the consumer reads nothing: a helper is
        /// being connected to, or has handshaken and owes this episode its first answer, or its
        /// last answer in this episode has outlived its bound.
        case awaitHelper(ControlNotTracked)

        /// Why nothing may be claimed, or `nil` for a fresh snapshot.
        public var notTracked: ControlNotTracked? {
            switch self {
            case .fresh: return nil
            case .readDirectly(let why), .awaitHelper(let why): return why
            }
        }
    }

    /// The longest pause after failed requests, in seconds. A failure pauses twice
    /// `refreshInterval`, and each further one doubles that, up to here — or to
    /// `refreshInterval` itself if that is longer.
    public static let retryCeiling: TimeInterval = 30

    /// How long the refresh interval must hold still before a change cuts the pause under way:
    /// the debounce in `refreshIntervalDidChange()` (#485 S2).
    public static let intervalSettleDelay: TimeInterval = 0.3

    private enum Reading {
        case none(ControlNotTracked)
        case helper(any HelperSnapshotReading)
    }

    private enum Answer {
        case received(
            SystemSnapshot, arrivedAt: ContinuousClock.Instant, wallClock: Date,
            ticket: LeaseDriver.SnapshotTicket?)
        case failed(detail: String)
        case contradicted(detail: String)
    }

    private let reading: Reading
    /// The lease driver's view of each read, or `nil` when there is no driver.
    private let observer: HelperSnapshotObserver?
    private let refreshInterval: @MainActor () -> TimeInterval
    private let now: @Sendable () -> ContinuousClock.Instant
    private let pacing: any PollingClock
    /// What the interval's debounce waits on.
    private let settling: any PollingClock

    /// The connection's health as last reported by `healthUpdates()`. `.idle` until the first
    /// report arrives, which licenses nothing.
    private(set) var health: HelperConnectionHealth = .idle

    /// Advances every time `health` leaves `.handshaken`. See this type's documentation.
    private var episode: UInt64 = 0
    /// The latest answer, and the episode its request was sent in.
    private var latest: (answer: Answer, episode: UInt64)?
    private var consecutiveFailures = 0
    private var demand = 0

    /// The request loop, while one exists. At most one.
    private var loop: Task<Void, Never>?
    /// The request in flight, while one is. Nothing in this type cancels it.
    private var outstanding: Task<SystemSnapshot, any Error>?
    /// The pause between two requests: the only task `stop()`, `retrySoon()`, `readSoon()` and a
    /// settled interval change cancel.
    private var pause: Task<Void, Never>?
    /// The wait for the refresh interval to hold still, while one is running.
    private var intervalSettle: Task<Void, Never>?
    /// Whether `readSoon()` found no pause to cut while the loop was running, so the pause after
    /// the cycle under way is skipped. See `readSoon()`.
    private var readOwed = false
    private var healthWatch: Task<Void, Never>?

    /// A source for a process with no helper to read: `authority()` is always
    /// `.readDirectly(why)`, and `start()`/`stop()` only count consumers.
    public convenience init(withoutHelper why: ControlNotTracked) {
        self.init(
            reading: .none(why), observer: nil,
            refreshInterval: { PreferencesRefreshInterval.defaultValue },
            clock: ContinuousClock(), pacing: SystemPollingClock(), settling: SystemPollingClock())
    }

    /// A source reading `reader`, pausing `refreshInterval()` seconds between requests — read
    /// afresh each time — on the real clocks.
    public convenience init(
        reader: any HelperSnapshotReading,
        refreshInterval: @escaping @MainActor () -> TimeInterval
    ) {
        self.init(reader: reader, observer: nil, refreshInterval: refreshInterval)
    }

    /// A source reading `reader` whose every read is reported to `observer`: the app's lease
    /// driver, in a build with a helper (`AppComposition`).
    convenience init(
        reader: any HelperSnapshotReading,
        observer: HelperSnapshotObserver?,
        refreshInterval: @escaping @MainActor () -> TimeInterval
    ) {
        self.init(
            reader: reader, refreshInterval: refreshInterval, clock: ContinuousClock(),
            pacing: SystemPollingClock(), settling: SystemPollingClock(), observer: observer)
    }

    /// The same source with its clocks named, for the suite: `clock` measures a snapshot's age,
    /// `pacing` waits between requests, and `settling` waits for a changed interval to hold
    /// still. Any clock whose instant is `ContinuousClock`'s will do, so a test can wind one by
    /// hand.
    convenience init<C: Clock>(
        reader: any HelperSnapshotReading,
        refreshInterval: @escaping @MainActor () -> TimeInterval,
        clock: C,
        pacing: any PollingClock,
        settling: any PollingClock = SystemPollingClock(),
        observer: HelperSnapshotObserver? = nil
    ) where C.Instant == ContinuousClock.Instant {
        self.init(
            reading: .helper(reader), observer: observer, refreshInterval: refreshInterval,
            clock: clock, pacing: pacing, settling: settling)
    }

    private init<C: Clock>(
        reading: Reading,
        observer: HelperSnapshotObserver?,
        refreshInterval: @escaping @MainActor () -> TimeInterval,
        clock: C,
        pacing: any PollingClock,
        settling: any PollingClock
    ) where C.Instant == ContinuousClock.Instant {
        self.reading = reading
        self.observer = observer
        self.refreshInterval = refreshInterval
        self.now = { clock.now }
        self.pacing = pacing
        self.settling = settling

        guard case .helper(let reader) = reading else { return }
        let updates = reader.healthUpdates()
        healthWatch = Task { [weak self] in
            for await health in updates {
                self?.observe(health)
            }
        }
    }

    deinit {
        healthWatch?.cancel()
    }

    /// The refresh interval as it stands now, clamped as `PollingViewModel` clamps its own.
    private var interval: TimeInterval {
        let value = refreshInterval()
        return value.isFinite
            ? max(value, PollingViewModel.minimumRefreshInterval)
            : PollingViewModel.minimumRefreshInterval
    }

    /// How long after its arrival a snapshot may be rendered:
    /// `refreshInterval + HelperClientDeadlines.gatedVerb`, at the interval as it stands now.
    var freshnessBound: Duration {
        .seconds(interval) + HelperClientDeadlines.gatedVerb
    }

    private func observe(_ new: HelperConnectionHealth) {
        if health == .handshaken, new != .handshaken {
            episode &+= 1
        }
        if health != .handshaken, new == .handshaken {
            retireFailureFromBeforeTheHandshake()
        }
        health = new
    }

    /// A handshake has just been heard, and a request that failed before it no longer decides
    /// anything (#501). See this type's documentation.
    ///
    /// Only a failure goes. A reply recorded in this episode came through a handshake of its
    /// own, because `HelperClient.snapshot()` goes through `withHandshakenProxy`, which sends
    /// nothing before a `hello` has succeeded on that connection. A contradiction is such a
    /// reply. A failure needs no handshake at all: a `hello` that went unanswered, or a
    /// connection refused before it was made.
    ///
    /// `HelperClient` publishes `.handshaken` before it sends the `snapshot`, so a failure of the
    /// `snapshot` itself is expected after the handshake is heard. One recorded first would be
    /// retired too, and the source would wait for the next answer rather than read directly.
    private func retireFailureFromBeforeTheHandshake() {
        guard case .failed = latest?.answer else { return }
        latest = nil
    }

    // MARK: - What a consumer may render

    /// Whether the latest snapshot may be rendered now, whether the SMC may be read instead,
    /// and why.
    ///
    /// In this order: no helper to read; a connection that is not `.handshaken` (`.idle`
    /// waits, every other state reads directly); no answer in this episode, where a failure
    /// from before the handshake is none (waits); a failed or self-contradicting answer
    /// (reads directly); an answer older than `freshnessBound` (waits — the connection is
    /// handshaken, so the next answer is due). Only past all of them is a snapshot `.fresh`.
    /// The age is read here, on this object's own clock, against the instant this object
    /// stamped when the reply arrived.
    public func authority() -> Authority {
        if case .none(let why) = reading { return .readDirectly(why) }
        guard health == .handshaken else {
            let why = ControlNotTracked.helperConnection(health)
            return health == .idle ? .awaitHelper(why) : .readDirectly(why)
        }
        guard let latest, latest.episode == episode else { return .awaitHelper(.awaitingSnapshot) }
        switch latest.answer {
        case .failed(let detail):
            return .readDirectly(.snapshotRequestFailed(detail: detail))
        case .contradicted(let detail):
            return .readDirectly(.snapshotContradicted(detail: detail))
        case .received(let snapshot, let arrivedAt, let wallClock, let ticket):
            guard arrivedAt.duration(to: now()) < freshnessBound else {
                return .awaitHelper(.snapshotStale)
            }
            return .fresh(snapshot, receivedAt: wallClock, readWith: ticket)
        }
    }

    // MARK: - Consumers

    /// Whether there is a helper to read at all. `false` in a build with no helper and for a
    /// damaged bundle, where `authority()` can only ever say why nothing is tracked — so a
    /// consumer has nothing to watch for (`PollingViewModel` starts no authority watch).
    public var hasReader: Bool {
        if case .helper = reading { return true }
        return false
    }

    /// The refresh interval preference changed. The pause between requests in progress was
    /// measured on the old interval. Once the preference has held still for
    /// `intervalSettleDelay`, that pause is cut short, so the next request goes out then and the
    /// pause after it is the new length. Without this, lowering the interval from 60 s to 1 s
    /// would leave a healthy helper's snapshot stale — and the window waiting, reading nothing —
    /// for most of a minute.
    ///
    /// **Debounced.** Each call starts the wait again, and only a wait that runs its course cuts
    /// the pause. The Settings slider moves in steps of 0.1 s, so a drag is a change per step,
    /// and cutting the pause at each one sent a request per step: #485's probe saw 21 requests
    /// for 20 changes at 60 s. The freshness bound reads the interval live, so it follows each
    /// change at once; only the cut waits for the slider to rest.
    ///
    /// **It cuts any pause, a backoff's included, and keeps the failure count.** So a failing
    /// helper is asked once more when the cut lands, and if that request fails as well, the
    /// pause after it is the backoff's next step, on the new interval. `retrySoon()`, by
    /// contrast, cuts only a backoff and starts the count again.
    ///
    /// Like `retrySoon()`, it cuts only a pause: a request in flight is left alone, and no
    /// second one is sent beside it (#419). A cut that lands while a request is in flight finds
    /// no pause, and the pause after that request is already the new length. But a request
    /// answered inside the wait leaves a pause that began on the new length, and the cut ends
    /// that pause anyway: one request goes out at once, a pause sooner than the new interval
    /// asks for.
    public func refreshIntervalDidChange() {
        intervalSettle?.cancel()
        let settling = settling
        intervalSettle = Task { [weak self] in
            do {
                try await settling.sleep(seconds: Self.intervalSettleDelay)
            } catch {
                return
            }
            // A later change cancelled this wait after it ended, before it got here.
            guard !Task.isCancelled, let self else { return }
            self.intervalSettle = nil
            self.intervalHasSettled()
        }
    }

    /// The interval has held still: the pause under way, measured on an older interval, ends now.
    /// See `refreshIntervalDidChange()`.
    private func intervalHasSettled() {
        pause?.cancel()
    }

    /// One more consumer wants snapshots. The first starts the request loop, unless one is
    /// still finishing a request from before the last `stop()` — then that loop carries on,
    /// and no second request is sent.
    public func start() {
        demand += 1
        guard case .helper(let reader) = reading, loop == nil else { return }
        loop = Task { await self.run(reader) }
    }

    /// One fewer consumer wants snapshots. When none does, the pause between requests is cut
    /// short and the loop ends — after the request it is waiting for, if any, is answered.
    /// Never cancels that request: see this type's documentation. A `stop()` with no consumer
    /// left does nothing, so one consumer stopping twice cannot take another's place away.
    public func stop() {
        guard demand > 0 else { return }
        demand -= 1
        guard demand == 0 else { return }
        pause?.cancel()
    }

    /// The user has just done something that may have changed the helper's answer: approved
    /// it, or come back to the app. A **backoff** pause ends now and the next request goes out
    /// at once; the failure count starts again. An ordinary pause, after an answer, is left
    /// alone — the app becomes active all the time, and a healthy helper is not polled faster
    /// for it. A request already in flight is left alone, and no second one is sent beside
    /// it — only a pause is ever cut short.
    public func retrySoon() {
        guard consecutiveFailures > 0 else { return }
        consecutiveFailures = 0
        pause?.cancel()
    }

    private func run(_ reader: any HelperSnapshotReading) async {
        while demand > 0 {
            // The driver's ticket, taken before the request's task exists (#479): a ticket taken
            // after the send would be younger than the read it vouches for. It is kept beside this
            // read's reply, and only this read's (ADR 0015 D2).
            let read = await observer?.readWillBeSent()
            guard demand > 0 else { break }
            let sentIn = episode
            // Unstructured, so that it inherits no cancellation from this loop.
            let request = Task { try await reader.snapshot() }
            outstanding = request
            let result = await request.result
            outstanding = nil
            record(result, sentIn: sentIn, ticket: read?.ticket)
            if let read, case .success(let snapshot) = result {
                await read.judgement(snapshot)
            }

            guard demand > 0 else { break }
            // `readSoon()` found no pause to cut during this cycle: skip the one after it, once,
            // unless the cycle failed and a backoff has begun.
            if readOwed, consecutiveFailures == 0 {
                readOwed = false
                continue
            }
            readOwed = false
            let pacing = pacing
            let wait = nextPause()
            // A cancelled pause throws, and that is simply the pause ending early.
            let pause = Task { _ = try? await pacing.sleep(seconds: wait) }
            self.pause = pause
            await pause.value
            self.pause = nil
        }
        readOwed = false
        loop = nil
    }

    /// Stores one answer with the episode its request was sent in and the ticket taken before it
    /// was sent. A reply is stamped here, on arrival, with this object's own clock.
    private func record(
        _ result: Result<SystemSnapshot, any Error>, sentIn: UInt64,
        ticket: LeaseDriver.SnapshotTicket?
    ) {
        switch result {
        case .success(let snapshot):
            if let contradiction = Self.contradiction(in: snapshot) {
                latest = (.contradicted(detail: contradiction), sentIn)
                consecutiveFailures += 1
            } else {
                latest = (
                    .received(snapshot, arrivedAt: now(), wallClock: Date(), ticket: ticket),
                    sentIn
                )
                consecutiveFailures = 0
            }
        case .failure(let error):
            let description = (error as? any LocalizedError)?.errorDescription
            let detail = HelperAuthoredText.sanitised(description ?? String(describing: error))
            latest = (.failed(detail: detail), sentIn)
            consecutiveFailures += 1
        }
    }

    private func nextPause() -> TimeInterval {
        let interval = interval
        guard consecutiveFailures > 0 else { return interval }
        let doubled = interval * pow(2, Double(min(consecutiveFailures, 16)))
        return max(interval, min(doubled, Self.retryCeiling))
    }

    /// Why a reply contradicts itself, or `nil`. A correct helper builds one entry per
    /// enumerated fan and per sensor key (#474), so a reply that names one twice is not a
    /// failed request but an answer the app refuses: it says two things about one fan or key,
    /// and SwiftUI would draw two rows with one identity.
    private static func contradiction(in snapshot: SystemSnapshot) -> String? {
        var fans: Set<Int> = []
        for fan in snapshot.fans where !fans.insert(fan.index).inserted {
            return "it lists fan \(fan.index) twice"
        }
        var keys: Set<String> = []
        for sample in snapshot.sensors where !keys.insert(sample.key).inserted {
            return "it lists sensor \(HelperAuthoredText.sanitised(sample.key)) twice"
        }
        return nil
    }

    // MARK: - For the suite

    /// Whether a request is outstanding. Read by the suite to show `stop()` left it alone.
    var hasOutstandingRequest: Bool { outstanding != nil }

    /// How many consumers want snapshots. Read by the suite, so an unbalanced `start()` or
    /// `stop()` fails on an assertion rather than as a wait that never ends.
    var consumerCount: Int { demand }

    /// Whether the request loop exists. The suite waits on this with a bounded wait, never on
    /// the loop's task itself, so a loop that never ends is a red and not a hung run.
    var isLoopRunning: Bool { loop != nil }

    /// Whether an interval change is still waiting to hold still. `false` once its cut has been
    /// made, so the suite can wait for the cut rather than for a number of turns.
    var isWaitingForTheIntervalToSettle: Bool { intervalSettle != nil }
}

// MARK: - A read soon after the driver stops acting

extension HelperSnapshotSource {

    /// Something the next snapshot is evidence of has just happened: the lease driver stopped
    /// acting, and Automatic waits for a read ticketed after that (ADR 0015 D2). An **ordinary**
    /// pause ends now, by the cut a settled interval change makes, so the next request goes out at
    /// once.
    ///
    /// - **A request in flight is left alone**, and no second one is sent beside it (#419). Its
    ///   ticket may predate the moment this is about, so the pause after it is skipped instead,
    ///   once: the next request goes out as soon as it is answered. So is the pause after a ticket
    ///   being taken, for the same reason. That holds for a backoff's retry too, so a floor minted
    ///   while the retry is out is read at once when the retry succeeds; if it fails, the backoff's
    ///   next pause runs (`run()` skips only after a cycle that did not fail).
    /// - **A backoff's pause is left alone.** A failing helper is not asked again sooner for it,
    ///   and the failure count is not touched: `retrySoon()` is what ends a backoff.
    /// - **The interval's debounce is untouched.** A wait for the slider to rest goes on, and its
    ///   cut lands as before (`refreshIntervalDidChange()`).
    /// - With no loop running there is nothing to cut: the next `start()` reads at once.
    ///
    /// Called on the main actor by the model that follows the driver's reports
    /// (`LeaseStateModel`), never by the driver: the source holds no reference to it.
    func readSoon() {
        guard loop != nil else { return }
        if let pause {
            guard consecutiveFailures == 0 else { return }
            pause.cancel()
        } else {
            readOwed = true
        }
    }
}
