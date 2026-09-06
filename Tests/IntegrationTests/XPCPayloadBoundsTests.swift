import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusXPC

/// The envelope check, which is the only bound that runs **before** `JSONDecoder` sees a
/// client's bytes.
///
/// Two properties have to hold at once and they pull in opposite directions: nothing an
/// honest client can legitimately send may be refused, and nothing unbounded may reach the
/// decoder. So every cap gets both tests — a maximal legal payload that must fit, and one
/// byte past the cap that must not — because a bound only tested from the refusing side is
/// a bound nobody would notice had been set to zero.
@Suite("XPC payload envelope bounds")
struct XPCPayloadBoundsTests {

    // MARK: - Fixtures

    /// The largest `clientDescription`/`holderDescription` the field validators accept, in
    /// the shape that maximises UTF-16 code units per character: 128 grapheme clusters,
    /// each a base letter plus a combining acute — 128 characters, 384 UTF-8 bytes, and 256
    /// code units, so its fully escaped form is 1536 bytes.
    ///
    /// A run of plain ASCII would be worse per byte but cannot be legal: 512 ASCII bytes is
    /// 512 characters and the character cap is 128.
    static let maximalDescription = String(
        repeating: "a\u{0301}", count: AeolusXPCValidation.maxClientDescriptionLength)

    /// Writes every UTF-16 code unit as `\uXXXX`, which is what `jsonEscapeExpansion`
    /// claims a conforming encoder may do and what several non-Foundation encoders do by
    /// default. The worst legal case for the envelope, and the only one that exercises the
    /// six.
    static func fullyEscaped(_ text: String) -> String {
        text.utf16.map { String(format: "\\u%04x", $0) }.joined()
    }

    /// Grows a payload to exactly `total` bytes with JSON whitespace, inserted after the
    /// opening brace or bracket so the result is unambiguously well-formed.
    ///
    /// Padding is how "exactly at the cap" is tested against something that also has to
    /// decode: the caps are far larger than any request worth writing out by hand, and a
    /// payload that reaches the cap by being maximal in every field would test the cap and
    /// the field validators at once.
    static func padded(_ payload: Data, toBytes total: Int) -> Data {
        var bytes = Array(payload)
        #expect(bytes.count <= total, "fixture is already larger than the target size")
        // Floored at zero rather than left to the expectation above. `#expect` records a
        // failure and carries on, and `Array(repeating:count:)` **traps** on a negative
        // count — so a fixture that outgrew its cap would abort the whole run instead of
        // failing this one test, which is the harder failure to read.
        bytes.insert(
            contentsOf: Array(repeating: UInt8(ascii: " "), count: max(0, total - bytes.count)),
            at: 1)
        return Data(bytes)
    }

    static func encoded(_ value: some Encodable) throws -> Data {
        try AeolusXPCCoding.encoder().encode(value)
    }

    /// The detail a body's `malformedPayload` refusal gave, or `nil` if it refused some
    /// other way or not at all.
    ///
    /// Deliberately not named `malformedDetail`: `AeolusXPCValidation` already has a
    /// function by that name, and a free function in the test target sharing it would be
    /// resolved by overload rather than reported.
    static func refusedMalformedDetail(_ body: () throws -> Void) -> String? {
        guard case .malformedPayload(let detail)? = fault(from: body) else { return nil }
        return detail
    }

    /// What an over-size refusal says, for the cap in question.
    static func sizeDetail(limit: Int) -> String {
        "is larger than the \(limit)-byte limit for this message"
    }

    static let helloFixture = HelloRequest(
        clientProtocolVersion: AeolusXPCVersion.current, clientDescription: "fanctl")
    static let leaseFixture = LeaseRequest(
        holderDescription: "fanctl", fanIndices: [0], timeToLive: 30, isSelfRenewing: false)
    static let settingsFixture = [FanSetting(fanIndex: 0, control: .automatic)]

    // MARK: - At the cap

    @Test("A hello payload of exactly the cap is decoded")
    func helloAtTheCapIsAccepted() throws {
        let payload = Self.padded(
            try Self.encoded(Self.helloFixture),
            toBytes: AeolusXPCPayloadBounds.maxHelloRequestBytes)

        #expect(payload.count == AeolusXPCPayloadBounds.maxHelloRequestBytes)
        let decoded = try AeolusXPCValidation.decodeHelloRequest(from: payload)
        #expect(decoded == Self.helloFixture)
    }

