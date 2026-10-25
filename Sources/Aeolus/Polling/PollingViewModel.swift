import AeolusXPC
import Combine
import Foundation
import SMCCore

/// The observable layer the app's views bind to: live fan and sensor readings on a refresh
/// cadence, and every control claim with the source it came from.
///
/// ## Two sources, one at a time
///
/// Each tick asks the app's one `HelperSnapshotSource` what may be rendered
/// ([ADR 0006](../../../docs/ADR/0006-single-smc-reader.md)):
///
/// - **A fresh helper snapshot.** Fans, sensors, the lease and the thermal emergency all come
///   from that one snapshot, and this view model reads **nothing** from the SMC on that tick:
///   one continuous SMC reader per machine, and while the helper answers it is the helper.
/// - **Read directly.** No helper in this build, or one that is refused, mismatched or
///   unreachable: fans and sensors are read from the SMC, as in the `Monitor` build, and every
///   control claim is unknown — each fan is `.notTracked(why)`, `thermalEmergency` is
///   `.unknown`, and `controlSource` says why.
/// - **Await the helper.** Connecting, or handshaken and owed this episode's first snapshot, or
///   its last answer in this episode has outlived its bound: every claim is unknown as above,
///   and **nothing** is read; `phase` is `.waitingForHelper`.
///
/// The last two withdraw every claim **before** anything else, so a tick whose direct read then
/// fails still leaves no claim on screen from a snapshot that may no longer be rendered.
/// Observations from that snapshot (an RPM, a temperature) may stay up with the failure noted;
/// the claims beside them may not.
///
/// ## The screen follows the source within a second, whatever the refresh interval
///
/// The refresh interval can be a minute. Long before the next tick, the snapshot on screen can
/// lose its licence — the helper stops answering, the helper is replaced, the bound runs out —
/// and the source can already hold a newer one. So a second loop, the **authority watch**, asks
/// the source every `authorityWatchInterval` seconds what may be rendered, and judges that
/// against **the snapshot on screen**, not merely against the source's newest answer:
///
/// - The source licenses a snapshot that is not the one on screen: the watch renders it. That
///   takes down the older snapshot's claims with it, and shows a first snapshot without waiting
///   for a tick.
/// - The source licenses nothing, and a snapshot's claims are on screen: the watch withdraws
///   them.
///
/// It never reads the SMC; it renders only what the source already holds. It does not render
/// while this view model's current loop is reading the SMC, because that read would land on the
/// render with readings that carry no claims; it renders at its first step after the read
/// lands. So "within a second" holds except during a direct read, and then a newer snapshot
/// follows within one step of the read's end. A read begun by a loop `stop()` cancelled does not
/// hold the watch back, and is discarded when it lands, so it can never land beneath a snapshot
/// rendered after it began (#485 S1; see `directRead`).
///
/// It does not run in a build with no helper, where the source can never license anything. A
/// separate loop rather than a shorter tick, because the tick's cadence is the user's and costs
/// SMC reads on the direct path, and the watch's costs nothing. A source that published every
/// change would need a timer for expiry anyway, which is this loop by another name.
///
/// ## Refresh design
///
/// `start()` runs an unbounded loop: poll once, publish the result, sleep
/// `refreshInterval` (via the injectable `PollingClock`), repeat until `stop()` cancels it.
/// Each direct read is `PollingEngine.poll(provider:labelSource:discovery:untracked:now:)` —
/// fans are always read via a targeted `SensorProvider.read(keys:)` subset (never
/// `readAll()`); sensors are discovered once via a single `readAll()` on the first successful
/// direct tick and refreshed via subset reads on every direct tick after. See
/// `PollingEngine`, `FanPoller`, and `SensorPoller` for why.
///
/// Cancelling this loop is safe because it awaits no XPC message: the snapshot request belongs
/// to the shared source, which never cancels one (#419). `start()` and `stop()` tell the source
/// that one more, or one fewer, consumer wants snapshots.
///
/// A single failed direct read — a momentarily unavailable connection, a transient SMC error
/// — does not stop the loop and does not clear `fans`/`sensors`: `phase` changes to
/// `.failed`, so a bound view can show the last readings alongside an honest note that the
/// last refresh did not succeed, rather than a blank screen or (worse) values frozen
/// mid-update with no indication anything is stale. This is a long-running UI process, not
/// a one-shot CLI invocation — `fanctl watch` is allowed to end the whole command on one
/// bad tick (`WatchCommand.run`'s documented behaviour); an app window is not.
///
/// ## Concurrency
///
/// `@MainActor`, `ObservableObject`: every published property is safe to read and bind
/// from SwiftUI without further synchronization. The loop's own `Task` inherits that
/// isolation, but never *blocks* the main actor: every SMC read crosses into
/// `SMCConnection`, an `actor`, so the synchronous, timeout-less `IOConnectCallStructMethod`
/// call inside it always runs on that actor's own executor while the main actor is merely
/// suspended awaiting the result, free to process other work (user input, layout, other
/// `@Published` updates) in the meantime.
@MainActor
public final class PollingViewModel: ObservableObject {
    /// The smallest refresh interval this view model accepts — see `init`'s documentation.
    ///
    /// `nonisolated`: this is a compile-time constant, not instance state, and
    /// `Preferences`/`PreferencesRefreshInterval` (`#64`) read it from a plain,
    /// non-actor-isolated context so the same number backs both this view model's own
    /// floor and the preference bound a user configures — see that type's documentation
    /// for why they are deliberately the same value rather than two numbers that could
    /// drift apart.
    nonisolated public static let minimumRefreshInterval: TimeInterval = 0.1

