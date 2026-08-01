import FanKit
import Foundation

/// Every way the helper says no.
///
/// The vocabulary is written out in full in E2, before most of it can be raised, so that
/// E5's safety supervisor and #37's bounds reporting cannot force a protocol bump merely
/// by learning to refuse for a reason nobody had named yet. Only the first few codes are
/// reachable today; the rest are contract, not dead code.
///
/// ## Forward tolerance, and which direction it points
///
/// An unrecognised code decodes to `.unknown(code:detail:)` and renders generically,
/// rather than failing the decode. A client that cannot decode a refusal has to invent
/// what happened, and every invention is optimistic.
///
/// The tolerance is for *values*, not for structure. A code this build knows, arriving
/// without the fields that code requires, still throws: within a version the required
/// fields of a known code cannot move — that is a bump — so their absence means the
/// payload is corrupt, not that the peer is newer.
///
/// ## Free text in a fault
///
/// `detail` and the raw `unknown` code are free text, and free text ends up in a log line
/// and a UI label. It is sanitised at **render** time by `errorDescription`, not at
/// decode time, so diagnostics keep the bytes that actually arrived while nothing
/// unprintable reaches a human. That is the opposite of the rule for client-supplied
/// input in `AeolusXPCValidation`, which refuses rather than repairs — and deliberately
/// so. A request that is not clean should not be honoured; a refusal that is not clean
/// should still be *shown*, because the alternative is a user staring at nothing.
///
/// Fault details never quote the offending value back. A detail describes the violation
/// ("contains a control character"), so nothing a client sent can steer a log line.
public enum AeolusXPCFault: Error, Sendable, Hashable {

    /// A message arrived on a connection where `hello` has not yet succeeded.
    case handshakeRequired

    /// The client speaks a protocol version outside the helper's range. Carries both
    /// sides' numbers so the client can name the fix rather than shrug.
    case versionMismatch(clientVersion: Int, helperRange: ProtocolVersionRange)

    /// A payload did not decode, or was missing a required field. Refused whole — never
    /// partially applied, never silently corrected.
    case malformedPayload(detail: String)

    /// A payload decoded but carried a value outside its declared envelope.
    case invalidParameter(name: String, detail: String)

    /// Manual control cannot be taken at all right now. `reason` shares its vocabulary
    /// with `FanState.manualControlAvailability`, so the answer to "why can't I control
    /// this fan" reads identically whether it arrives in a snapshot or in a refusal.
    case manualControlUnavailable(reason: ManualControlAvailability.Reason)

    /// The lease lapsed. Re-acquire; expiry is never undone by asking again, because a
    /// client that stopped proving it was alive does not get to carry on as though it
    /// never had.
    case leaseExpired

    /// No lease with that ID exists.
    case leaseUnknown

    /// The lease exists but belongs to another connection. A lease is bound to the
    /// connection that acquired it; a valid ID on the wrong connection is a refusal.
    case leaseNotHeldByThisConnection

    /// The thermal emergency override is engaged. It outranks every client request and
    /// cannot be waived by one — there is no message that turns it off.
    case thermalEmergencyActive

    /// The system took the fan back. Reported rather than papered over: the UI must
    /// never claim control it does not have.
    case reclaimedBySystem

    /// The fan's firmware bounds did not survive a plausibility check, so there is no
    /// envelope to clamp into and no safe speed to honour.
    case boundsImplausible(fanIndex: Int, detail: String)

    /// A code this build does not recognise, from a newer helper. Render it generically;
    /// never treat it as a success.
    ///
    /// A decode product, not something to construct by hand: built with a code this build
    /// *does* know, it never round-trips to itself. `.unknown(code: "leaseExpired")`
    /// decodes back as `.leaseExpired`; `.unknown(code: "versionMismatch")` encodes without
    /// the fields that code requires and **throws** on decode. Neither is what was built.
    case unknown(code: String, detail: String?)
}