    @Test("A lease payload of exactly the cap is decoded")
    func leaseAtTheCapIsAccepted() throws {
        let payload = Self.padded(
            try Self.encoded(Self.leaseFixture),
            toBytes: AeolusXPCPayloadBounds.maxLeaseRequestBytes)

        #expect(payload.count == AeolusXPCPayloadBounds.maxLeaseRequestBytes)
        let decoded = try AeolusXPCValidation.decodeLeaseRequest(from: payload)
        #expect(decoded == Self.leaseFixture)
    }

    @Test("A settings payload of exactly the cap is decoded")
    func settingsAtTheCapIsAccepted() throws {
        let payload = Self.padded(
            try Self.encoded(Self.settingsFixture),
            toBytes: AeolusXPCPayloadBounds.maxFanSettingsBytes)

        #expect(payload.count == AeolusXPCPayloadBounds.maxFanSettingsBytes)
        let decoded = try AeolusXPCValidation.decodeFanSettings(from: payload)
        #expect(decoded == Self.settingsFixture)
    }

    // MARK: - One byte over

    @Test("A hello payload one byte over the cap is refused as malformedPayload")
    func helloOneByteOverIsRefused() throws {
        let payload = Self.padded(
            try Self.encoded(Self.helloFixture),
            toBytes: AeolusXPCPayloadBounds.maxHelloRequestBytes + 1)

        #expect(
            Self.refusedMalformedDetail {
                _ = try AeolusXPCValidation.decodeHelloRequest(from: payload)
            } == Self.sizeDetail(limit: AeolusXPCPayloadBounds.maxHelloRequestBytes))
    }

    /// Through the full entry point, not only the decoder, because that is the one the
    /// helper's `hello` handler calls.
    @Test("The hello entry point refuses an over-size payload before it validates fields")
    func helloRequestEntryPointRefusesOverSize() throws {
        let payload = Self.padded(
            try Self.encoded(Self.helloFixture),
            toBytes: AeolusXPCPayloadBounds.maxHelloRequestBytes + 1)

        #expect(
            Self.refusedMalformedDetail {
                _ = try AeolusXPCValidation.helloRequest(from: payload)
            } == Self.sizeDetail(limit: AeolusXPCPayloadBounds.maxHelloRequestBytes))
    }

    @Test("A lease payload one byte over the cap is refused as malformedPayload")
    func leaseOneByteOverIsRefused() throws {
        let payload = Self.padded(
            try Self.encoded(Self.leaseFixture),
            toBytes: AeolusXPCPayloadBounds.maxLeaseRequestBytes + 1)

        #expect(
            Self.refusedMalformedDetail {
                _ = try AeolusXPCValidation.decodeLeaseRequest(from: payload)
            } == Self.sizeDetail(limit: AeolusXPCPayloadBounds.maxLeaseRequestBytes))
    }

    @Test("A settings payload one byte over the cap is refused as malformedPayload")
    func settingsOneByteOverIsRefused() throws {
        let payload = Self.padded(
            try Self.encoded(Self.settingsFixture),
            toBytes: AeolusXPCPayloadBounds.maxFanSettingsBytes + 1)

        #expect(
            Self.refusedMalformedDetail {
                _ = try AeolusXPCValidation.decodeFanSettings(from: payload)
            } == Self.sizeDetail(limit: AeolusXPCPayloadBounds.maxFanSettingsBytes))
    }

    // MARK: - Ordering

    /// The point of the whole exercise: the size check has to run **before** the decoder,
    /// or an unbounded payload is parsed and only then refused.
    ///
    /// Asserted on the detail rather than on the fault code, because both answers are
    /// `malformedPayload` — a test that only checked the code would pass just as happily
    /// with the size check deleted and `JSONDecoder` catching the garbage on the way out.
    @Test("An over-size payload that is not JSON at all is refused by the size check")
    func sizeCheckRunsBeforeTheDecoder() {
        let garbage = Data(
            repeating: UInt8(ascii: "{"), count: AeolusXPCPayloadBounds.maxHelloRequestBytes + 1)

        let detail = Self.refusedMalformedDetail {
            _ = try AeolusXPCValidation.decodeHelloRequest(from: garbage)
        }
        #expect(detail == Self.sizeDetail(limit: AeolusXPCPayloadBounds.maxHelloRequestBytes))
        #expect(detail != "is not well-formed JSON", "the decoder answered, so it ran first")
    }

    /// The other half of the ordering claim: the same garbage *under* the cap really does
    /// reach the decoder, so the test above is distinguishing two live answers rather than
    /// one live answer and one impossible one.
    @Test("The same malformed bytes under the cap are refused by the decoder")
    func underSizeGarbageStillReachesTheDecoder() {
        let garbage = Data(repeating: UInt8(ascii: "{"), count: 16)

        #expect(
            Self.refusedMalformedDetail {
                _ = try AeolusXPCValidation.decodeHelloRequest(from: garbage)
            } == "is not well-formed JSON")
    }

    /// The ordering claim is made for all three entry points, so it is tested at all three.
    ///
    /// It was tested at `decodeHelloRequest` alone, and #219's review showed what that
    /// bought: moving the size check to *after* the decoder in either of the other two left
    /// the entire non-hardware suite green. The "one byte over" tests cannot see it — they
    /// pad well-formed JSON, so the decoder succeeds and the size check then throws the
    /// identical fault whichever order they run in. Only bytes that are over-size **and**
    /// undecodable separate the two orders, and only the answer, not the fault code,
    /// distinguishes them: both are `malformedPayload`.
    ///
    /// The decoder's own answer for the same byte shape is measured here rather than
    /// written down, because it differs per entry point — `[FanSetting]` refuses an object
    /// where it wanted an array, `LeaseRequest` refuses the syntax — and a test that hard
    /// -codes one of those is a test that breaks when Foundation rewords an error.
    @Test("An over-size lease payload that is not JSON at all is refused by the size check")
    func leaseSizeCheckRunsBeforeTheDecoder() {
        let overSize = Data(
            repeating: UInt8(ascii: "{"), count: AeolusXPCPayloadBounds.maxLeaseRequestBytes + 1)
        let decoderAnswer = Self.refusedMalformedDetail {
            _ = try AeolusXPCValidation.decodeLeaseRequest(from: Data(repeating: 0x7B, count: 16))
        }

        let detail = Self.refusedMalformedDetail {
            _ = try AeolusXPCValidation.decodeLeaseRequest(from: overSize)
        }

        #expect(detail == Self.sizeDetail(limit: AeolusXPCPayloadBounds.maxLeaseRequestBytes))
        #expect(
            decoderAnswer != nil, "the decoder has to be a live answer for this to mean anything")
        #expect(detail != decoderAnswer, "the decoder answered, so it ran first")
    }

    /// `apply`'s half of the same claim. This is the one that matters most of the three:
    /// its cap is 486 KB, so a decoder running first is the largest amplification the
    /// helper offers a signed-but-buggy client — which is the whole of #91.
    @Test("An over-size settings payload that is not JSON at all is refused by the size check")
    func settingsSizeCheckRunsBeforeTheDecoder() {
        let overSize = Data(
            repeating: UInt8(ascii: "{"), count: AeolusXPCPayloadBounds.maxFanSettingsBytes + 1)
        let decoderAnswer = Self.refusedMalformedDetail {
            _ = try AeolusXPCValidation.decodeFanSettings(from: Data(repeating: 0x7B, count: 16))
        }

        let detail = Self.refusedMalformedDetail {
            _ = try AeolusXPCValidation.decodeFanSettings(from: overSize)
        }

        #expect(detail == Self.sizeDetail(limit: AeolusXPCPayloadBounds.maxFanSettingsBytes))
        #expect(
            decoderAnswer != nil, "the decoder has to be a live answer for this to mean anything")
        #expect(detail != decoderAnswer, "the decoder answered, so it ran first")
    }

    // MARK: - The caps are not too tight

    /// The escape-expansion term, exercised by the only payload that can reach it: a
    /// maximal legal description written entirely as `\uXXXX`.
    ///
    /// If `jsonEscapeExpansion` were wrong, or the cap were derived from the character cap
    /// rather than the byte cap, this is the test that fails — and it fails as a *refusal
    /// of something legal*, which is the failure mode a cap sized from the refusing side
    /// alone would never show.
    @Test("A maximal, fully escaped hello request fits under the cap and still validates")
    func maximalEscapedHelloFitsUnderTheCap() throws {
        let json = """
            {"clientProtocolVersion":\(AeolusXPCVersion.current),\
            "clientDescription":"\(Self.fullyEscaped(Self.maximalDescription))"}
            """
        let payload = Data(json.utf8)

        #expect(payload.count <= AeolusXPCPayloadBounds.maxHelloRequestBytes)
        let request = try AeolusXPCValidation.helloRequest(from: payload)
        #expect(request.clientDescription == Self.maximalDescription)
        #expect(request.clientDescription.count == AeolusXPCValidation.maxClientDescriptionLength)
    }

    @Test("A maximal, fully escaped lease request fits under the cap and still validates")
    func maximalEscapedLeaseFitsUnderTheCap() throws {
        let indices = (0..<AeolusXPCPayloadBounds.maxFansPerPayload).map(String.init)
            .joined(separator: ",")
        let json = """
            {"holderDescription":"\(Self.fullyEscaped(Self.maximalDescription))",\
            "fanIndices":[\(indices)],\
            "timeToLive":\(Int(AeolusXPCValidation.leaseTTLRange.upperBound)),\
            "isSelfRenewing":false}
            """
        let payload = Data(json.utf8)

        #expect(payload.count <= AeolusXPCPayloadBounds.maxLeaseRequestBytes)
        let request = try AeolusXPCValidation.decodeLeaseRequest(from: payload)
        try AeolusXPCValidation.validateHolderDescription(request.holderDescription)
        #expect(request.fanIndices.count == AeolusXPCPayloadBounds.maxFansPerPayload)
    }

    /// `apply` carries no client-authored free text — its only strings are four-character
    /// SMC keys and a fixed aggregation name — so what has to fit is structure: one setting
    /// per fan this project will enumerate, each holding the largest `Control` arm.
    @Test("A settings payload for every fan, each with a full curve, fits under the cap")
    func maximalSettingsFitUnderTheCap() throws {
        let curve = FanCurve(
            points: (0..<AeolusXPCPayloadBounds.maxCurvePoints).map {
                FanCurve.Point(temperatureCelsius: Double($0), rpm: 1000 + Double($0))
            },
            source: SensorGroup(
                sensorKeys: (0..<AeolusXPCPayloadBounds.maxSensorKeysPerCurve).map {
                    String(format: "TC%02dP", $0)
                },
                aggregation: .maximum
            )
        )
        let settings = (0..<AeolusXPCPayloadBounds.maxFansPerPayload).map {
            FanSetting(fanIndex: $0, control: .curve(curve))
        }
        let payload = try Self.encoded(settings)

        #expect(payload.count <= AeolusXPCPayloadBounds.maxFanSettingsBytes)
        #expect(
            try AeolusXPCValidation.decodeFanSettings(from: payload).count
                == AeolusXPCPayloadBounds.maxFansPerPayload)
    }

    /// The other way a cap fails, and the one no test that derives its own payload from the
    /// constant can see.
    ///
    /// Every "one byte over" test above sizes its payload as `cap + 1`, so loosening the cap
    /// moves the test with it and the suite stays green while the bound stops bounding
    /// anything. These are absolute ceilings on the ceilings — not derivations, and each one
    /// a round number.
    ///
    /// They are the *tightest* round number above each derived cap rather than the loosest
    /// defensible one, which is a change #219's review argued for and it earns its keep: at
    /// 64 KiB / 64 KiB / 1 MiB the whole set tolerated `headroomFactor` going from 2 to 3 —
    /// a 50% loosening of all three caps at once, invisible to every other test in the file.
    /// At 8 KiB / 12 KiB / 512 KiB that mutation is refused by the first two. The cost is
    /// that a real growth in the derivation reaches this test first, which is the intended
    /// direction: widening the envelope on the pre-handshake message should take an argument
    /// and an edit here, not happen as a side effect of adding a field.
    @Test("The caps stay small enough to still be bounds")
    func capsStaySmallEnoughToBeBounds() {
        #expect(AeolusXPCPayloadBounds.maxHelloRequestBytes < 8 * 1024)
        #expect(AeolusXPCPayloadBounds.maxLeaseRequestBytes < 12 * 1024)
        #expect(AeolusXPCPayloadBounds.maxFanSettingsBytes < 512 * 1024)
    }

    /// The one constant here that is a restatement of a number owned elsewhere.
    ///
    /// `AeolusXPC` cannot import `SMCCore` — the shared contract does not take an IOKit
    /// dependency to size an envelope — so this pins the relationship instead: the envelope
    /// must admit at least as many fans as enumeration will ever produce, or a machine at
    /// the enumeration ceiling could not be given settings for its own fans.
    @Test("The settings envelope admits every fan this project will enumerate")
    func envelopeAdmitsEveryFanThisProjectWillEnumerate() {
        #expect(
            AeolusXPCPayloadBounds.maxFansPerPayload >= SMCFanEnumeration.maxPlausibleFanCount)
    }
}
