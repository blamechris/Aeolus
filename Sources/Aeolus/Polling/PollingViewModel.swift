import Combine
import Foundation
import SMCCore

/// The observable layer the app's views (`#62`/`#63`) bind to: live fan and sensor
/// readings on a refresh cadence, plus the honesty flags `CLAUDE.md` rule 6 requires be
/// modelled even before there is anything real to report.
///
/// ## Why the honesty flags are hardcoded here, not omitted
///
/// Under the `Monitor` build configuration there is no helper, no XPC client, and no
/// write path — E2 (the XPC client), E3/E4 (the write path), and E5 (the safety
/// supervisor that owns leases and reclamation) are all unstarted. `isThermalEmergencyActive`
/// below, and `FanPollingReading.mode`/`isReclaimedBySystem` on every fan this view model
/// publishes, are therefore *definitionally* always the safe value: nothing here has ever
/// asked for manual control, so nothing can be reclaimed, and no helper-owned thermal
/// supervisor exists yet to declare an emergency. These fields are carried explicitly
/// anyway, sourced locally and pinned to that safe value, rather than left out until E2/E5
/// land: when a real `AeolusXPC.SystemSnapshot` becomes available, the code that swaps
/// `PollingViewModel` for an XPC-backed equivalent only has to change *where* these values
/// come from, not add fields to every view that already renders a fan or a thermal state.
///
/// ## Refresh design
///
/// `start()` runs an unbounded loop: poll once, publish the result, sleep
/// `refreshInterval` (via the injectable `PollingClock`), repeat until `stop()` cancels it.
/// Each poll is `PollingEngine.poll(provider:labelSource:discovery:now:)` — fans are
/// always read via a targeted `SensorProvider.read(keys:)` subset (never `readAll()`);
/// sensors are discovered once via a single `readAll()` on the first successful tick and
/// refreshed via subset reads on every tick after. See `PollingEngine`, `FanPoller`, and
/// `SensorPoller` for why.
///
/// A single failed tick — a momentarily unavailable connection, a transient SMC error —
/// does not stop the loop and does not clear `fans`/`sensors`: only `phase` changes, to
/// `.failed`, so a bound view can show "still working" data alongside an honest note that
/// the last refresh did not succeed, rather than a blank screen or (worse) values frozen
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
    public static let minimumRefreshInterval: TimeInterval = 0.1

    @Published public private(set) var fans: [FanPollingReading] = []
    @Published public private(set) var sensors: [SensorPollingReading] = []
    @Published public private(set) var phase: PollingPhase = .notStarted
    /// When `fans`/`sensors` were last successfully refreshed. `nil` until the first
    /// successful tick — never backdated to `Date()` at construction, which would let a
    /// view show a plausible-looking "last updated just now" before anything was actually
    /// read.
    @Published public private(set) var lastUpdated: Date?

    /// See this type's top-level documentation for why this is hardcoded rather than
    /// omitted.
    @Published public private(set) var isThermalEmergencyActive = false

    private let provider: any SensorProvider
    private let labelSource: any SensorLabelSource
    private let clock: any PollingClock
    private let refreshInterval: TimeInterval

    private var discoveredSensors: [DiscoveredSensor] = []
    private var loopTask: Task<Void, Never>?

    /// - Parameters:
    ///   - provider: Where readings come from. Defaults to the real SMC — a fake is
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
    public init(
        provider: some SensorProvider = SMCSensorProvider(),
        labelSource: some SensorLabelSource = NoSensorLabels(),
        clock: some PollingClock = SystemPollingClock(),
        refreshInterval: TimeInterval = 1
    ) {
        self.provider = provider
        self.labelSource = labelSource
        self.clock = clock
        self.refreshInterval =
            refreshInterval.isFinite
            ? max(refreshInterval, Self.minimumRefreshInterval)
            : Self.minimumRefreshInterval
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
        let clock = clock
        let interval = refreshInterval
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                if Task.isCancelled { return }
                do {
                    try await clock.sleep(seconds: interval)
                } catch {
                    // CancellationError, or any other error a test double's clock might
                    // raise to simulate one — either way, a clean stop, not a crash.
                    return
                }
            }
        }
    }

    /// Cancels the refresh loop. `fans`/`sensors`/`lastUpdated` are left exactly as they
    /// were on the last successful tick — stopping is not the same as losing the last
    /// known reading.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Awaits the refresh loop's underlying `Task` until it finishes on its own — e.g.
    /// because an injected `PollingClock` was scripted to cancel it after a fixed number
    /// of ticks. `internal`, not `private`, and used only by
    /// `Tests/AeolusUITests/PollingViewModelTests.swift`: it is the deterministic way to
    /// know a `FakePollingClock`-driven loop has run every scripted tick before making
    /// assertions, rather than guessing with a real sleep in the test.
    func waitUntilLoopFinishes() async {
        await loopTask?.value
    }

    /// Runs exactly one poll cycle and publishes the result.
    ///
    /// `internal`, not `private`: `Tests/AeolusUITests/PollingViewModelTests.swift` drives
    /// this directly to assert on individual ticks deterministically, without depending on
    /// the timer loop's `Task`/`PollingClock` machinery at all — the same reason
    /// `ListCommand.fetch`/`WatchCommand.run` are exposed as directly callable functions
    /// rather than only reachable through `Fanctl.List`/`Fanctl.Watch`'s command wiring.
    func tick() async {
        phase = .polling
        do {
            let snapshot = try await PollingEngine.poll(
                provider: provider, labelSource: labelSource, discovery: discoveredSensors)
            fans = snapshot.fans
            sensors = snapshot.sensors
            discoveredSensors = snapshot.discovery
            lastUpdated = snapshot.capturedAt
            phase = .ready
        } catch let error as PollingError {
            // fans/sensors/lastUpdated are deliberately untouched here — see this type's
            // top-level "Refresh design" section for why a transient failure must not
            // erase a reading a view is already showing.
            phase = .failed(error)
        } catch {
            phase = .failed(.readFailed(context: "poll", reason: String(describing: error)))
        }
    }
}
