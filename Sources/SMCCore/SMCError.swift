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
    /// A value could not be represented in the key's declared type.
    case encodingFailed(key: SMCKey, type: SMCKeyType)
    /// The caller lacks the privileges required for the operation. Writes need root.
    case notPermitted

    /// `true` when the error is the M3+ "thermal manager is holding the fans" rejection
    /// that the `Ftst` unlock sequence exists to resolve.
    public var isThermalManagerRejection: Bool {
        self == .firmware(code: 0x82)
    }
}
