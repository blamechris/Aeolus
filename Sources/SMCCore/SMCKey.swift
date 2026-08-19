import Foundation

/// A four-character SMC key, e.g. `F0Ac` (fan 0 actual RPM) or `Tp09`.
///
/// Keys are discovered at runtime by enumerating `#KEY` and walking the index, never
/// from a hard-coded list. A hard-coded list would silently omit sensors on any Mac we
/// have not personally seen — and we have seen very few. The named constants below are
/// conveniences for keys the control path needs by name, not an inventory.
public struct SMCKey: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    /// Creates a key from a four-character string. Returns `nil` if the string is not
    /// exactly four ASCII characters.
    public init?(_ rawValue: String) {
        guard rawValue.count == 4, rawValue.allSatisfy(\.isASCII) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// The key as the FourCharCode the IOKit interface expects.
    public var fourCharCode: FourCharCode {
        rawValue.utf8.reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }
    }

    /// Builds a key from the four-character code IOKit hands back, e.g. from
    /// `READ_INDEX` during enumeration. Returns `nil` if the code does not decode to
    /// four ASCII characters — index-table entries are firmware data, not something
    /// this project controls, so this is not force-unwrapped anywhere it is used.
    public init?(fourCharCode code: FourCharCode) {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        self.init(String(decoding: bytes, as: UTF8.self))
    }
}

extension SMCKey {
    /// Builds a key from a string literal known at authoring time to be four ASCII
    /// characters. Traps on a malformed literal, which can only be a typo in this file
    /// and is caught by the test suite rather than by a user.
    private static func known(_ raw: String) -> SMCKey {
        guard let key = SMCKey(raw) else {
            preconditionFailure("'\(raw)' is not a valid four-character SMC key")
        }
        return key
    }

    /// Number of keys the SMC exposes. The root of all key enumeration.
    public static let keyCount = known("#KEY")

    /// Per-fan keys. `index` is zero-based; `F0Ac` is fan 0's actual RPM.
    public static func fanActualRPM(_ index: Int) -> SMCKey? { SMCKey("F\(index)Ac") }
    public static func fanTargetRPM(_ index: Int) -> SMCKey? { SMCKey("F\(index)Tg") }
    public static func fanMinimumRPM(_ index: Int) -> SMCKey? { SMCKey("F\(index)Mn") }
    public static func fanMaximumRPM(_ index: Int) -> SMCKey? { SMCKey("F\(index)Mx") }
    /// Per-fan mode key. Writing `1` requests manual control (Apple Silicon).
    public static func fanMode(_ index: Int) -> SMCKey? { SMCKey("F\(index)Md") }

    /// Total fan count.
    public static let fanCount = known("FNum")

    /// Intel force-manual bitmask: bit *n* forces fan *n*.
    public static let fanForceBitmask = known("FS! ")

    /// Diagnostic / force key. On Apple Silicon M3 and newer, writing `1` here is what
    /// persuades the thermal manager to yield the fans; firmware resets it across sleep,
    /// so the unlock is re-run whenever manual control is granted — never by the helper
    /// re-asserting on wake, which ADR 0007 forbids. See E4.
    public static let forceTest = known("Ftst")
}
