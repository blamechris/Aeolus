import Foundation

/// The data type the SMC firmware *declares* for a key.
///
/// This is the single most important type in `SMCCore`, and the reason is worth stating
/// plainly: **encoding differs between Apple Silicon and Intel, but we never branch on
/// the architecture.** We ask the SMC what type a key is and honour the answer.
///
/// Branching on `uname -m` would be wrong in both directions — it would break on any
/// future silicon, and it would miss the fact that a single machine exposes keys of
/// several different types at once. Reading the declared type is one code path that
/// happens to be correct on both generations.
///
/// See `docs/ARCHITECTURE.md` § Sensor and key model.
public enum SMCKeyType: Sendable, Hashable {
    /// Little-endian IEEE-754 `Float32`. Fan RPM on Apple Silicon.
    case flt
    /// Big-endian unsigned 14.2 fixed point — the raw value is `RPM << 2`.
    /// Fan RPM on Intel.
    case fpe2
    /// Big-endian unsigned 7.8 fixed point.
    case fp78
    /// Big-endian signed 7.8 fixed point. The classic Intel temperature encoding.
    case sp78
    case ui8
    case ui16
    case ui32
    case si8
    case si16
    /// Little-endian signed 32-bit integer. Observed on `Mac16,5` (e.g. battery current
    /// and power keys); 84 keys on that machine.
    case si32
    /// Little-endian unsigned 64-bit integer. Observed on `Mac16,5` (energy/charge
    /// accumulators); 23 keys on that machine.
    case ui64
    /// Little-endian signed 64-bit integer. Observed on `Mac16,5`; 5 keys on that
    /// machine.
    case si64
    /// A single byte, `0x00` or `0x01`. Observed as a boolean across all 50 `flag` keys
    /// on `Mac16,5` — no other value was ever seen.
    case flag
    /// Little-endian 48.16 fixed point: read the 8 bytes as a `UInt64` and divide by
    /// 65536.
    ///
    /// - Important: This format was **derived by this project**, not taken from any
    ///   published source. It is not documented anywhere the way `sp78` or `fpe2` are.
    ///   The evidence is in `docs/SMC-RESEARCH.md` §5: all 11 `ioft` keys on `Mac16,5`
    ///   decode to coherent temperatures under this rule, and `TR0Z` (bytes
    ///   `9ad9330000000000`, decoding to 51.850) independently agrees with
    ///   `IOHIDEventSystemClient`'s `PMU tcal` reading of 51.850 to three decimal
    ///   places. Treat this case differently from the others in this enum: it is
    ///   observed-and-corroborated, not sourced.
    case ioft
    /// Fan descriptor struct (`{fds`) — fan ID, type, and a name field.
    case fds
    /// A structured 21-byte record (`{jst`). Observed on `Mac16,5` on 4 keys (`D1JD`…
    /// `D4JD`); no field layout has been derived. Opaque, like `{fds`.
    case jst
    /// Fixed-length character buffer (`ch8*`).
    case ch8
    /// Opaque bytes (`hex_`). Surfaced raw; never interpreted.
    case hex
    /// A declared type we do not recognise. Carried verbatim so the UI can still show
    /// the key and its raw bytes rather than pretending the key does not exist.
    case unknown(FourCharCode)

    /// Builds a key type from the four-character code the SMC reports.
    public init(fourCharCode code: FourCharCode) {
        switch Self.string(from: code) {
        case "flt ": self = .flt
        case "fpe2": self = .fpe2
        case "fp78": self = .fp78
        case "sp78": self = .sp78
        case "ui8 ": self = .ui8
        case "ui16": self = .ui16
        case "ui32": self = .ui32
        case "si8 ": self = .si8
        case "si16": self = .si16
        case "si32": self = .si32
        case "ui64": self = .ui64
        case "si64": self = .si64
        case "flag": self = .flag
        case "ioft": self = .ioft
        case "{fds": self = .fds
        case "{jst": self = .jst
        case "ch8*": self = .ch8
        case "hex_": self = .hex
        default: self = .unknown(code)
        }
    }

    /// The byte width the firmware is expected to report for this type.
    ///
    /// `nil` means variable or unknown width — trust the SMC's reported `dataSize`
    /// instead. Where both are known and they disagree, the firmware wins and the
    /// mismatch is worth logging: it means our table is out of date, not that the
    /// hardware is wrong.
    public var expectedByteWidth: Int? {
        switch self {
        case .flt, .ui32, .si32: 4
        case .fpe2, .fp78, .sp78, .ui16, .si16: 2
        case .ui8, .si8, .flag: 1
        case .ui64, .si64, .ioft: 8
        case .fds, .jst, .ch8, .hex, .unknown: nil
        }
    }

    /// Whether values of this type are meaningful as a scalar reading (a temperature, a
    /// speed, a voltage). Non-numeric types are shown raw and never fed to a fan curve.
    public var isNumeric: Bool {
        switch self {
        case .flt, .fpe2, .fp78, .sp78, .ui8, .ui16, .ui32, .si8, .si16,
            .si32, .ui64, .si64, .flag, .ioft:
            true
        case .fds, .jst, .ch8, .hex, .unknown: false
        }
    }

    /// The four-character code as the SMC spells it, e.g. `"fpe2"`.
    public var fourCharString: String {
        switch self {
        case .flt: "flt "
        case .fpe2: "fpe2"
        case .fp78: "fp78"
        case .sp78: "sp78"
        case .ui8: "ui8 "
        case .ui16: "ui16"
        case .ui32: "ui32"
        case .si8: "si8 "
        case .si16: "si16"
        case .si32: "si32"
        case .ui64: "ui64"
        case .si64: "si64"
        case .flag: "flag"
        case .ioft: "ioft"
        case .fds: "{fds"
        case .jst: "{jst"
        case .ch8: "ch8*"
        case .hex: "hex_"
        case .unknown(let code): Self.string(from: code)
        }
    }

    static func string(from code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}
