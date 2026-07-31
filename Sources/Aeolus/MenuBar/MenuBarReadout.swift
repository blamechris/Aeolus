import FanKit
import SMCCore

/// One user-chosen thing to show in the menu bar: a raw SMC key plus which value on that
/// key to render there.
///
/// ## The model E7.4 (Preferences, `#64`) extends
///
/// "Multiple simultaneous readouts, user-chosen" implies persisted selection, but the
/// *choosing* UI belongs to `#64`, not here. This type is deliberately small and
/// `Codable` so `#64` can serialize an ordered `[MenuBarReadout]` (e.g. into
/// `UserDefaults` as JSON) without redesigning anything: adding a picker means producing
/// values of this type from whatever `PollingViewModel.fans`/`.sensors` currently report,
/// nothing more.
///
/// ## Selection is keyed on `key`, never on a label
///
/// `MenuBarViewModel.resolve(against:)` looks a readout up by `key` alone — never by
/// `FanPollingReading.displayName` or `CatalogDecoration.label`. Per `CLAUDE.md`: a wrong
/// label must never be able to quietly mislead someone into showing the wrong sensor. A
/// saved selection surviving a catalog update that relabels (or unlabels) the same key is
/// a feature of this design, not an edge case it forgot.
///
/// ## Why `source` exists at all
///
/// `SensorPoller.discover(provider:)` enumerates every key `SensorProvider.readAll()`
/// reports, including fan keys (`F<n>Ac`/`Mn`/`Mx`) — nothing filters them out before they
/// reach `SensorPollingReading`. The same raw key can therefore legitimately appear in
/// both `PollingViewModel.fans` (as `FanPollingReading.actual.key`, labelled "Fan `<n>`")
/// and `PollingViewModel.sensors` (as a generic, usually-unlabelled `SensorPollingReading`
/// with the same key). `source` is what disambiguates which one a saved readout meant,
/// rather than resolution guessing from where the key happens to appear first.
public struct MenuBarReadout: Sendable, Hashable, Codable, Identifiable {
    /// The raw four-character SMC key this readout tracks. Always present and always
    /// what selection, resolution, and persistence key on — see this type's own
    /// documentation.
    public let key: String
    public let source: Source

    /// Which list `key` is resolved against.
    public enum Source: String, Sendable, Hashable, Codable {
        /// `key` names a fan; the readout is that fan's current actual RPM
        /// (`FanPollingReading.actual`). A fan's minimum/maximum are hardware bounds, not
        /// live state, so they are never independently selectable readouts.
        case fan
        /// `key` names a non-fan sensor; the readout is that sensor's current sample
        /// (`SensorPollingReading.sample`), formatted per its own `kind`.
        case sensor
    }

    /// `source` is folded into `id` (not just `key`) because the same raw key can appear
    /// in both `fans` and `sensors` — see this type's documentation.
    public var id: String { "\(source.rawValue):\(key)" }

    public init(key: String, source: Source) {
        self.key = key
        self.source = source
    }
}

/// One `MenuBarReadout`, resolved against a live poll: everything a view needs to render
/// it honestly, in one place.
public struct ResolvedMenuBarReadout: Sendable, Hashable, Identifiable {
    /// The raw SMC key — always present and always shown, per `CLAUDE.md`'s rule that a
    /// friendly label never stands in for the key it came from. Present even when
    /// `reading` is `.unavailable` (including when nothing in the current poll matched
    /// this readout at all — see `MenuBarReadout.resolve(fans:sensors:)`).
    public let key: String
    /// Which `MenuBarReadout` this was resolved from. Carried through (not just `key`)
    /// so `id` stays unique — see this property's own note on `id` below.
    public let source: MenuBarReadout.Source
    /// The catalog or fan-poll label for `key`, if any. `nil` is a normal result — an
    /// unrecognised or unlabelled sensor still resolves fully, just without a friendly
    /// name.
    public let label: String?
    public let kind: SensorReading.Kind
    public let reading: KeyedReading
    /// Carried only for `.fan`-sourced readouts — a sensor has no control mode to
    /// misreport. `nil` here is never itself a claim of "automatic"; a view rendering a
    /// fan readout without this populated is a bug, not a safe default, which is why
    /// `MenuBarReadout.resolve(fans:sensors:)` always fills it in for `.fan` sources.
    public let fanControlState: FanControlState?

    /// Mirrors `MenuBarReadout.id`: `key` alone is not unique, because a selection may
    /// legitimately include the same raw key once as `.fan` and once as `.sensor` — see
    /// `MenuBarReadout`'s documentation on why `source` exists. Without `source` folded
    /// in here too, `ForEach(viewModel.readouts)` over such a selection would see two
    /// rows claiming the same identity.
    public var id: String { "\(source.rawValue):\(key)" }

    public init(
        key: String,
        source: MenuBarReadout.Source,
        label: String?,
        kind: SensorReading.Kind,
        reading: KeyedReading,
        fanControlState: FanControlState? = nil
    ) {
        self.key = key
        self.source = source
        self.label = label
        self.kind = kind
        self.reading = reading
        self.fanControlState = fanControlState
    }
}

/// What is driving a fan, and whether the system has taken it back — mirrored from
/// `FanPollingReading` so a menu bar readout can render reclamation honestly instead of
/// silently presenting a fan as always-automatic. Always `.automatic`/`false` under
/// `Monitor` today (see `FanPollingReading`'s own documentation for why), carried through
/// unconditionally anyway so nothing has to change shape when a real answer exists.
public struct FanControlState: Sendable, Hashable {
    public let mode: FanControlMode
    public let isReclaimedBySystem: Bool

    public init(mode: FanControlMode, isReclaimedBySystem: Bool) {
        self.mode = mode
        self.isReclaimedBySystem = isReclaimedBySystem
    }
}

extension MenuBarReadout {
    /// Resolves this readout against a live poll's fans and sensors.
    ///
    /// Never returns `nil`: a readout naming a key the current poll does not (yet, or any
    /// longer) report resolves to `.unavailable` with a diagnostic reason, exactly like
    /// any other missing reading in this codebase — never silently dropped from the menu
    /// bar, because a selection a user made deliberately disappearing without explanation
    /// is its own kind of dishonesty about state.
    public func resolve(
        fans: [FanPollingReading], sensors: [SensorPollingReading]
    ) -> ResolvedMenuBarReadout {
        switch source {
        case .fan:
            guard let fan = fans.first(where: { $0.actual.key == key }) else {
                return ResolvedMenuBarReadout(
                    key: key, source: source, label: nil, kind: .rpm,
                    reading: .unavailable(key: key, reason: "no fan reports this key right now"),
                    fanControlState: nil)
            }
            return ResolvedMenuBarReadout(
                key: key, source: source, label: fan.displayName, kind: .rpm,
                reading: fan.actual,
                fanControlState: FanControlState(
                    mode: fan.mode, isReclaimedBySystem: fan.isReclaimedBySystem))
        case .sensor:
            guard let sensor = sensors.first(where: { $0.key == key }) else {
                return ResolvedMenuBarReadout(
                    key: key, source: source, label: nil, kind: .unknown,
                    reading: .unavailable(
                        key: key, reason: "no sensor reports this key right now"),
                    fanControlState: nil)
            }
            return ResolvedMenuBarReadout(
                key: key, source: source, label: sensor.decoration?.label, kind: sensor.kind,
                reading: sensor.sample, fanControlState: nil)
        }
    }
}
