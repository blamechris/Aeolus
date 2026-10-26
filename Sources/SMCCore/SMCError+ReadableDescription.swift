import Foundation

extension SMCError {
    /// A human-readable description of this failure, for a person reading `fanctl`'s output,
    /// the app, or a hardware report. It is never the default `String(describing:)` dump of
    /// the enum case. Diagnostic only: never parsed or matched on by a caller.
    ///
    /// This is the one place the wording lives. Until #536 it was `fanctl`'s
    /// `describeSMCError(_:)`, which `SMCCore` cannot call. So `SMCSensorProvider` and
    /// `SMCFanEnumeration` printed the raw case into the reasons that `fanctl list`,
    /// `fanctl watch` and the app show. `fanctl`, the app and this module now all call this.
    ///
    /// The switch names every case and has no `default:` arm, so a new case does not compile
    /// until it is described here.
    ///
    /// Deliberately not `CustomStringConvertible`. Conforming would change what
    /// `String(describing:)` prints for an `SMCError` at every call site, including the root
    /// helper's log lines (`ReadOnlyFanAuthority.readSensors()` logs a failed `read(keys:)`
    /// that way). This property changes only the text of the callers that ask for it.
    public var readableDescription: String {
        switch self {
        case .connectionFailed(let kernReturn):
            return "connection to AppleSMC failed (kernel result \(kernReturn))"
        case .keyNotFound(let key):
            return "\(key) does not exist on this machine"
        case .firmware(let code):
            return "firmware rejected the request (SMC result 0x\(Self.hex([code])))"
        case .sizeMismatch(let key, let declared, let reportedBytes):
            return "\(key) declares \(declared.fourCharString) but returned \(reportedBytes) bytes"
        case .invalidFlagValue(let key, let byte):
            return "\(key) is declared flag but returned 0x\(Self.hex([byte])), not 0x00 or 0x01"
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
            return Self.byteOrderUndetectableDescription(of: "\(key)")
        case .implausibleKeyCount(let declared):
            return "#KEY decoded to an implausible value (\(declared))"
        case .unrepresentableKeyCount(let type, let bytes):
            return "#KEY (\(type.fourCharString), raw bytes \(Self.hex(bytes))) did not decode "
                + "to a whole number within Int's range"
        case .nonNumericKeyCount(let type, let bytes):
            return "#KEY declares \(type.fourCharString) (raw bytes \(Self.hex(bytes))), which is "
                + "not a numeric type, so it holds no key count"
        }
    }

    /// `error`'s `readableDescription` when it is an `SMCError`, and `String(describing:)`
    /// otherwise.
    ///
    /// For a caller holding `any Error`: a `do`/`catch` around a `SensorProvider` call or
    /// around `SMCValue.scalar()`. The fallback covers errors this module does not own, such
    /// as a test double's, whose own description is the best text there is.
    public static func readableDescription(of error: any Error) -> String {
        guard let smcError = error as? SMCError else { return String(describing: error) }
        return smcError.readableDescription
    }

    /// The wording for a value whose byte order was never resolved, because the SMC interface
    /// generation could not be detected for its connection.
    ///
    /// Shared by `integerByteOrderUndetectable`, whose subject is the key, and by
    /// `SMCSensorProvider`'s per-key failure for a numeric value that `scalar()` declined to
    /// decode, whose subject is the declared type. One wording, so the two cannot drift.
    static func byteOrderUndetectableDescription(of subject: String) -> String {
        "\(subject) byte order undetectable (SMC interface generation unknown)"
    }

    /// Lowercase hex with no separators, e.g. `[0x7F, 0xC0]` → `"7fc0"`. The same rendering
    /// as the bytes column of `fanctl dump`, so a byte string in a description can be found
    /// in a dump by searching for it.
    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
