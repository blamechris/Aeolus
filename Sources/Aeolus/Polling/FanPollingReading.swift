import FanKit
import Foundation

/// One fan's live state, as the polling layer can currently see it.
///
/// ## No `{fds` on Apple Silicon
///
/// There is no fan descriptor struct to enumerate. Fans are discovered via `FNum` plus
/// `F<n>Ac`/`Mn`/`Mx` per index — see `FanPoller`, which follows the exact enumeration
/// `fanctl`'s `ListCommand` already validated. `displayName` ("Fan 0") is synthesised by
/// this layer for a human to read; it is never presented as something the firmware
/// reported, and `actual.key`/`minimum.key`/`maximum.key` are always available alongside
/// it so a view can show the raw key too.
///
/// ## The honesty flags, hardcoded safe
///
/// `mode` and `isReclaimedBySystem` mirror `FanKit.FanState`'s identical fields exactly,
/// on purpose: under the `Monitor` configuration there is no helper, no write path, and
/// therefore no lease that could ever be reclaimed from — E2 (XPC client), E3/E4 (the
/// write path), and E5 (the safety supervisor that owns reclamation) are all unstarted.
/// Fan state here is *definitionally* always automatic. These fields are still modelled,
/// not omitted, per `CLAUDE.md` rule 6 ("never claim control you do not have"): when a
/// real `AeolusXPC.SystemSnapshot` arrives over a working helper connection, the
/// rendering code built against this type swaps its data source for one that reports a
/// real answer, instead of needing every view that renders a fan to be redesigned to grow
/// a field it never carried before.
public struct FanPollingReading: Sendable, Hashable, Identifiable {
    public let index: Int
    public let displayName: String
    public let actual: KeyedReading
    public let minimum: KeyedReading
    public let maximum: KeyedReading

    /// What is currently driving this fan. Always `.automatic` in this build — see this
    /// type's documentation.
    public let mode: FanControlMode
    /// Whether the system has taken this fan back from manual control. Always `false` in
    /// this build: nothing here has ever asked for manual control, so nothing can have
    /// been reclaimed from it.
    public let isReclaimedBySystem: Bool

    public var id: Int { index }

    public init(
        index: Int,
        displayName: String,
        actual: KeyedReading,
        minimum: KeyedReading,
        maximum: KeyedReading,
        mode: FanControlMode = .automatic,
        isReclaimedBySystem: Bool = false
    ) {
        self.index = index
        self.displayName = displayName
        self.actual = actual
        self.minimum = minimum
        self.maximum = maximum
        self.mode = mode
        self.isReclaimedBySystem = isReclaimedBySystem
    }
}
