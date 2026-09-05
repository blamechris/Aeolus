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
    /// count — see `SMCFanEnumeration.maxPlausibleFanCount`, the same defence
    /// `fanctl`'s `ListCommand` enumeration applies for the identical reason.
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

extension PollingError {
    /// Reclassifies `SMCFanEnumeration`'s enumeration-level failures into this module's
    /// own error vocabulary, case for case — `FanPoller.poll(provider:)` throws this,
    /// never `SMCFanEnumerationError` directly, so `PollingViewModel` and its tests keep
    /// speaking one error type regardless of which layer actually did the enumerating.
    init(_ error: SMCFanEnumerationError) {
        switch error {
        case .noSMC:
            self = .noSMC
        case .readFailed(let context, let reason):
            self = .readFailed(context: context, reason: reason)
        case .implausibleFanCount(let declared):
            self = .implausibleFanCount(declared)
        }
    }
}
