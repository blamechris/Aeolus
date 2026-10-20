import AeolusXPC
import AeolusXPCClient
import Foundation

/// The app's one reader of helper snapshots, and the judge of whether the last one may still
/// be rendered.
///
/// [ADR 0006](../../../docs/ADR/0006-single-smc-reader.md) is the policy: while the connection
/// is `.handshaken` and the latest snapshot is within its bound, the app renders that snapshot
/// and stops reading the SMC for anything it carries; otherwise it reads directly and every
/// control claim is unknown. `authority()` is that decision, and every `PollingViewModel`
/// asks it once per tick.
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
/// **Nothing here cancels a request.** `stop()` cancels only the pause between requests. A
/// request outstanding at `stop()` is left to finish, and its answer is **kept**: it is a real
/// reply, stamped when it arrived, and the freshness bound decides whether anything may render
/// it later. A `start()` that arrives while it is outstanding does not send another; the loop
/// that sent it carries on once it is answered. Each request also runs in its own unstructured
/// task, so even a cancelled loop could not cancel it.
///
/// That is #419's rule for the read side. `HelperClient` keeps a cancelled caller's sequenced
/// message in flight with its deadline running (`InFlightMessages`), so a view that cancelled
/// and re-sent a `snapshot` behind a wedged `apply` would pile up orphans, each adding a whole
/// deadline before the live read's own began. And **no SwiftUI `.task` owns this await**:
/// SwiftUI cancels a `.task` when its view disappears, which is exactly the cancellation this
/// type exists not to make. Views call `start()` and `stop()`; the loop's task belongs to this
/// object.
///
/// ## Fresh is measured from arrival, on a clock that does not stop in sleep
///
/// A snapshot is fresh for `refreshInterval + HelperClientDeadlines.gatedVerb`, measured from
/// the instant its reply reached this object. The bound is one pause plus one full deadline:
/// if the helper wedges on the next request, `HelperClient` gives up on it at `gatedVerb`, and
/// by then this snapshot has already gone stale rather than outliving the wedge.
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
///
/// ## No client at all in a build with no helper
///
/// `forBundle` builds a `HelperClient` only for a bundle that ships a helper
/// (`HelperEmbedding.embedded`). A `Monitor` build — and a damaged bundle — gets a source with
/// no reader, whose `authority()` always says why nothing is tracked.
@MainActor
public final class HelperSnapshotSource {

    /// What a consumer may render right now.
    public enum Authority: Sendable, Hashable {
        /// A snapshot within its bound on a handshaken connection. `receivedAt` is this
        /// process's wall clock when the reply arrived, for a "last updated" label only.
        case fresh(SystemSnapshot, receivedAt: Date)
        /// Nothing may be claimed about control, and why.
        case notTracked(ControlNotTracked)
    }

    /// The longest pause after failed requests, in seconds. A failure pauses twice
    /// `refreshInterval`, and each further one doubles that, up to here — or to
    /// `refreshInterval` itself if that is longer.
    public static let retryCeiling: TimeInterval = 30

    /// How long after its arrival a snapshot may be rendered:
    /// `refreshInterval + HelperClientDeadlines.gatedVerb`.
    let freshnessBound: Duration

    private enum Reading {
        case none(ControlNotTracked)
        case helper(any HelperSnapshotReading)
    }

    private enum Latest {
        case received(SystemSnapshot, arrivedAt: ContinuousClock.Instant, wallClock: Date)
        case failed(detail: String)
    }

    private let reading: Reading
    private let refreshInterval: TimeInterval
    private let now: @Sendable () -> ContinuousClock.Instant
    private let pacing: any PollingClock

    /// The connection's health as last reported by `healthUpdates()`. `.idle` until the first
    /// report arrives, which licenses nothing.
    private(set) var health: HelperConnectionHealth = .idle

    private var latest: Latest?
    private var consecutiveFailures = 0
    private var demand = 0

