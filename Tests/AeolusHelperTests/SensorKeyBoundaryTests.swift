import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// A curve's sensor keys, checked by the helper after they cross (#566, `CLAUDE.md` rule 7).
///
/// Sent over a real XPC connection (`AnonymousListenerHarness`): a client's JSON, through
/// `NSXPCConnection`, the exported object and the session's decode, to the guard and back. The
/// transport matters here as much as the guard. A key a client cannot get past `JSONDecoder`
/// never tests the guard, so each hostile key is shown to arrive and be refused by name and
/// detail, not merely to fail.
///
/// **Before the authority.** `RecordingFanAuthority` records every call, and each refusal here
/// leaves it empty. Everything that could store, log or read a key — the lease core, level 6,
/// the plane, the SMC — is behind that seam, so an authority never called is a key nothing has
/// looked at.
@Suite("Sensor keys at the boundary", .timeLimit(.minutes(1)))
struct SensorKeyBoundaryTests {

    /// One malformed sensor group, and the detail its refusal must carry.
    struct Refusal: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let keys: [String]
        let detail: String
    }

    static let length = "each key must be exactly 4 bytes, as an SMC key is"
    static let alphabet = "each key must be printable ASCII, as an SMC key is"

    /// Each guard, at least once, and each half of the alphabet: the newline, NUL, U+2028 and
    /// U+202E are what the display rule removes; `é` is displayed and outside ASCII.
    static let refusals = [
        Refusal(testDescription: "three bytes", keys: ["Tp0"], detail: length),
        Refusal(testDescription: "five bytes", keys: ["Tp091"], detail: length),
        Refusal(
            testDescription: "four characters, five bytes", keys: ["Tp0\u{E9}"], detail: length),
        Refusal(testDescription: "a newline", keys: ["Tp0\n"], detail: alphabet),
        Refusal(testDescription: "NUL", keys: ["Tp0\u{0}"], detail: alphabet),
        Refusal(testDescription: "U+2028 LINE SEPARATOR", keys: ["\u{2028}T"], detail: alphabet),
        Refusal(
            testDescription: "U+202E, a bidi override", keys: ["\u{202E}T"], detail: alphabet),
        Refusal(testDescription: "outside ASCII", keys: ["T\u{E9}0"], detail: alphabet),
        Refusal(
            testDescription: "no sensors", keys: [], detail: "a curve must name at least one sensor"
        ),
        Refusal(
            testDescription: "seventeen sensors",
            keys: (0..<17).map { String(format: "Tp%02d", $0) },
            detail: "a curve may name at most 16 sensors"),
        Refusal(
            testDescription: "a sensor named twice", keys: ["Tp09", "TC0P", "Tp09"],
            detail: "a curve names the same sensor twice"),
    ]

    /// The JSON a client sends to drive fan 0 from a curve over `keys`.
    static func settings(sensorKeys keys: [String]) throws -> Data {
        try AeolusXPCCoding.encoder().encode([
            FanSetting(
                fanIndex: 0,
                control: .curve(
                    FanCurve(
                        points: [FanCurve.Point(temperatureCelsius: 50, rpm: 2_000)],
                        source: SensorGroup(sensorKeys: keys))))
        ])
    }

    /// A handshaken connection to a helper answering through `authority`.
    private func handshaken(_ authority: RecordingFanAuthority) async -> AnonymousListenerHarness {
        let harness = AnonymousListenerHarness(authority: authority)
        _ = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: (try? helloPayload()) ?? Data(), reply: reply)
        }
        return harness
    }

    /// **Mutation:** delete `try AeolusXPCValidation.validateSensorKeys(in: settings)` from
    /// `HelperConnectionSession.apply(settings:leaseID:)`. Run: red on every row, at both
    /// expectations: the fault is `manualControlUnavailable(writePathNotBuilt)`, the double's
    /// answer, and the authority was called.
    @Test(
        "A malformed sensor group is refused over the wire, before the authority",
        arguments: refusals)
    func aMalformedSensorGroupIsRefused(_ refusal: Refusal) async throws {
        let authority = RecordingFanAuthority()
        let harness = await handshaken(authority)
        let payload = try Self.settings(sensorKeys: refusal.keys)

        let reply = await harness.acknowledgementMessage { proxy, reply in
            proxy.apply(settings: payload, leaseID: UUID().uuidString, reply: reply)
        }

        #expect(reply.fault == .invalidParameter(name: "sensorKeys", detail: refusal.detail))
        #expect(await authority.calls.isEmpty)
    }

    /// The other half of the claim: keys shaped like SMC keys pass, and the message reaches the
    /// authority as it did before #566. The double records the call and answers
    /// `writePathNotBuilt`.
    ///
    /// **Mutation:** make `validateSensorKey`'s alphabet guard refuse every key. Run: red on both.
    @Test("A curve over SMC keys reaches the authority")
    func smcKeysReachTheAuthority() async throws {
        let authority = RecordingFanAuthority()
        let harness = await handshaken(authority)
        let payload = try Self.settings(sensorKeys: ["Tp09", "#KEY", "aDC?", "FS! "])
        let leaseID = UUID()

        let reply = await harness.acknowledgementMessage { proxy, reply in
            proxy.apply(settings: payload, leaseID: leaseID.uuidString, reply: reply)
        }

        #expect(reply.fault == .manualControlUnavailable(reason: .writePathNotBuilt))
        #expect(await authority.calls.map(Self.leaseOfApply) == [leaseID])
    }

    /// The lease an `apply` call named, or `nil` for any other call.
    private static func leaseOfApply(_ call: RecordingFanAuthority.Call) -> UUID? {
        guard case .apply(let lease, _) = call else { return nil }
        return lease
    }
}
