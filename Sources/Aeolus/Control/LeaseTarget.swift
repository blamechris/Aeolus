import FanKit

/// The fans the user put in Custom, and the speed each is to hold.
///
/// ## Only Custom fans
///
/// A fan on Auto is not in a target. Auto is the lease's release, never a setting: the helper
/// refuses `.automatic` inside `apply` ("release the lease instead"), and one lease covers exactly
/// the fans in Custom (#153). So the fans of a target **are** the fans the lease is asked for, and
/// a change to which fans they are is a release, then an acquire, then an apply.
///
/// ## 0 RPM is not representable
///
/// Every speed is a `FanTargetRPM`, the one shape a commandable speed comes in. Its only source is
/// `FanControlEnvelope.target(for:)` or `target(forPercent:)`, so each speed here is finite, is not
/// zero, and lies inside a validated envelope's commandable range (`CLAUDE.md` rules 3 and 4). The
/// helper clamps again on its side regardless; this is what keeps a zero out of the request.
///
/// ## Never empty
///
/// The initialiser fails on no fans. A lease over no fans is one the helper refuses
/// (`AeolusXPCValidation.validateFanIndices`), and `SystemSnapshot.controlLoss(leaseID:covering:)`
/// over an empty `covering` judges only the lease and the emergency, never a fan. Neither can be
/// reached from here.
public struct LeaseTarget: Sendable, Hashable {

    /// The speed for each fan, by index.
    public let speeds: [Int: FanTargetRPM]

    /// `nil` when `speeds` names no fan.
    public init?(speeds: [Int: FanTargetRPM]) {
        guard !speeds.isEmpty else { return nil }
        self.speeds = speeds
    }

    /// The fans this target names, ascending: the fans the lease is asked for.
    public var fans: [Int] { speeds.keys.sorted() }

    /// What `apply` sends: a `.fixed(rpm:)` for each fan, in index order.
    var settings: [FanSetting] {
        speeds.sorted { $0.key < $1.key }.map {
            FanSetting(fanIndex: $0.key, control: .fixed(rpm: $0.value.rpm))
        }
    }
}