    /// The request loop, while one exists. At most one.
    private var loop: Task<Void, Never>?
    /// The request in flight, while one is. Nothing in this type cancels it.
    private var outstanding: Task<SystemSnapshot, any Error>?
    /// The pause between two requests: the only task `stop()` cancels.
    private var pause: Task<Void, Never>?
    private var healthWatch: Task<Void, Never>?

    /// A source for a process with no helper to read: `authority()` is always
    /// `.notTracked(why)`, and `start()`/`stop()` do nothing.
    public convenience init(withoutHelper why: ControlNotTracked) {
        self.init(
            reading: .none(why), refreshInterval: PreferencesRefreshInterval.defaultValue,
            clock: ContinuousClock(), pacing: SystemPollingClock())
    }

    /// A source reading `reader` every `refreshInterval` seconds, on the real clocks.
    public convenience init(reader: any HelperSnapshotReading, refreshInterval: TimeInterval) {
        self.init(
            reader: reader, refreshInterval: refreshInterval, clock: ContinuousClock(),
            pacing: SystemPollingClock())
    }

    /// The same source with its clocks named, for the suite: `clock` measures a snapshot's age
    /// and `pacing` waits between requests. Any clock whose instant is `ContinuousClock`'s will
    /// do, so a test can wind one by hand.
    convenience init<C: Clock>(
        reader: any HelperSnapshotReading,
        refreshInterval: TimeInterval,
        clock: C,
        pacing: any PollingClock
    ) where C.Instant == ContinuousClock.Instant {
        self.init(
            reading: .helper(reader), refreshInterval: refreshInterval, clock: clock,
            pacing: pacing)
    }

    private init<C: Clock>(
        reading: Reading,
        refreshInterval: TimeInterval,
        clock: C,
        pacing: any PollingClock
    ) where C.Instant == ContinuousClock.Instant {
        let interval =
            refreshInterval.isFinite
            ? max(refreshInterval, PollingViewModel.minimumRefreshInterval)
            : PollingViewModel.minimumRefreshInterval
        self.reading = reading
        self.refreshInterval = interval
        self.freshnessBound = .seconds(interval) + HelperClientDeadlines.gatedVerb
        self.now = { clock.now }
        self.pacing = pacing

        guard case .helper(let reader) = reading else { return }
        let updates = reader.healthUpdates()
        healthWatch = Task { [weak self] in
            for await health in updates {
                self?.health = health
            }
        }
    }

    deinit {
        healthWatch?.cancel()
    }

    // MARK: - What a consumer may render

    /// Whether the latest snapshot may be rendered now, and if not, why.
    ///
    /// In this order: no helper to read; a connection that is not `.handshaken`; no answer
    /// yet; a failed answer; an answer older than `freshnessBound`. Only past all five is a
    /// snapshot `.fresh`. The age is read here, on this object's own clock, against the
    /// instant this object stamped when the reply arrived.
    public func authority() -> Authority {
        if case .none(let why) = reading { return .notTracked(why) }
        guard health == .handshaken else { return .notTracked(.helperConnection(health)) }
        switch latest {
        case nil:
            return .notTracked(.awaitingSnapshot)
        case .failed(let detail):
            return .notTracked(.snapshotRequestFailed(detail: detail))
        case .received(let snapshot, let arrivedAt, let wallClock):
            guard arrivedAt.duration(to: now()) < freshnessBound else {
                return .notTracked(.snapshotStale)
            }
            return .fresh(snapshot, receivedAt: wallClock)
        }
    }

    // MARK: - Consumers

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
    /// Never cancels that request: see this type's documentation.
    public func stop() {
        guard demand > 0 else { return }
        demand -= 1
        guard demand == 0 else { return }
        pause?.cancel()
    }

