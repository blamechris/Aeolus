import Combine
import Foundation

/// The observable layer `MenuBarLabelView`/`MenuBarContentView` bind to: a selection of
/// `MenuBarReadout`s, resolved against a live poll, republished every tick.
///
/// ## An independent consumer of `PollingViewModel`, not a shared instance
///
/// `#63`'s issue text describes this and the main window (`#62`) as "independent
/// consumers of the same data layer" once `PollingViewModel`'s shape was fixed by E7.1 —
/// not as two views sharing one running poll. This type therefore owns its own
/// `PollingViewModel` (composition, not injection of a shared singleton): the menu bar's
/// refresh loop starts and stops with the menu bar item's own lifecycle, independently of
/// whether the main window is even open. What the two **do** share is the app's one
/// `HelperSnapshotSource` (#156): while the helper answers, neither reads the SMC and there
/// is one snapshot stream, not two. Only on the direct-read fallback does each run its own
/// `SensorProvider` poll, at the user's refresh interval. Whether two readers are harmless
/// beside the helper's unlock sequence on M3 and later is not known (ADR 0006), which is one
/// more reason the fallback is only a fallback.
///
/// ## Why this reacts to `revision`, not to `fans`/`sensors` directly
///
/// `PollingViewModel.tick()` assigns `fans`, then `sensors`, then (for a successful tick)
/// `lastUpdated`, then finally `phase` — separate `@Published` mutations, each of which
/// publishes to its own subscribers independently and in that order. Subscribing to
/// `$fans.combineLatest($sensors)` would fire once per upstream emission, meaning the
/// *first* combined event of any given tick pairs the just-updated `fans` with the
/// *previous* tick's `sensors` — exactly the kind of half-updated read this project's
/// honesty rules exist to prevent. `revision` moves as the last step of each change
/// `polling` makes — after every `phase` assignment, and after a withdrawal by its authority
/// watch, which changes no phase and would otherwise leave the menu bar showing a claim the
/// window had already taken down — so by the time it reaches `refresh()` below, every other
/// property on `polling` has settled and a direct read (`polling.fans`) is safe.
@MainActor
public final class MenuBarViewModel: ObservableObject {
    @Published public private(set) var readouts: [ResolvedMenuBarReadout] = []
    @Published public private(set) var phase: PollingPhase = .notStarted
    @Published public private(set) var lastUpdated: Date?
    /// Mirrors `PollingViewModel.thermalEmergency`: on, off, or unknown — never a
    /// hardcoded `false`.
    @Published public private(set) var thermalEmergency: ThermalEmergencyState = .unknown
    /// Mirrors `PollingViewModel.controlSource`, so the dropdown says whose report the fans
    /// are, or why nothing is tracked, as the window's fan pane does.
    @Published public private(set) var controlSource: ControlSource = .notTracked(
        .nothingReadYet)
    /// Whether the helper reports **any** fan reclaimed by the system — every fan in the
    /// poll, not only the ones selected as readouts, so a reclamation is never hidden by a
    /// selection that left its fan out.
    @Published public private(set) var isAnyFanReportedReclaimed = false

    private let polling: PollingViewModel
    /// `nil` until either an explicit selection was supplied at `init` or
    /// `MenuBarReadoutSelection.defaultSelection(fans:sensors:)` has run once against real
    /// data — see `refresh()`. Distinct from "selected nothing," which is
    /// `[]` (a user, via `#64`, can deliberately choose to show no readouts; this view
    /// model must not overwrite that choice with a default on the next tick).
    private var selection: [MenuBarReadout]?
    private var cancellables: Set<AnyCancellable> = []

    /// - Parameters:
    ///   - polling: The menu bar's own view model. `AeolusApp` builds it with the real
    ///     catalog (`CatalogSensorLabelSource.loadDefault()`) wired in as its label
    ///     source — matching `#62`'s `MainView` exactly, and not `PollingViewModel`'s own
    ///     `NoSensorLabels()` default: `MenuBarReadoutSelection.defaultSelection`
    ///     specifically prefers catalog-labelled sensors, so a menu bar that never saw a
    ///     label would never demonstrate what that preference is for — and with the app's
    ///     one `HelperSnapshotSource`, which is why there is no default here. A test
    ///     injects a `PollingViewModel` built from a fake `SensorProvider`/`PollingClock`,
    ///     exactly like `PollingViewModel`'s own tests do.
    ///   - selection: An explicit readout selection — e.g. one `#64` previously persisted
    ///     and is restoring. `nil` (the default) means "compute a sensible default from
    ///     the first successful poll," per `MenuBarReadoutSelection`.
    public init(
        polling: PollingViewModel,
        selection: [MenuBarReadout]? = nil
    ) {
        self.polling = polling
        self.selection = selection
        observe()
    }

    /// Starts the underlying poll loop. See `PollingViewModel.start()` — identical
    /// contract, forwarded rather than reimplemented.
    public func start() {
        polling.start()
    }

    /// Stops the underlying poll loop. The owning view is responsible for calling this —
    /// see `PollingViewModel.stop()`.
    public func stop() {
        polling.stop()
    }

    /// The readout selection currently in effect — the default computed from live data,
    /// an explicit selection supplied at `init`, or whatever `setSelection(_:)` last set.
    /// A future preferences screen (`#64`) reads this to seed a picker with the user's
    /// current choice.
    public var currentSelection: [MenuBarReadout] {
        selection ?? []
    }

    /// Replaces the current selection outright — the hook `#64`'s real picker calls once
    /// a user changes what the menu bar shows. `readouts` is recomputed immediately
    /// against whatever `polling` last reported, rather than waiting for the next tick, so
    /// a selection change is reflected at once instead of up to one refresh interval
    /// later. An empty array is a valid, deliberate selection ("show nothing") and is
    /// never replaced by a default on a later tick — see `selection`'s documentation.
    public func setSelection(_ readouts: [MenuBarReadout]) {
        selection = readouts
        self.readouts = readouts.map { $0.resolve(fans: polling.fans, sensors: polling.sensors) }
    }

    private func observe() {
        polling.$revision
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    /// Runs on every `PollingViewModel.revision` — each phase transition, success, failure or
    /// the transient `.polling` alike, and each withdrawal of claims — so `phase`/
    /// `lastUpdated`/`thermalEmergency`/`controlSource` here always mirror `polling`'s exactly,
    /// and `readouts` is recomputed from whatever `polling.fans`/`.sensors` currently hold. A
    /// failed tick leaves those two untouched (`PollingViewModel.tick()`'s own contract), so
    /// this naturally keeps showing the last known good values alongside the honest `.failed`
    /// phase, the same behaviour `PollingViewModel` gives every other consumer.
    private func refresh() {
        self.phase = polling.phase
        self.lastUpdated = polling.lastUpdated
        self.thermalEmergency = polling.thermalEmergency
        self.controlSource = polling.controlSource
        self.isAnyFanReportedReclaimed = polling.fans.contains { $0.control.reportsReclamation }

        let fans = polling.fans
        let sensors = polling.sensors
        if selection == nil, !fans.isEmpty || !sensors.isEmpty {
            selection = MenuBarReadoutSelection.defaultSelection(fans: fans, sensors: sensors)
        }
        readouts = (selection ?? []).map { $0.resolve(fans: fans, sensors: sensors) }
    }
}
