import FanKit
import Foundation

/// One fan's live state, as the polling layer can currently see it.
///
/// ## No `{fds` on Apple Silicon
///
/// There is no fan descriptor struct to enumerate. Fans are discovered via `FNum` plus
/// `F<n>Ac`/`Mn`/`Mx` per index — see `SMCCore.SMCFanEnumeration`, the shared enumeration
/// `FanPoller` wraps for presentation. `displayName` ("Fan 0") is synthesised by this
/// layer for a human to read; it is never presented as something the firmware reported,
/// and `actual.key`/`minimum.key`/`maximum.key` are always available alongside it so a
/// view can show the raw key too. A fan from a helper snapshot gets the same three keys,
/// from the same `SMCFanEnumeration` functions, because the snapshot does not carry them.
///
/// ## Observations and control facts, kept apart
///
/// `actual`/`minimum`/`maximum` are observations, and either source may supply them.
/// `control` is every control claim at once, and it names its source: the helper's own
/// `FanState`, from a snapshot within its freshness bound, or `.notTracked` and why.
///
/// This type used to carry `mode` and `isReclaimedBySystem` as fields, hardcoded to
/// `.automatic` and `false` on the direct-read path, which ADR 0006 records as a latent
/// rule-6 defect: a claim about the hardware that a stray helper or another vendor's tool
/// could falsify, made by a process that had asked nobody. There is no default for
/// `control` now, so no path can reach a fan row without saying where its control facts came
/// from.
public struct FanPollingReading: Sendable, Hashable, Identifiable {
    public let index: Int
    public let displayName: String
    public let actual: KeyedReading
    public let minimum: KeyedReading
    public let maximum: KeyedReading

    /// Where this fan's control facts come from — see this type's documentation.
    public let control: FanControlSource

    public var id: Int { index }

    public init(
        index: Int,
        displayName: String,
        actual: KeyedReading,
        minimum: KeyedReading,
        maximum: KeyedReading,
        control: FanControlSource
    ) {
        self.index = index
        self.displayName = displayName
        self.actual = actual
        self.minimum = minimum
        self.maximum = maximum
        self.control = control
    }

    /// The same observations with every control claim withdrawn: what a fan from an earlier
    /// helper snapshot becomes once that snapshot may no longer be rendered.
    func untracked(_ why: ControlNotTracked) -> FanPollingReading {
        FanPollingReading(
            index: index, displayName: displayName, actual: actual, minimum: minimum,
            maximum: maximum, control: .notTracked(why))
    }
}