    @Published public private(set) var fans: [FanPollingReading] = []
    @Published public private(set) var sensors: [SensorPollingReading] = []
    @Published public private(set) var phase: PollingPhase = .notStarted {
        didSet { revision &+= 1 }
    }
    /// When `fans`/`sensors` were last successfully refreshed: the end of a direct read, or
    /// the arrival of the helper snapshot they came from. `nil` until the first successful
    /// tick — never backdated to `Date()` at construction, which would let a view show a
    /// plausible-looking "last updated just now" before anything was actually read.
    @Published public private(set) var lastUpdated: Date?

    /// Whether the helper reports a thermal emergency. `.unknown` unless a fresh snapshot is on
    /// screen — never a hardcoded `false`. See `ThermalEmergencyState`.
    @Published public private(set) var thermalEmergency: ThermalEmergencyState = .unknown

    /// Where the control facts on screen came from, for the whole machine.
    @Published public private(set) var controlSource: ControlSource = .notTracked(.nothingReadYet)

    /// Moves as the last step of every change a consumer must see whole: each `phase`
    /// assignment, and each withdrawal the authority watch makes, which changes no phase. A
    /// consumer that reads several properties together (`MenuBarViewModel`) subscribes to this
    /// rather than to any one of them.
    @Published public private(set) var revision: UInt64 = 0

    /// How often the authority watch asks what may be on screen: half a second, so a claim is
    /// withdrawn, and a newer snapshot shown, within a second whatever the refresh interval —
    /// except that a newer snapshot waits for a direct read in progress, and is shown at the
    /// first step after it lands. See this type's documentation.
    nonisolated public static let authorityWatchInterval: TimeInterval = 0.5

    private let provider: any SensorProvider
    private let labelSource: any SensorLabelSource
    private let clock: any PollingClock
    private let authorityWatchClock: any PollingClock
    private let refreshInterval: TimeInterval
    private let snapshots: HelperSnapshotSource

    private var discoveredSensors: [DiscoveredSensor] = []
    private var loopTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    /// The snapshot on screen and when its reply arrived — what the authority watch judges the
    /// source's licence against. `nil` whenever no snapshot's claims are on screen.
    private var rendered: (snapshot: SystemSnapshot, receivedAt: Date)?

    /// The snapshot whose claims are on screen, or `nil` when none are: what
    /// `FanControlPresentation` judges a lease against. `render` assigns it after `fans`,
    /// `thermalEmergency` and `controlSource`, so a sink on any of those sees the previous
    /// snapshot here.
    ///
    /// Get-only and computed, so it is a plain `KeyPath` and nothing outside this type can write
    /// the snapshot on screen; not `private(set) var`, whose key path a dynamic cast can still make
    /// writable (SR-5218). `internal`, because nothing outside this module reads it.
    var renderedSnapshot: SystemSnapshot? { rendered?.snapshot }

    /// The direct read whose results may still go on screen: the one the current refresh loop's
    /// tick is awaiting, or `nil` when there is none. Each read takes a new token, and `stop()`
    /// clears it, so a read begun by a loop `stop()` cancelled is discarded when it lands, and
    /// changes nothing on screen (#485 S1). While it is set, the authority watch renders nothing,
    /// because the current loop's read would land on the render; the watch renders at its first
    /// step after that read lands.
    ///
    /// That also discards every read that lands after a render. A snapshot is rendered in two
    /// places: a tick's `.fresh` arm, and the watch. Outside the suite, only the refresh loop
    /// calls `tick()`, and a loop runs one tick at a time, so its render cannot overtake its own
    /// read; and the watch holds back while this is set. So a render begins while a read is
    /// outstanding only once `stop()` has cancelled the loop that began that read, and that read
    /// is no longer this one.
    ///
    /// A token rather than a count of reads in flight, the issue's other fix: a count would hold
    /// back the watch, but a tick of the new loop could still render while the stopped loop's
    /// read was in flight, and that read would land on the render.
    private var directRead: UInt64?
    /// How many direct reads this view model has begun: where each read's token comes from.
    private var directReadsBegun: UInt64 = 0