extension AeolusXPCFault {

    /// The codes this build recognises. Kept as its own `RawRepresentable` enum so that
    /// decoding switches over a closed set: adding a case to `AeolusXPCFault` without
    /// teaching the coder about it becomes a compile error rather than a value that
    /// silently round-trips into `.unknown`.
    private enum KnownCode: String {
        case handshakeRequired
        case versionMismatch
        case malformedPayload
        case invalidParameter
        case manualControlUnavailable
        case leaseExpired
        case leaseUnknown
        case leaseNotHeldByThisConnection
        case thermalEmergencyActive
        case reclaimedBySystem
        case boundsImplausible
    }

    /// The string this fault travels as.
    public var wireCode: String {
        switch self {
        case .handshakeRequired: return KnownCode.handshakeRequired.rawValue
        case .versionMismatch: return KnownCode.versionMismatch.rawValue
        case .malformedPayload: return KnownCode.malformedPayload.rawValue
        case .invalidParameter: return KnownCode.invalidParameter.rawValue
        case .manualControlUnavailable: return KnownCode.manualControlUnavailable.rawValue
        case .leaseExpired: return KnownCode.leaseExpired.rawValue
        case .leaseUnknown: return KnownCode.leaseUnknown.rawValue
        case .leaseNotHeldByThisConnection:
            return KnownCode.leaseNotHeldByThisConnection.rawValue
        case .thermalEmergencyActive: return KnownCode.thermalEmergencyActive.rawValue
        case .reclaimedBySystem: return KnownCode.reclaimedBySystem.rawValue
        case .boundsImplausible: return KnownCode.boundsImplausible.rawValue
        case .unknown(let code, _): return code
        }
    }
}

extension AeolusXPCFault: Codable {
    private enum CodingKeys: String, CodingKey {
        case code
        case detail
        case name
        case clientVersion
        case helperRange
        case reason
        case fanIndex
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireCode, forKey: .code)
        switch self {
        case .handshakeRequired,
            .leaseExpired,
            .leaseUnknown,
            .leaseNotHeldByThisConnection,
            .reclaimedBySystem,
            .thermalEmergencyActive:
            break
        case .versionMismatch(let clientVersion, let helperRange):
            try container.encode(clientVersion, forKey: .clientVersion)
            try container.encode(helperRange, forKey: .helperRange)
        case .malformedPayload(let detail):
            try container.encode(detail, forKey: .detail)
        case .invalidParameter(let name, let detail):
            try container.encode(name, forKey: .name)
            try container.encode(detail, forKey: .detail)
        case .manualControlUnavailable(let reason):
            try container.encode(reason.wireValue, forKey: .reason)
        case .boundsImplausible(let fanIndex, let detail):
            try container.encode(fanIndex, forKey: .fanIndex)
            try container.encode(detail, forKey: .detail)
        case .unknown(_, let detail):
            try container.encodeIfPresent(detail, forKey: .detail)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        guard let known = KnownCode(rawValue: code) else {
            self = .unknown(
                code: code,
                detail: try container.decodeIfPresent(String.self, forKey: .detail)
            )
            return
        }
        switch known {
        case .handshakeRequired:
            self = .handshakeRequired
        case .versionMismatch:
            self = .versionMismatch(
                clientVersion: try container.decode(Int.self, forKey: .clientVersion),
                helperRange: try container.decode(ProtocolVersionRange.self, forKey: .helperRange)
            )
        case .malformedPayload:
            self = .malformedPayload(detail: try container.decode(String.self, forKey: .detail))
        case .invalidParameter:
            self = .invalidParameter(
                name: try container.decode(String.self, forKey: .name),
                detail: try container.decode(String.self, forKey: .detail)
            )
        case .manualControlUnavailable:
            let raw = try container.decode(String.self, forKey: .reason)
            self = .manualControlUnavailable(
                reason: ManualControlAvailability.Reason(wireValue: raw)
            )
        case .leaseExpired:
            self = .leaseExpired
        case .leaseUnknown:
            self = .leaseUnknown
        case .leaseNotHeldByThisConnection:
            self = .leaseNotHeldByThisConnection
        case .thermalEmergencyActive:
            self = .thermalEmergencyActive
        case .reclaimedBySystem:
            self = .reclaimedBySystem
        case .boundsImplausible:
            self = .boundsImplausible(
                fanIndex: try container.decode(Int.self, forKey: .fanIndex),
                detail: try container.decode(String.self, forKey: .detail)
            )
        }
    }
}

