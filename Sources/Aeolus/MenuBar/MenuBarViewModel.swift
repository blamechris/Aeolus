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
/// whether the main window is even open. The cost is a second 1 Hz `SensorProvider` poll
/// running alongside the window's; the alternative — threading one `PollingViewModel`
/// instance through both `#62`'s and `#63`'s independently-developed view trees — is
/// exactly the coupling "independent consumers" was written to avoid. Both readers are
/// read-only, so nothing about running two is unsafe, only slightly redundant, and
/// nothing here prevents a later refactor to share one instance if that redundancy turns
/// out to matter.
///
/// ## Why this reacts to `phase`, not to `fans`/`sensors` directly
///
/// `PollingViewModel.tick()` assigns `fans`, then `sensors`, then (for a successful tick)
/// `lastUpdated`, then finally `phase = .ready` — four separate `@Published` mutations,
/// each of which publishes to its own subscribers independently and in that order.
/// Subscribing to `$fans.combineLatest($sensors)` would fire once per upstream emission,
/// meaning the *first* combined event of any given tick pairs the just-updated `fans`
/// with the *previous* tick's `sensors` — exactly the kind of half-updated read this
/// project's honesty rules exist to prevent. `phase` is always the last thing `tick()`
/// sets, so by the time a `$phase` change reaches `handle(phase:)` below, every other
/// `@Published` property on `polling` has already finished settling and a direct property
/// read (`polling.fans`, not a value captured from a `combineLatest` payload) is safe.
@MainActor
public final class MenuBarViewModel: ObservableObject {
    @Published public private(set) var readouts: [ResolvedMenuBarReadout] = []
    @Published public private(set) var phase: PollingPhase = .notStarted
    @Published public private(set) var lastUpdated: Date?
    /// Mirrors `PollingViewModel.isThermalEmergencyActive` — see that property's
    /// documentation for why it is hardcoded `false` under `Monitor` and carried through
    /// regardless.
    @Published public private(set) var isThermalEmergencyActive = false

    private let polling: PollingViewModel
    /// `nil` until either an explicit selection was supplied at `init` or
    /// `MenuBarReadoutSelection.defaultSelection(fans:sensors:)` has run once against real
    /// data — see `handle(phase:)`. Distinct from "selected nothing," which is
    /// `[]` (a user, via `#64`, can deliberately choose to show no readouts; this view
    /// model must not overwrite that choice with a default on the next tick).
    private var selection: [MenuBarReadout]?
    private var cancellables: Set<AnyCancellable> = []

    /// - Parameters:
    ///   - polling: Defaults to a real `SMCSensorProvider`-backed instance; a test injects
    ///     one built from a fake `SensorProvider`/`PollingClock`, exactly like
    ///     `PollingViewModel`'s own tests do.
    ///   - selection: An explicit readout selection — e.g. one `#64` previously persisted
    ///     and is restoring. `nil` (the default) means "compute a sensible default from
    ///     the first successful poll," per `MenuBarReadoutSelection`.
    public init(
        polling: PollingViewModel = PollingViewModel(),
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
        polling.$phase
            .sink { [weak self] phase in
                self?.handle(phase: phase)
            }
            .store(in: &cancellables)
    }

    /// Runs on every `PollingViewModel.phase` transition — success, failure, or the
    /// transient `.polling` state alike — so `phase`/`lastUpdated`/
    /// `isThermalEmergencyActive` here always mirror `polling`'s exactly, and `readouts`
    /// is recomputed from whatever `polling.fans`/`.sensors` currently hold. A failed tick
    /// leaves those two untouched (`PollingViewModel.tick()`'s own contract), so this
    /// naturally keeps showing the last known good values alongside the honest `.failed`
    /// phase, the same behaviour `PollingViewModel` gives every other consumer.
    private func handle(phase: PollingPhase) {
        self.phase = phase
        self.lastUpdated = polling.lastUpdated
        self.isThermalEmergencyActive = polling.isThermalEmergencyActive

        let fans = polling.fans
        let sensors = polling.sensors
        if selection == nil, !fans.isEmpty || !sensors.isEmpty {
            selection = MenuBarReadoutSelection.defaultSelection(fans: fans, sensors: sensors)
        }
        readouts = (selection ?? []).map { $0.resolve(fans: fans, sensors: sensors) }
    }
}
