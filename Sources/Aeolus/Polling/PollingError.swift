import SMCCore

/// Everything that can stop a poll cycle outright — as opposed to a single key's failure,
/// which never stops anything: see `KeyedReading` for how one bad key is represented
/// without aborting the rest of a refresh.
///
/// `PollingViewModel` never lets one of these crash the refresh loop. A failed tick is
/// recorded on `PollingViewModel.phase` and the loop tries again on the next interval —
/// see that type's documentation for why a long-running UI must not die the way a
/// one-shot `fanctl` invocation is allowed to.
public enum PollingError: Error, Sendable, Hashable, CustomStringConvertible {
    /// `SensorProvider.isAvailable` reported `false` — no `AppleSMC` IOService on this
    /// machine at all.
    case noSMC
    /// A whole-request failure from `SensorProvider` itself (not a per-key failure —
    /// those are `KeyedReading.Availability.unavailable`), e.g. the underlying
    /// `SMCConnection` could not be opened.
    case readFailed(context: String, reason: String)
    /// `FNum` decoded to something outside the range this project trusts as a real fan
    /// count — see `FanPoller.maxPlausibleFanCount`, the same defence
    /// `fanctl`'s `ListCommand.maxPlausibleFanCount` applies for the identical reason.
    case implausibleFanCount(Double)

    public var description: String {
        switch self {
        case .noSMC:
            return "no AppleSMC service on this machine"
        case .readFailed(let context, let reason):
            return "\(context): \(reason)"
        case .implausibleFanCount(let value):
            return "FNum decoded to an implausible fan count (\(value))"
        }
    }
}

extension SensorReadFailure {
    /// A human-readable rendering of this failure, for `KeyedReading.Availability
    /// .unavailable`'s `reason`. Never parsed or matched on — mirrors `fanctl`'s
    /// identical `SensorReadFailure.readableDescription` in `ListCommand.swift`,
    /// reimplemented here rather than imported since `AeolusUI` does not depend on the
    /// `fanctl` executable target.
    var readableDescription: String {
        switch self {
        case .unknownKey(let key):
            return "\(key) is not present on this machine"
        case .readFailed(let reason):
            return reason
        case .notDecodable(let reason):
            return reason
        }
    }
}