extension AeolusXPCFault: LocalizedError {

    /// A message a human can act on, for every case including the ones this build has
    /// never heard of.
    public var errorDescription: String? {
        switch self {
        case .handshakeRequired:
            return """
                The helper refused this request: the connection has not completed its \
                version handshake.
                """
        case .versionMismatch(let clientVersion, let helperRange):
            return """
                Protocol version mismatch. This client speaks version \(clientVersion); \
                the installed helper speaks \(helperRange.minimumSupported) to \
                \(helperRange.current). Update whichever of Aeolus.app or fanctl is older.
                """
        case .malformedPayload(let detail):
            return "The helper refused a malformed request: \(FaultText.displayable(detail))."
        case .invalidParameter(let name, let detail):
            let field = FaultText.displayable(name)
            return "The helper refused the value of \(field): \(FaultText.displayable(detail))."
        case .manualControlUnavailable(let reason):
            return """
                Manual fan control is not available (\(FaultText.displayable(reason.wireValue))).
                """
        case .leaseExpired:
            return """
                The manual-control lease expired and the fans have returned to automatic \
                control. Acquire a new lease to take them back.
                """
        case .leaseUnknown:
            return "The helper has no record of that manual-control lease."
        case .leaseNotHeldByThisConnection:
            return """
                That manual-control lease belongs to another connection. A lease is held \
                by the client that acquired it and cannot be used from elsewhere.
                """
        case .thermalEmergencyActive:
            return """
                A thermal emergency override is engaged. It outranks manual control and \
                cannot be waived.
                """
        case .reclaimedBySystem:
            return """
                The system has taken this fan back from manual control. Aeolus is not \
                driving it right now.
                """
        case .boundsImplausible(let fanIndex, let detail):
            return """
                Fan \(fanIndex) cannot be controlled: its firmware speed bounds are not \
                usable (\(FaultText.displayable(detail))).
                """
        case .unknown(let code, let detail):
            let suffix = detail.map { " (\(FaultText.displayable($0)))" } ?? ""
            return """
                The helper refused this request with a reason this build does not \
                recognise: \(FaultText.displayable(code))\(suffix). The helper is probably newer \
                than this client.
                """
        }
    }
}

/// Rendering rules for the free text a fault carries across the boundary.
enum FaultText {

    /// Longest run of helper-supplied free text this client will render, in characters.
    ///
    /// Not a validation limit — nothing is refused for exceeding it. It bounds one log
    /// line and one UI label, which is all `errorDescription` is for.
    static let maxRenderedLength = 200

    /// The same bound, in UTF-8 bytes.
    ///
    /// A character cap alone does not bound a log line: one grapheme cluster can carry an
    /// unbounded run of combining marks, so 200 *characters* can be hundreds of kilobytes.
    /// Exactly the defect `AeolusXPCValidation.maxHolderDescriptionUTF8Bytes` exists for,
    /// at the same 4:1 ratio, applied to the rendering side. Not reachable from client
    /// input today — this text comes from the helper — so it is depth, not a live hole.
    static let maxRenderedUTF8Bytes = maxRenderedLength * 4

    /// Shown in place of text that survived stripping with nothing left.
    static let unprintableMarker = "unprintable"

