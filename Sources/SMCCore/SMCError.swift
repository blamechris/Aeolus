import Foundation

/// Errors raised by the SMC layer.
///
/// `firmware(code:)` deserves special attention: SMC result `0x82` is named `SmcBadCommand`
/// in Intel-era documentation. That the result namespace carries over to Apple Silicon is
/// **an assumption, not an observation** — it is consistent with every code seen on
/// `Mac16,5` landing on a defined Intel name, and nothing more; `docs/SMC-RESEARCH.md`
/// records it with the same caveat. What *is* observed is that `0x82` behaves as a
/// **general** firmware status here, not a fan-control-specific one. On
/// `Mac16,5` it is the response to a plain read of 21 power/battery function keys, none of
/// them fan-related (see `docs/SMC-RESEARCH.md`). Community reports say the same code also
/// answers an `F0Md` write while `thermalmonitord` is holding the fans on M3-or-newer
/// hardware. The code alone identifies neither condition: only the combination of *what
/// was being attempted* and *this code* is diagnostic. See `isCommandRejection` below and
/// epic E4.
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
    /// The key declares itself unreadable via attribute bit `0x80`. Observed on 52 keys
    /// on `Mac16,5`. Distinct from `firmware(code:)`: this is caught client-side, before
    /// `READ_BYTES` is ever issued, from metadata `READ_KEYINFO` already returned.
    case notReadable(SMCKey)
    /// The key's declared `dataSize` exceeds the 32-byte `SMCKeyData_t` payload. Observed
    /// up to 120 bytes on 30 keys on `Mac16,5`, none of them fan or temperature keys.
    /// `SMCConnection` refuses to read these rather than silently truncating — truncating
    /// would fabricate a value. Metadata (type, size, attributes) remains available via
    /// `SMCConnection.keyInfo(for:)`.
    case valueTooLargeForSingleRead(key: SMCKey, dataSize: Int)
    /// `#KEY` index enumeration returned a four-character code that is not valid ASCII.
    /// Never observed on `Mac16,5`, but the index table is firmware data, not something
    /// this project controls, so it must not be assumed well-formed.
    case malformedKeyCode(FourCharCode)
    /// A negative or otherwise unrepresentable key-table index was requested.
    case invalidIndex(Int)
    /// `IOConnectCallStructMethod` returned success but wrote fewer than the 80 bytes of
    /// `SMCKeyData_t`. The reply buffer is zero-initialised and decoded at fixed offsets,
    /// so a short write would otherwise surface as a zeroed `result` byte — success — and
    /// an all-zero payload: a fabricated 0 RPM or 0 °C reading rather than an error.
    /// Never observed on `Mac16,5`; checked because the alternative failure is silent.
    case truncatedReply(expected: Int, received: Int)
    /// A plain-integer key (`ui16`/`si16`/`ui32`/`si32`/`ui64`/`si64`) could not be
    /// decoded because the SMC interface generation was undetectable for this connection.
    /// Byte order for these types is firmware-declared per key, not implied by the type —
    /// see `docs/ADR/0003-integer-byte-order.md` — and refusing to guess beats guessing.
    /// Distinct from `sizeMismatch`: the bytes are exactly the length the type declares,
    /// but this decoder does not know which order to read them in.
    case integerByteOrderUndetectable(key: SMCKey)
    /// `#KEY` decoded to a value outside `SMCConnection.maxPlausibleKeyCount`.
    ///
    /// This is a firmware/decode-consistency fault, not an I/O failure, and is reported as
    /// its own case so a caller can tell the two apart. It is the exact failure ADR 0003's
    /// `#KEY` cross-check exists to catch: a misdecoded `#KEY` used, unchecked, to size an
    /// allocation and bound an enumeration loop. On `Mac16,5`, `#KEY`'s raw bytes
    /// (`00000d39`) decode to 3385 big-endian (correct) or 957,153,280 little-endian (a
    /// ~957-million-element allocation and loop) — this case is what stands between a
    /// byte-order regression and that outcome. Carries the offending decoded value.
    case implausibleKeyCount(declared: Int)

    /// `true` when the firmware answered with `0x82` — named `SmcBadCommand` in Intel-era
    /// documentation, on the assumption that namespace carries over (see the type comment).
    ///
    /// This is **not**, by itself, a test for "the thermal manager is holding the fans."
    /// `0x82` is a general command-rejection status: on `Mac16,5` it is what a plain
    /// `READ_BYTES` gets back from 21 power/battery function keys (`pcHS`, `rBK0`–`rBK9`,
    /// `rLD0`–`rLD5`, and others — see `docs/SMC-RESEARCH.md`), none of them related to fan
    /// control. Community reports separately describe the same code answering an `F0Md`
    /// write on M3-or-newer hardware while `thermalmonitord` is asserting control.
    ///
    /// The code alone identifies nothing. A caller only has evidence of a thermal-manager
    /// hold when **both** are true: the rejected operation was a write to a fan mode or
    /// target key (`F0Md`/`F1Md`/`F0Tg`/`F1Tg`), *and* the firmware answered with this code.
    /// E4's retry loop must branch on that conjunction, not on this property alone — an
    /// unrelated `0x82` fed into the reported ~300-attempt, 100 ms retry budget is roughly
    /// 30 seconds of futile retrying before an honest failure is reported.
    public var isCommandRejection: Bool {
        self == .firmware(code: 0x82)
    }
}
