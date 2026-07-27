import Foundation

/// A key's declared type, size, and attribute byte, independent of whether its value can
/// actually be read. Always obtainable, including for keys `SMCConnection.read(_:)`
/// refuses — see its documentation for the three failure modes this exists to survive.
public struct SMCKeyInfo: Sendable, Hashable {
    public let key: SMCKey
    public let type: SMCKeyType
    public let dataSize: Int
    public let attributes: UInt8

    public init(key: SMCKey, type: SMCKeyType, dataSize: Int, attributes: UInt8) {
        self.key = key
        self.type = type
        self.dataSize = dataSize
        self.attributes = attributes
    }

    /// Attribute bit `0x80`. Observed as a perfect correlation with a successful read
    /// across all 3385 keys on `Mac16,5`: necessary, but — per 52 further keys that set
    /// it and still error on `READ_BYTES` — not sufficient.
    public var isReadable: Bool { attributes & 0x80 != 0 }
}