    /// How many refresh loops' tasks are still running. More than one only after `stop()` then
    /// `start()` while the stopped loop's tick is still suspended: `stop()` cancels a loop, and
    /// the loop looks at that only once its tick has returned (`start()`), so a tick suspended in
    /// a direct read keeps its loop running until the read ends. `internal`, for the suite: a
    /// bounded wait on this replaces awaiting a loop's task, which no cancellation can interrupt,
    /// so a loop that never ends is a red and never a run that does not exit. A count rather than
    /// a flag, so the stopped loop ending cannot report that the running one has ended (#485).
    private(set) var runningRefreshLoops = 0

    /// Whether any refresh loop's task is still running. See `runningRefreshLoops`.
    var isRefreshLoopRunning: Bool { runningRefreshLoops > 0 }

    /// - Parameters:
    ///   - provider: Where direct readings come from. Defaults to the real SMC — a fake is
    ///     injected in tests.
    ///   - labelSource: Optional catalog decoration — see `SensorLabelSource`'s
    ///     documentation for why this must default to `NoSensorLabels()` and stay fully
    ///     functional without a catalog wired in.
    ///   - clock: How the loop waits between ticks — injectable so tests never wait on
    ///     the wall clock, matching `fanctl watch`'s `WatchClock` seam.
    ///   - refreshInterval: Seconds between ticks. Clamped to `minimumRefreshInterval`
    ///     rather than accepted as-is: an interval of `0` (or a negative value, from a
    ///     future settings surface that does not yet validate its own input) would turn
    ///     this into a busy loop hammering the SMC, not a 1 Hz monitor.
    ///   - snapshots: The app's one helper snapshot source. Required, with no default, so
    ///     that a view model nobody wired cannot quietly become a second SMC reader beside a
    ///     healthy helper.
    ///   - authorityWatchClock: How the authority watch waits — injectable for the same reason
    ///     as `clock`, and separate from it so a suite can hold one still and move the other.
    public init(
        provider: some SensorProvider = SMCSensorProvider(),
        labelSource: some SensorLabelSource = NoSensorLabels(),
        clock: some PollingClock = SystemPollingClock(),
        refreshInterval: TimeInterval = 1,
        snapshots: HelperSnapshotSource,
        authorityWatchClock: some PollingClock = SystemPollingClock()
    ) {
        self.provider = provider
        self.labelSource = labelSource
        self.clock = clock
        self.authorityWatchClock = authorityWatchClock
        self.refreshInterval =
            refreshInterval.isFinite
            ? max(refreshInterval, Self.minimumRefreshInterval)
            : Self.minimumRefreshInterval
        self.snapshots = snapshots
    }

