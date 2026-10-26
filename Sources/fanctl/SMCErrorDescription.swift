import Foundation
import SMCCore

/// A clear, human-readable description of a failure from the SMC read path — never the
/// default `String(describing:)` dump of an enum case, and never a bare `nil`. Every
/// case in `SMCError` is named explicitly, so a contributor reading a hardware report
/// understands what happened without the source open next to it.
///
/// Shared by every `fanctl` command that reports an `SMCError`: `dump` for its rows and its
/// whole-command failures, and `sensors` when `readAll()` throws. It was `dump`'s own
/// `describeDumpError(_:)` until #531 found `sensors` printing the raw enum case instead,
/// which broke the promise in `FanctlError`'s documentation.
func describeSMCError(_ error: Error) -> String {
    guard let smcError = error as? SMCError else {
        return String(describing: error)
    }
    switch smcError {
    case .connectionFailed(let kernReturn):
        return "connection to AppleSMC failed (kernel result \(kernReturn))"
    case .keyNotFound(let key):
        return "\(key) does not exist on this machine"
    case .firmware(let code):
        let hex = String(format: "%02x", code)
        return "firmware rejected the request (SMC result 0x\(hex))"
    case .sizeMismatch(let key, let declared, let reportedBytes):
        return "\(key) declares \(declared.fourCharString) but returned \(reportedBytes) bytes"
    case .invalidFlagValue(let key, let byte):
        let hex = String(format: "%02x", byte)
        return "\(key) is declared flag but returned 0x\(hex), not 0x00 or 0x01"
    case .encodingFailed(let key, let type):
        return "\(key) (\(type.fourCharString)) value could not be encoded"
    case .encodingNotImplemented(let type):
        return "no encoder implemented yet for \(type.fourCharString)"
    case .notPermitted:
        return "not permitted (this connection has no write access)"
    case .notReadable(let key):
        return "\(key) declares itself unreadable (attribute bit 0x80 clear)"
    case .valueTooLargeForSingleRead(let key, let dataSize):
        return "\(key) declares \(dataSize) bytes, larger than the 32-byte read payload"
    case .malformedKeyCode(let code):
        return "index table returned a malformed key code (\(code))"
    case .invalidIndex(let index):
        return "invalid key-table index \(index)"
    case .truncatedReply(let expected, let received):
        return "truncated SMC reply: expected \(expected) bytes, received \(received)"
    case .integerByteOrderUndetectable(let key):
        return "\(key) byte order undetectable (SMC interface generation unknown)"
    case .implausibleKeyCount(let declared):
        return "#KEY decoded to an implausible value (\(declared))"
    case .unrepresentableKeyCount(let type, let bytes):
        return "#KEY (\(type.fourCharString), raw bytes \(hexString(bytes))) did not decode "
            + "to a whole number within Int's range"
    }
}
