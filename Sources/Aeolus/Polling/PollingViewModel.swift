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
/// - **Anything else.** Fans and sensors are read directly from the SMC, as in the `Monitor`
///   build, and every control claim is unknown: each fan is `.notTracked(why)`,
///   `thermalEmergency` is `.unknown`, and `controlSource` says why.
///
/// The second answer withdraws the first's claims **before** it reads anything, so a tick
/// whose direct read then fails still leaves no claim on screen from a snapshot that may no
/// longer be rendered. Observations from that snapshot (an RPM, a temperature) may stay up
/// with the failure noted; the claims beside them may not.
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
    @Published public private(set) var phase: PollingPhase = .notStarted
    /// When `fans`/`sensors` were last successfully refreshed: the end of a direct read, or
    /// the arrival of the helper snapshot they came from. `nil` until the first successful
    /// tick — never backdated to `Date()` at construction, which would let a view show a
    /// plausible-looking "last updated just now" before anything was actually read.
    @Published public private(set) var lastUpdated: Date?

    /// Whether the helper reports a thermal emergency. `.unknown` unless this tick rendered a
    /// fresh snapshot — never a hardcoded `false`. See `ThermalEmergencyState`.
    @Published public private(set) var thermalEmergency: ThermalEmergencyState = .unknown

    /// Where this tick's control facts came from, for the whole machine.
    @Published public private(set) var controlSource: ControlSource = .notTracked(.nothingReadYet)

    private let provider: any SensorProvider
    private let labelSource: any SensorLabelSource
    private let clock: any PollingClock
    private let refreshInterval: TimeInterval
    private let snapshots: HelperSnapshotSource

    private var discoveredSensors: [DiscoveredSensor] = []
    private var loopTask: Task<Void, Never>?

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
    public init(
        provider: some SensorProvider = SMCSensorProvider(),
        labelSource: some SensorLabelSource = NoSensorLabels(),
        clock: some PollingClock = SystemPollingClock(),
        refreshInterval: TimeInterval = 1,
        snapshots: HelperSnapshotSource
    ) {
        self.provider = provider
        self.labelSource = labelSource
        self.clock = clock
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

    /// Cancels the refresh loop, and tells the snapshot source this consumer is gone.
    /// `fans`/`sensors`/`lastUpdated` are left exactly as they were on the last successful
    /// tick — stopping is not the same as losing the last known reading.
    public func stop() {
        guard let loopTask else { return }
        loopTask.cancel()
        self.loopTask = nil
        snapshots.stop()
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
        switch snapshots.authority() {
        case .fresh(let snapshot, let receivedAt):
            phase = .polling
            fans = SnapshotReadings.fans(in: snapshot)
            sensors = SnapshotReadings.sensors(in: snapshot, labelSource: labelSource)
            thermalEmergency = snapshot.isThermalEmergencyActive ? .active : .inactive
            controlSource = .helperSnapshot(activeLease: snapshot.activeLease)
            lastUpdated = receivedAt
            phase = .ready
        case .notTracked(let why):
            withdrawControlClaims(why)
            phase = .polling
            await readDirectly(untracked: why)
        }
    }

    /// Every control claim on screen becomes unknown, before anything is read: see this
    /// type's documentation.
    private func withdrawControlClaims(_ why: ControlNotTracked) {
        fans = fans.map { $0.untracked(why) }
        thermalEmergency = .unknown
        controlSource = .notTracked(why)
    }

    private func readDirectly(untracked why: ControlNotTracked) async {
        do {
            let snapshot = try await PollingEngine.poll(
                provider: provider, labelSource: labelSource, discovery: discoveredSensors,
                untracked: why)
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
