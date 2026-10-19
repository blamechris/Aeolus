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
    /// **The four factories below are the only way to build one.** Three things hold that:
    /// - **Outside this file, the compiler.** The initialiser is `private`. Each field is stored
    ///   as a `private let`, and the rest of SMCCore reads it through a get-only accessor. Code
    ///   anywhere else, `SMCConnection.swift` included, cannot call
    ///   `Request(key:selector:data32:dataSize:payload:)` or name a stored field. An initialiser
    ///   it writes in an extension cannot assign an accessor, however the extension names the
    ///   type: `extension (SMCConnection.Request)` is refused with "'key' is a get-only
    ///   property", as the plain spelling is. Nor can that code, in safe Swift, change a field of
    ///   a request a factory built.
    /// - **Anywhere, two run-time checks.** `SMCRequestConstructionTests` checks that no key path
    ///   to an accessor, or to `bytes`, is a `WritableKeyPath`, and that `Request` is not
    ///   `Decodable`, whose synthesised `init(from:)` would build one with any selector. Both are
    ///   asked in a test file that imports nothing, so SMCCore's internal names cannot change
    ///   what they ask. A public SMCCore name that a test-target file re-exports, or a name the
    ///   test target declares, still can (#456's delta review, X1 and T2).
    /// - **Inside this file, a source pin.** `private` reaches an extension written in the same
    ///   file, so here the compiler refuses nothing. The same suite holds the file to this one
    ///   declaration, `Request` to the members below, its body to no `@` at all, and each
    ///   accessor's body to exactly its stored field. An `init` accessor, which needs
    ///   `@storageRestrictions`, would let an extension anywhere assign the fields again.
    ///
    /// **Why the accessors are computed rather than `private(set) var` (SR-5218).** A
    /// `private(set)` property still has a setter, and the key path to it is a `WritableKeyPath`
    /// at run time, whatever its static type. In `SMCConnection.swift`,
    /// `(\Request.selector as AnyKeyPath) as? WritableKeyPath<Request, UInt8>` succeeded and
    /// wrote selector 6 into a request a factory built (#456's review, K1). A `let` and a get-only
    /// accessor have no setter, so that cast returns `nil`. A property wrapper cannot be applied
    /// to either. Do not turn the accessors back into `private(set) var`.
    ///
    /// The file boundary is therefore part of the control, not only a way to keep
    /// `SMCConnection.swift` under the length limit. Either way, no request carries a selector no
    /// factory sends. `WritePathAbsenceTests`' selector pin reads declared constants only, and a
    /// literal in such a call would pass it.
    ///
    /// **The payload's size is not this type's to check.** `writeBytes(_:payload:)` accepts any
    /// payload. A write's payload is 1 to 32 bytes because `write(_:to:)` refuses any other
    /// before it calls `writeBytes`, and it is `writeBytes`'s only caller:
    /// `SMCRequestConstructionTests` holds SMCCore to that one call.
    struct Request: Sendable, Equatable {
        private let storedKey: FourCharCode
        private let storedSelector: UInt8
        private let storedData32: UInt32
        private let storedDataSize: UInt32
        private let storedPayload: [UInt8]

        /// The fields as the rest of SMCCore reads them: get-only, so nothing can assign one and
        /// no key path to one is writable, by a dynamic cast or otherwise. See SR-5218 above.
        var key: FourCharCode { storedKey }
        var selector: UInt8 { storedSelector }
        var data32: UInt32 { storedData32 }
        var dataSize: UInt32 { storedDataSize }
        var payload: [UInt8] { storedPayload }

        /// Written out, not synthesised. With the fields stored `private`, Swift's memberwise
        /// initialiser would be private too, but its access would follow the storage's, so
        /// widening a stored field would widen it. This one stays `private` whatever the storage
        /// is, and declaring it in the body suppresses the memberwise one.
        /// `SMCRequestConstructionTests` holds it to `private` and to being the only one.
        private init(
            key: FourCharCode, selector: UInt8, data32: UInt32, dataSize: UInt32, payload: [UInt8]
        ) {
            storedKey = key
            storedSelector = selector
            storedData32 = data32
            storedDataSize = dataSize
            storedPayload = payload
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
        /// length, so the two cannot disagree. This accepts any payload: its one caller,
        /// `write(_:to:)`, has already refused one that is empty or longer than 32 bytes, and
        /// `SMCRequestConstructionTests` holds it to that one caller.
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
