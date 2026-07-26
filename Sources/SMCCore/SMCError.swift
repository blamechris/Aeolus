import Foundation

/// Errors raised by the SMC layer.
///
/// `firmware(code:)` deserves special attention: SMC result `0x82` is the rejection an
/// Apple Silicon M3-or-newer machine returns when `thermalmonitord` is holding the fans
/// and refusing to hand over manual control. It is an expected, recoverable condition
/// on the write path, not a bug — see `docs/SMC-RESEARCH.md` and epic E4.
public enum SMCError: Error, Sendable, Equatable {
    /// Could not open a connection to the `AppleSMC` IOService.
    case connectionFailed(kernReturn: Int32)
    /// The key does not exist on this machine. Common and benign: key sets vary by model.
    case keyNotFound(SMCKey)
    /// The firmware returned a non-zero result byte.
    case firmware(code: UInt8)
    /// The firmware reported a data size that disagrees with the declared type.
    case sizeMismatch(key: SMCKey, declared: SMCKeyType, reportedBytes: Int)
    /// A `flag` key returned a byte other than `0x00`/`0x01`. All 50 `flag` keys on
    /// `Mac16,5` were observed as strictly boolean, and the type is documented — and
    /// tested — as one. A firmware value outside that set means the key is not actually
    /// behaving like its declared type; surfacing the raw byte as a `Double` would
    /// fabricate a truth value nobody measured, so this is reported rather than guessed.
    case invalidFlagValue(key: SMCKey, byte: UInt8)
    /// A value could not be represented in the key's declared type.
    case encodingFailed(key: SMCKey, type: SMCKeyType)
    /// No encoder exists yet for this declared type. Distinct from `encodingFailed`,
    /// which means the value did not fit: this means the code is not written. Refusing
    /// is the only safe answer — a guessed encoding writes a wrong RPM to real hardware.
    case encodingNotImplemented(type: SMCKeyType)
    /// The caller lacks the privileges required for the operation. Writes need root.
    case notPermitted

    /// `true` when the error is the M3+ "thermal manager is holding the fans" rejection
    /// that the `Ftst` unlock sequence exists to resolve.
    public var isThermalManagerRejection: Bool {
        self == .firmware(code: 0x82)
    }
}
