import Testing

@testable import SMCCore

// swiftlint:disable force_unwrapping

/// The reason `SMCSensorProvider.read(keys:)` gives for a key that produced no reading. It is
/// what `fanctl list`, `fanctl watch` and the app print beside the key (#536).
///
/// Driven through `sensorResult(for:_:)`, the conversion `read(keys:)` applies to every
/// outcome. `SMCConnection` has no scripted transport, so `read(keys:)` itself cannot be
/// handed a firmware failure or an unresolved byte order without hardware that produces one.
/// Needs no SMC: the provider's connection is never opened.
@Suite("SMC sensor provider, failure reasons")
struct SMCSensorProviderFailureReasonTests {
    private let provider = SMCSensorProvider()
    private let key = SMCKey("F0Ac")!

    private func converted(
        _ result: Result<SMCValue, SMCError>
    ) -> Result<SensorReading, SensorReadFailure> {
        provider.sensorResult(for: key, SMCKeyReadOutcome(key: key, result: result))
    }

    // MARK: - A key that failed to read

    /// Before #536 this reason was `String(describing:)` of the error, so the user read
    /// `firmware(code: 130)`.
    @Test("A failed read's reason is the error in words, not its enum case")
    func failedReadIsDescribed() {
        #expect(
            converted(.failure(.firmware(code: 0x82)))
                == .failure(.readFailed(reason: "firmware rejected the request (SMC result 0x82)")))
    }

    /// The same rule for an error `scalar()` throws, which reaches the reason through the
    /// `catch`, not through the failed-read case. `flt` is named without the space that pads
    /// it to four characters (#544): before, this read "declares flt  but".
    @Test("A value scalar() refuses is described in words, not as its enum case")
    func refusedDecodeIsDescribed() {
        let value = SMCValue(key: key, type: .flt, bytes: [0x00, 0x00], byteOrder: .littleEndian)
        #expect(
            converted(.success(value))
                == .failure(.notDecodable(reason: "F0Ac declares flt but returned 2 bytes")))
    }

    @Test("A key the firmware does not have is reported as unknown, not as a read failure")
    func absentKeyIsUnknown() {
        #expect(converted(.failure(.keyNotFound(key))) == .failure(.unknownKey("F0Ac")))
    }

    // MARK: - An unresolved byte order is not a non-numeric type

    /// A `ui32` with no resolved byte order, as every `ui32` is on a Mac whose interface
    /// generation could not be detected. Before #536 this said "ui32 is not numeric".
    @Test("A ui32 whose byte order was never resolved says so, not that it is non-numeric")
    func unresolvedIntegerOrderIsNamed() {
        let value = SMCValue(
            key: key, type: .ui32, bytes: [0x00, 0x00, 0x0D, 0x39], byteOrder: nil)
        #expect(
            converted(.success(value))
                == .failure(
                    .notDecodable(
                        reason: "ui32 byte order undetectable (SMC interface generation unknown)")
                ))
    }

    /// Every other numeric type whose byte order the firmware declares per key, and so every
    /// other type `scalar()` returns `nil` for when the order is unresolved.
    ///
    /// Each reason is pinned exactly, with the name written out rather than taken from
    /// `fourCharString`: `flt` is padded to four characters, and before #544 its reason read
    /// "flt  byte order undetectable", which a prefix check on the padded code accepted.
    @Test(
        "Every numeric type with an unresolved byte order says so",
        arguments: [
            (SMCKeyType.si16, "si16", [UInt8](repeating: 0, count: 2)),
            (.ui16, "ui16", [UInt8](repeating: 0, count: 2)),
            (.si32, "si32", [UInt8](repeating: 0, count: 4)),
            (.flt, "flt", [UInt8](repeating: 0, count: 4)),
            (.ui64, "ui64", [UInt8](repeating: 0, count: 8)),
            (.si64, "si64", [UInt8](repeating: 0, count: 8)),
            (.ioft, "ioft", [UInt8](repeating: 0, count: 8)),
        ])
    func unresolvedOrderIsNamedForEveryOrderedType(
        type: SMCKeyType, name: String, bytes: [UInt8]
    ) {
        let value = SMCValue(key: key, type: type, bytes: bytes, byteOrder: nil)
        #expect(
            converted(.success(value))
                == .failure(
                    .notDecodable(
                        reason: "\(name) byte order undetectable (SMC interface generation unknown)"
                    )))
    }

    /// A code this project does not recognise, padded to four characters the way `flt ` is,
    /// is named without its padding too (#544).
    @Test("A padded unrecognised type is called non-numeric without its padding")
    func paddedUnknownTypeIsNamedWithoutPadding() {
        let value = SMCValue(
            key: key, type: .unknown(0x6162_2020), bytes: [0x41, 0x42], byteOrder: nil)
        #expect(converted(.success(value)) == .failure(.notDecodable(reason: "ab is not numeric")))
    }

    /// On a Mac whose generation is unknown, every key's `byteOrder` is `nil`, the
    /// non-numeric ones included. The reason is keyed on the declared type, so those still
    /// say they are not numeric, and a resolved order does not change that either.
    @Test(
        "A non-numeric type is called non-numeric whether or not a byte order was resolved",
        arguments: [SMCByteOrder?.none, .bigEndian, .littleEndian])
    func nonNumericTypeIsNamed(order: SMCByteOrder?) {
        let value = SMCValue(key: key, type: .ch8, bytes: [0x41, 0x42], byteOrder: order)
        #expect(
            converted(.success(value)) == .failure(.notDecodable(reason: "ch8* is not numeric")))
    }

    @Test("A ui32 with a resolved byte order still decodes")
    func resolvedIntegerDecodes() {
        let value = SMCValue(
            key: key, type: .ui32, bytes: [0x00, 0x00, 0x0D, 0x39], byteOrder: .bigEndian)
        #expect(
            converted(.success(value))
                == .success(
                    SensorReading(key: "F0Ac", value: 3385, kind: .rpm, providerIdentifier: "smc")))
    }
}

// swiftlint:enable force_unwrapping