    private func run(_ reader: any HelperSnapshotReading) async {
        while demand > 0 {
            // Unstructured, so that it inherits no cancellation from this loop.
            let request = Task { try await reader.snapshot() }
            outstanding = request
            let result = await request.result
            outstanding = nil
            record(result)

            guard demand > 0 else { break }
            let pacing = pacing
            let wait = nextPause()
            // A cancelled pause throws, and that is simply the pause ending early.
            let pause = Task { _ = try? await pacing.sleep(seconds: wait) }
            self.pause = pause
            await pause.value
            self.pause = nil
        }
        loop = nil
    }

    /// Stores one answer. A reply is stamped here, on arrival, with this object's own clock.
    private func record(_ result: Result<SystemSnapshot, any Error>) {
        switch result {
        case .success(let snapshot):
            if let repeated = Self.repeatedFanIndex(in: snapshot) {
                // A correct helper builds one entry per enumerated fan (#474). A snapshot that
                // names one fan twice contradicts itself about that fan, and SwiftUI would draw
                // two rows with one identity, so none of it is rendered.
                latest = .failed(detail: "the helper's snapshot lists fan \(repeated) twice")
                consecutiveFailures += 1
            } else {
                latest = .received(snapshot, arrivedAt: now(), wallClock: Date())
                consecutiveFailures = 0
            }
        case .failure(let error):
            let description = (error as? any LocalizedError)?.errorDescription
            latest = .failed(
                detail: HelperAuthoredText.sanitised(description ?? String(describing: error)))
            consecutiveFailures += 1
        }
    }

    private func nextPause() -> TimeInterval {
        guard consecutiveFailures > 0 else { return refreshInterval }
        let doubled = refreshInterval * pow(2, Double(min(consecutiveFailures, 16)))
        return max(refreshInterval, min(doubled, Self.retryCeiling))
    }

    private static func repeatedFanIndex(in snapshot: SystemSnapshot) -> Int? {
        var seen: Set<Int> = []
        for fan in snapshot.fans where !seen.insert(fan.index).inserted {
            return fan.index
        }
        return nil
    }

    // MARK: - For the suite

    /// Whether a request is outstanding. Read by the suite to show `stop()` left it alone.
    var hasOutstandingRequest: Bool { outstanding != nil }

    /// Waits for the request loop to end, for a suite that has stopped it.
    func waitUntilIdle() async {
        await loop?.value
    }
}

extension HelperSnapshotSource {

    /// The source for this bundle: a `HelperClient` only when the bundle ships a helper.
    ///
    /// - Parameters:
    ///   - embedding: What the bundle contains (`HelperBundleLayout.embedding`).
    ///   - refreshInterval: Seconds between requests.
    ///   - makeReader: Builds the reader. **Never called** unless `embedding` is `.embedded`:
    ///     a `Monitor` build constructs no client, and so cannot reach the helper's mach name
    ///     even by accident.
    /// - Returns: A source reading the new client, or a source with no reader that says why.
    static func forBundle(
        _ embedding: HelperEmbedding,
        refreshInterval: TimeInterval,
        makeReader: () -> any HelperSnapshotReading
    ) -> HelperSnapshotSource {
        switch embedding {
        case .absent:
            return HelperSnapshotSource(withoutHelper: .noHelperInThisBuild)
        case .incomplete:
            return HelperSnapshotSource(withoutHelper: .helperInstallIncomplete)
        case .embedded:
            return HelperSnapshotSource(reader: makeReader(), refreshInterval: refreshInterval)
        }
    }

    /// The running app's source: its own bundle, and a `HelperClient` on the default
    /// transport and pinning if, and only if, that bundle ships a helper.
    static func forRunningApp(refreshInterval: TimeInterval) -> HelperSnapshotSource {
        forBundle(
            HelperBundleLayout.embedding(inBundleAt: Bundle.main.bundleURL),
            refreshInterval: refreshInterval
        ) {
            HelperClient(clientDescription: clientDescription(of: .main))
        }
    }

    /// What the app calls itself in the helper's log: `Aeolus.app <version>`.
    static func clientDescription(of bundle: Bundle) -> String {
        guard
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            !version.isEmpty
        else { return "Aeolus.app" }
        return "Aeolus.app \(version)"
    }
}
