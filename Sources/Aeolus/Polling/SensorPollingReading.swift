import FanKit
import SMCCore

/// One non-fan sensor's live state, as the polling layer can currently see it.
///
/// `key` and `kind` are established once, at discovery (`SensorPoller.discover(provider:
/// )`) — a key's physical kind is a property of that key, not of any one reading of it —
/// and then held stable across refreshes so a view can key a stable list identity off
/// `key` even on a tick where the value itself is unavailable. `sample` is what actually
/// changes tick to tick.
public struct SensorPollingReading: Sendable, Hashable, Identifiable {
    /// The raw SMC key, always present regardless of whether a catalog labelled it or
    /// this tick's read succeeded — see `CLAUDE.md`'s rule that the raw key is always
    /// shown alongside any friendly label.
    public let key: String
    public let kind: SensorReading.Kind
    /// This tick's value, or the reason it is currently unavailable. Never a fabricated
    /// zero — see `KeyedReading`'s documentation.
    public let sample: KeyedReading
    /// The catalog's opinion on this key, if any — see `SensorLabelSource`. `nil` is a
    /// normal result, not a degraded one: an unrecognised or unscoped sensor shows fully,
    /// unlabelled.
    public let decoration: CatalogDecoration?

    public var id: String { key }

    public init(
        key: String,
        kind: SensorReading.Kind,
        sample: KeyedReading,
        decoration: CatalogDecoration? = nil
    ) {
        self.key = key
        self.kind = kind
        self.sample = sample
        self.decoration = decoration
    }
}