    /// Starts the refresh loop. Safe to call more than once — a second call while a loop
    /// is already running is a no-op rather than starting a second, competing loop.
    ///
    /// The owning view is responsible for calling `stop()` (typically from `.onDisappear`
    /// or an equivalent lifecycle hook) once this view model is no longer shown: the loop
    /// captures `self` only weakly, and only for the span of each `tick()` call — `clock`
    /// and `refreshInterval` are captured by value below, independently of `self`, so
    /// nothing about the wait between ticks requires `self` to still exist. That means the
    /// loop cannot itself keep this instance alive past its last external strong
    /// reference, but it also will not stop polling on its own once started — an explicit
    /// `stop()` is what releases the underlying `SensorProvider` connection and ends the
    /// SMC traffic for good.
    public func start() {
        guard loopTask == nil else { return }
        snapshots.start()
        if snapshots.hasReader { startAuthorityWatch() }
        let clock = clock
        let interval = refreshInterval
        runningRefreshLoops += 1
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                if Task.isCancelled { break }
                do {
                    try await clock.sleep(seconds: interval)
                } catch {
                    // CancellationError, or any other error a test double's clock might
                    // raise to simulate one — either way, a clean stop, not a crash.
                    break
                }
            }
            self?.runningRefreshLoops -= 1
        }
    }

    /// Cancels the refresh loop and the authority watch, and tells the snapshot source this
    /// consumer is gone — once, however often this is called, so a view whose `onDisappear`
    /// fires twice cannot take another consumer's place at the source away.
    /// `fans`/`sensors`/`lastUpdated` are left exactly as they were on the last successful
    /// tick — stopping is not the same as losing the last known reading. A direct read the
    /// cancelled loop is still awaiting is discarded when it lands (`directRead`).
    public func stop() {
        guard let loopTask else { return }
        loopTask.cancel()
        self.loopTask = nil
        directRead = nil
        watchTask?.cancel()
        watchTask = nil
        snapshots.stop()
    }

    private func startAuthorityWatch() {
        let watchClock = authorityWatchClock
        let interval = Self.authorityWatchInterval
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await watchClock.sleep(seconds: interval)
                } catch {
                    return
                }
                guard let self else { return }
                self.reassessAuthority()
            }
        }
    }

    /// The authority watch's one step, judged against the snapshot on screen: render a licensed
    /// snapshot that is not the one shown; withdraw the claims of a snapshot no longer licensed.
    /// Never reads the SMC. See this type's documentation.
    ///
    /// `internal`, for the suite, which drives it through a held clock rather than by calling it.
    func reassessAuthority() {
        switch snapshots.authority() {
        case .fresh(let snapshot, let receivedAt):
            guard directRead == nil else { return }
            if let rendered, rendered.receivedAt == receivedAt, rendered.snapshot == snapshot {
                return
            }
            render(snapshot, receivedAt: receivedAt)
        case .readDirectly(let why), .awaitHelper(let why):
            guard case .helperSnapshot = controlSource else { return }
            withdrawControlClaims(why)
            revision &+= 1
        }
    }

    /// Runs exactly one poll cycle and publishes the result.
    ///
    /// `internal`, not `private`: `Tests/AeolusUITests/PollingViewModelTests.swift` drives
    /// this directly to assert on individual ticks deterministically, without depending on
    /// the timer loop's `Task`/`PollingClock` machinery at all — the same reason
    /// `ListCommand.fetch`/`WatchCommand.run` are exposed as directly callable functions
    /// rather than only reachable through `Fanctl.List`/`Fanctl.Watch`'s command wiring.
    func tick() async {
        switch snapshots.authority() {
        case .fresh(let snapshot, let receivedAt):
            render(snapshot, receivedAt: receivedAt)
        case .awaitHelper(let why):
            withdrawControlClaims(why)
            phase = .waitingForHelper
        case .readDirectly(let why):
            withdrawControlClaims(why)
            phase = .polling
            directReadsBegun &+= 1
            let read = directReadsBegun
            directRead = read
            let outcome = await readDirectly(untracked: why)
            // Begun by a loop `stop()` cancelled: discarded. See `directRead`.
            guard directRead == read else { return }
            directRead = nil
            show(outcome)
        }
    }

    /// Puts one snapshot on screen: fans, sensors, the emergency and the lease, all from it.
    private func render(_ snapshot: SystemSnapshot, receivedAt: Date) {
        phase = .polling
        fans = SnapshotReadings.fans(in: snapshot)
        sensors = SnapshotReadings.sensors(in: snapshot, labelSource: labelSource)
        thermalEmergency = snapshot.isThermalEmergencyActive ? .active : .inactive
        controlSource = .helperSnapshot(activeLease: snapshot.activeLease)
        lastUpdated = receivedAt
        rendered = (snapshot, receivedAt)
        phase = .ready
    }

    /// Every control claim on screen becomes unknown, before anything is read: see this
    /// type's documentation.
    private func withdrawControlClaims(_ why: ControlNotTracked) {
        fans = fans.map { $0.untracked(why) }
        thermalEmergency = .unknown
        controlSource = .notTracked(why)
        rendered = nil
    }

    /// One direct read, not yet on screen: `tick()` decides whether it may be shown.
    private func readDirectly(
        untracked why: ControlNotTracked
    ) async -> Result<PollingEngine.Snapshot, PollingError> {
        do {
            return .success(
                try await PollingEngine.poll(
                    provider: provider, labelSource: labelSource, discovery: discoveredSensors,
                    untracked: why))
        } catch let error as PollingError {
            return .failure(error)
        } catch {
            return .failure(.readFailed(context: "poll", reason: String(describing: error)))
        }
    }

    /// Puts one direct read on screen.
    private func show(_ outcome: Result<PollingEngine.Snapshot, PollingError>) {
        switch outcome {
        case .success(let snapshot):
            fans = snapshot.fans
            sensors = snapshot.sensors
            discoveredSensors = snapshot.discovery
            lastUpdated = snapshot.capturedAt
            phase = .ready
        case .failure(let error):
            // fans/sensors/lastUpdated are deliberately untouched here — see this type's
            // top-level "Refresh design" section for why a transient failure must not
            // erase a reading a view is already showing.
            phase = .failed(error)
        }
    }
}
