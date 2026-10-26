import Testing

@testable import SMCCore

/// The parts of `keyCount()`'s generation route that can be pinned without IOKit.
///
/// The generation decides one thing in `#KEY`'s decode: whether the big-endian fallback may
/// answer, which it may only when the generation is unknown. It reaches the decode by one
/// route. `read(_:)` turns it into the value's `byteOrder`, `nil` exactly when it is unknown,
/// and `decodeKeyCount(value:)` reads nothing else. Until #531, `keyCount()` also passed the
/// generation in beside the value. Replacing that argument with `.modern` broke the fallback
/// on a Mac whose generation cannot be detected, and no test could see it.
///
/// A connection that is never opened has no generation, and both tests here run on one
/// without a round trip: `#KEY`'s metadata is seeded into the `keyInfo` cache, so
/// `READ_KEYINFO` is skipped, and its `dataSize` is 0, so `READ_BYTES` is too. That is the
/// branch `read(_:)` takes for a zero-length key. It works the same on CI, where there is no
/// SMC, and on a real Mac.
///
/// **What these tests do not reach.** A real `#KEY` is 4 bytes, so `read(_:)` returns it from
/// its non-empty branch, after `READ_BYTES`, which these tests never take. With no bytes,
/// `scalar()` throws `sizeMismatch` before it reads the byte order. So nothing here, and nothing
/// on `Mac16,5`, whose generation is always known, checks that `byteOrder` survives that
/// return and `keyCount()`'s hand-off when the generation is unknown. Substituting
/// `.littleEndian` for a missing order at either point leaves every test green. #539 records
/// the gap and what closing it would take: a scripted transport under the stamped call.
@Suite("SMC #KEY: what the interface generation's route to the decode pins without IOKit")
struct SMCConnectionKeyCountGenerationFlowTests {

    /// A never-opened connection that already knows `#KEY`'s metadata. Attribute byte
    /// `0x80` is readable with bit `0x04` clear, which is `#KEY`'s own byte on `Mac16,5`.
    static func connection(seedingKeyCountAs type: SMCKeyType) async -> SMCConnection {
        let connection = SMCConnection()
        await connection.seedKeyInfoCacheForTesting(
            SMCKeyInfo(key: SMCKey.keyCount, type: type, dataSize: 0, attributes: 0x80))
        return connection
    }

    /// `read(_:)`'s byte-order computation, observed through the zero-length return. If it
    /// gave `#KEY` an order without a generation, `scalar()` would decode a `ui32` with that
    /// order, and the fallback this suite is about would never be asked. It cannot see an order
    /// substituted only on the non-empty return; see the suite's documentation.
    @Test("With no generation, read(_:) computes no byte order for #KEY (zero-length return)")
    func readLeavesTheByteOrderUnsetWithoutAGeneration() async throws {
        let connection = await Self.connection(seedingKeyCountAs: .ui32)
        #expect(await connection.interfaceGeneration == nil)

        let value = try await connection.read(SMCKey.keyCount)

        #expect(value.key == SMCKey.keyCount)
        #expect(value.type == .ui32)
        #expect(value.bytes.isEmpty)
        #expect(value.byteOrder == nil)
        #expect(await connection.readKeyInfoAttempts == 0)
    }

    /// The entry point, not the seam: `keyCount()` hands `#KEY`'s declared type, as
    /// `read(_:)` returned it, to `decodeKeyCount(value:)`. A non-numeric type is the one
    /// declaration whose refusal needs no bytes, and its error names the type `read(_:)` was
    /// given. Only the type is pinned here. The byte order in the hand-off is not, because a
    /// refusal of a non-numeric type never reads it.
    @Test("keyCount() hands read(_:)'s declared #KEY type to the decode")
    func keyCountDecodesWhatReadReturned() async {
        let connection = await Self.connection(seedingKeyCountAs: .hex)

        await #expect(throws: SMCError.nonNumericKeyCount(type: .hex, bytes: [])) {
            _ = try await connection.keyCount()
        }
        #expect(await connection.readKeyInfoAttempts == 0)
    }
}