    /// Makes free text from the far side of the boundary safe to put in a log line or a
    /// UI label, without discarding the fact that something arrived.
    ///
    /// Control and format characters go, because those are what turn one log line into
    /// two (`\n`) or reverse the reading order of the rest of it (U+202E). An empty or
    /// entirely-unprintable string renders as a marker rather than as nothing at all, so
    /// a reader can tell "the helper said something unprintable" from "the helper said
    /// nothing".
    ///
    /// Both caps apply. Text over either renders truncated with an ellipsis; text so dense
    /// that not one character fits inside the byte cap renders as the marker.
    static func displayable(
        _ text: String,
        limit: Int = maxRenderedLength,
        byteLimit: Int = maxRenderedUTF8Bytes
    ) -> String {
        let stripped = String(
            text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        )
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return unprintableMarker }
        guard trimmed.count > limit || trimmed.utf8.count > byteLimit else { return trimmed }
        let cut = truncated(trimmed, characters: limit, bytes: byteLimit)
        guard !cut.isEmpty else { return unprintableMarker }
        return cut + "…"
    }

    /// Applies both caps at once, cutting on a `Character` boundary so the result is never
    /// a half-formed grapheme cluster and never a split scalar.
    private static func truncated(_ text: String, characters: Int, bytes: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in text.prefix(characters) {
            let width = String(character).utf8.count
            guard byteCount + width <= bytes else { break }
            result.append(character)
            byteCount += width
        }
        return result
    }
}

extension AeolusXPCFault {

    /// The `NSError` domain every Aeolus refusal crosses the boundary under.
    public static let errorDomain = "com.blamechris.Aeolus.XPCFault"

    /// Where `asNSError()` parks the encoded fault.
    ///
    /// A `String`, not `Data`: `NSXPCConnection` re-encodes `userInfo` and is far happier
    /// with the property-list types, and a JSON fault that a human can read straight out
    /// of a crash log is worth more than a compact one.
    public static let payloadUserInfoKey = "AeolusXPCFaultPayload"

    /// `NSError.code` for every Aeolus fault, without exception.
    ///
    /// The vocabulary is `wireCode` and the payload, not this number. A parallel integer
    /// vocabulary would be a second thing to keep in step with the first, and the failure
    /// mode of the two disagreeing is a client acting on the wrong refusal.
    public static let errorCode = 1

    /// Packs this fault into the `NSError` an XPC reply block can carry.
    ///
    /// `NSXPCConnection` flattens a Swift `Error` to an `NSError`, discarding associated
    /// values, so the fault travels as JSON in `userInfo` and is reassembled by
    /// `init(nsError:)` on the far side.
    ///
    /// Never throws. A fault that cannot be encoded is still a refusal that has to reach
    /// the client, so the fallback drops the payload and keeps the message — degrading to
    /// less diagnostic detail, never to an apparent success.
    public func asNSError() -> NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: errorDescription ?? wireCode
        ]
        let encoded = try? AeolusXPCCoding.encoder().encode(self)
        if let encoded, let json = String(data: encoded, encoding: .utf8) {
            userInfo[Self.payloadUserInfoKey] = json
        }
        return NSError(domain: Self.errorDomain, code: Self.errorCode, userInfo: userInfo)
    }

    /// Reassembles a fault an XPC reply block delivered, or `nil` if this error did not
    /// come from Aeolus's boundary.
    ///
    /// `nil` rather than a synthesised `.unknown`: an error from some other layer —
    /// `NSCocoaErrorDomain`, an XPC transport failure — is not a helper refusal, and
    /// dressing it up as one would lose the distinction between "the helper said no" and
    /// "the helper never answered".
    public init?(nsError: NSError) {
        guard nsError.domain == Self.errorDomain,
            let json = nsError.userInfo[Self.payloadUserInfoKey] as? String,
            let data = json.data(using: .utf8),
            let decoded = try? AeolusXPCCoding.decoder().decode(Self.self, from: data)
        else { return nil }
        self = decoded
    }
}
