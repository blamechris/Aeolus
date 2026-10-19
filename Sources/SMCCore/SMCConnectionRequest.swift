import Foundation

extension SMCConnection {
    /// One `SMCKeyData_t` request: the fields this project sets, and nothing else.
    ///
    /// `bytes` is the request exactly as `call(_:)` hands it to `IOConnectCallStructMethod`,
    /// built by a pure function at the offsets in the layout note on `SMCConnection`. Every
    /// request is built here, reads and the write alike, so a write cannot be laid out
    /// differently from the reads `Mac16,5` has answered, and a test can check the bytes a
    /// write sends, one by one, with no connection at all.
    ///
    /// Internal, so `@testable import SMCCore` reaches it and no client does. It confers
    /// nothing: building a request sends nothing, and only `call(_:)`, in
    /// `SMCConnection.swift`, sends one. The offsets and command codes it uses are declared
    /// there.
    ///
    /// **The four factories below are the only way to build one.** Two layers hold that:
    /// - **Outside this file, the compiler.** The initialiser is `private` and every field is
    ///   `private(set)`. Code anywhere else, `SMCConnection.swift` included, cannot call
    ///   `Request(key:selector:data32:dataSize:payload:)`. An initialiser it writes in an
    ///   extension cannot assign a field, however the extension names the type: `extension
    ///   (SMCConnection.Request)` is refused with "setter is inaccessible", as the plain spelling
    ///   is. Nor can that code change a field of a request a factory built.
    /// - **Inside this file, a source pin.** `private` reaches an extension written in the same
    ///   file, so here the compiler refuses nothing. `SMCRequestConstructionTests` holds the file
    ///   to this one declaration and `Request` to the members below. It also checks at run time
    ///   that `Request` is not `Decodable`, whose synthesised `init(from:)` would build one with
    ///   any selector.
    ///
    /// The file boundary is therefore part of the control, not only a way to keep
    /// `SMCConnection.swift` under the length limit. Either way, no request carries a selector no
    /// factory sends, or a payload `write(_:to:)`'s size guard never saw. `WritePathAbsenceTests`'
    /// selector pin reads declared constants only, and a literal in such a call would pass it.
    struct Request: Sendable, Equatable {
        private(set) var key: FourCharCode
        private(set) var selector: UInt8
        private(set) var data32: UInt32
        private(set) var dataSize: UInt32
        private(set) var payload: [UInt8]

        /// Written out, not synthesised, because Swift's memberwise initialiser would be internal.
        /// Declaring one in the body suppresses it. `SMCRequestConstructionTests` holds this one
        /// to `private` and to being the only one.
        private init(
            key: FourCharCode, selector: UInt8, data32: UInt32, dataSize: UInt32, payload: [UInt8]
        ) {
            self.key = key
            self.selector = selector
            self.data32 = data32
            self.dataSize = dataSize
            self.payload = payload
        }

        /// `READ_KEYINFO` (9): the key's declared type, size and attributes.
        static func readKeyInfo(_ key: FourCharCode) -> Request {
            Request(
                key: key, selector: SMCConnection.selectorReadKeyInfo, data32: 0, dataSize: 0,
                payload: [])
        }

        /// `READ_INDEX` (8): the key at `index` in the table. Key 0, which is not a key.
        static func readIndex(_ index: UInt32) -> Request {
            Request(
                key: 0, selector: SMCConnection.selectorReadIndex, data32: index, dataSize: 0,
                payload: [])
        }

        /// `READ_BYTES` (5): `dataSize` bytes of the key's value, the size a prior
        /// `READ_KEYINFO` declared.
        static func readBytes(_ key: FourCharCode, dataSize: UInt32) -> Request {
            Request(
                key: key, selector: SMCConnection.selectorReadBytes, data32: 0,
                dataSize: dataSize, payload: [])
        }

        /// `WRITE_BYTES` (6): `payload` written to the key. `dataSize` is the payload's own
        /// length, so the two cannot disagree. `write(_:to:)` has already refused a payload
        /// that is empty or longer than 32 bytes.
        static func writeBytes(_ key: FourCharCode, payload: [UInt8]) -> Request {
            Request(
                key: key, selector: SMCConnection.selectorWriteBytes, data32: 0,
                dataSize: UInt32(payload.count), payload: payload)
        }

        /// The 80 bytes sent: zero everywhere but the key, `dataSize`, `data8` (the selector),
        /// `data32`, and the payload from offset 48. Integers are stored in the host's byte
        /// order, as the read path always has.
        ///
        /// A payload longer than the 32-byte field is a programming error here, not a
        /// request: it traps rather than being cut short, because a truncated write is a
        /// different write. `write(_:to:)` refuses one before it can reach this.
        var bytes: [UInt8] {
            precondition(
                payload.count <= SMCConnection.maxPayloadBytes,
                "an SMC request carries at most \(SMCConnection.maxPayloadBytes) payload bytes")
            var buffer = [UInt8](repeating: 0, count: SMCConnection.structSize)
            buffer.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: key, toByteOffset: SMCConnection.offsetKey, as: UInt32.self)
                raw.storeBytes(
                    of: dataSize, toByteOffset: SMCConnection.offsetDataSize, as: UInt32.self)
                raw.storeBytes(
                    of: selector, toByteOffset: SMCConnection.offsetData8, as: UInt8.self)
                raw.storeBytes(
                    of: data32, toByteOffset: SMCConnection.offsetData32, as: UInt32.self)
            }
            let start = SMCConnection.offsetBytes
            buffer.replaceSubrange(start..<start + payload.count, with: payload)
            return buffer
        }
    }
}
