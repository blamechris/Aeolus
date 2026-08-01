import FanKit
import Foundation

/// What the helper checks before it believes a client.
///
/// Pure functions over values, with every limit a named constant, for two reasons. The
/// first is testability: this is the code that stands between a hostile payload and a
/// root daemon, and it has a wide surface of refusal paths that all have to be exercised
/// without hardware, a listener, or a privilege. The second is placement — these live in
/// the shared contract target so a client can pre-check a request and give the user an
/// immediate message, while the helper runs the *same* functions after the payload
/// crosses the boundary. Client-side validation is a courtesy; helper-side validation is
/// the control (`CLAUDE.md` rule 7). Sharing the code must not be mistaken for the client
/// doing the checking.
///
/// ## Refuse, never repair
///
/// Nothing here clamps, truncates, de-duplicates, or substitutes a default. A repaired
/// request is one the client never sent and cannot be shown to the user as what they
/// asked for — and a lease whose holder is displayed as a truncated version of a name
/// nobody chose misidentifies who is holding the fans. Every violation throws an
/// `AeolusXPCFault`, and the whole request is refused, never partially applied.
///
/// The first violation found wins. Reporting them all would mean continuing to inspect a
/// payload already known to be untrustworthy, for the benefit of a caller that has to fix
/// them one at a time regardless.
///
/// Fault details describe the violation and never quote the offending value back. A
/// client cannot steer a helper log line with a string it chose.
public enum AeolusXPCValidation {

    // MARK: - Limits

    /// The lease lifetimes the helper will grant.
    ///
    /// The floor exists because a TTL shorter than a plausible scheduling hiccup makes
    /// the lease expire under a healthy client, teaching users that fans dropping back to
    /// automatic is normal noise — which is exactly the signal that must stay meaningful.
    /// The ceiling exists because the TTL is the backstop that catches a client whose
    /// connection never tore down; two minutes of pinned fans is the longest window this
    /// project is willing to leave open.
    ///
    /// `Lease.defaultTimeToLive` (30s) sits inside this range by construction.
    public static let leaseTTLRange: ClosedRange<TimeInterval> = 5...120

    /// Longest `LeaseRequest.holderDescription` the helper accepts, in characters.
    ///
    /// It names who is holding the fans, in a UI row and in `log show`. 128 characters is
    /// more than any honest client needs and less than anything that would push the rest
    /// of a log line off the end of it.
    public static let maxHolderDescriptionLength = 128

    /// Longest `LeaseRequest.holderDescription` the helper accepts, in UTF-8 bytes.
    ///
    /// A character cap alone does not bound what lands in a log line: one grapheme
    /// cluster can carry an unbounded run of combining marks, so 128 *characters* can be
    /// megabytes. Both caps are checked.
    public static let maxHolderDescriptionUTF8Bytes = 512

    /// Longest `HelloRequest.clientDescription` the helper accepts, in characters. Same
    /// class of input as `holderDescription`, so deliberately the same limit.
    public static let maxClientDescriptionLength = maxHolderDescriptionLength

    /// Longest `HelloRequest.clientDescription` the helper accepts, in UTF-8 bytes.
    public static let maxClientDescriptionUTF8Bytes = maxHolderDescriptionUTF8Bytes

    /// The exact length of a lease ID, in UTF-8 bytes.
    ///
    /// `UUID.uuidString` is 36 ASCII characters — 32 hex digits and four hyphens — so this
    /// is an equality, not a maximum. A lease ID has one legal shape and every other
    /// length is a different kind of thing wearing its name.
    public static let leaseIDLength = 36

    // MARK: - Lease requests

    /// Decodes and validates a `LeaseRequest` that arrived over the boundary.
    ///
    /// - Parameters:
    ///   - payload: The JSON the client sent.
    ///   - enumeratedFanIndices: The fans the helper actually found on this machine.
    ///     Supplied by the caller rather than read here, because this module is pure and
    ///     fan enumeration is hardware.
    /// - Returns: The request, when every check passed.
    /// - Throws: `AeolusXPCFault.malformedPayload` if the JSON does not decode, or
    ///   `AeolusXPCFault.invalidParameter` for the first field outside its envelope.
    public static func leaseRequest(
        from payload: Data,
        enumeratedFanIndices: Set<Int>
    ) throws -> LeaseRequest {
        let request = try decodeLeaseRequest(from: payload)
        try validate(request, enumeratedFanIndices: enumeratedFanIndices)
        return request
    }

    /// Decodes a `LeaseRequest` without validating it.
    ///
    /// Every field is required on the wire. `LeaseRequest`'s initialiser has Swift-side
    /// defaults for `timeToLive` and `isSelfRenewing` as a convenience for constructing
    /// one in code; a synthesised `Decodable` does not apply initialiser defaults, and
    /// that asymmetry is the wanted one. A payload that omits a TTL is a client that did
    /// not say how long it wants the fans, and the helper should not decide that for it.
    ///
    /// - Parameter payload: The JSON the client sent.
    /// - Returns: The decoded request.
    /// - Throws: `AeolusXPCFault.malformedPayload`.
    public static func decodeLeaseRequest(from payload: Data) throws -> LeaseRequest {
        do {
            return try AeolusXPCCoding.decoder().decode(LeaseRequest.self, from: payload)
        } catch {
            throw AeolusXPCFault.malformedPayload(detail: malformedDetail(for: error))
        }
    }

    /// Checks an already-decoded `LeaseRequest`.
    ///
    /// - Parameters:
    ///   - request: The decoded request.
    ///   - enumeratedFanIndices: The fans the helper actually found on this machine.
    /// - Throws: `AeolusXPCFault.invalidParameter` for the first field outside its
    ///   envelope.
    public static func validate(
        _ request: LeaseRequest,
        enumeratedFanIndices: Set<Int>
    ) throws {
        try validateHolderDescription(request.holderDescription)
        try validateFanIndices(request.fanIndices, enumeratedFanIndices: enumeratedFanIndices)
        try validateTimeToLive(request.timeToLive)
    }

    /// Checks the fans a lease is being requested over.
    ///
    /// - Parameters:
    ///   - indices: The indices the client asked for.
    ///   - enumeratedFanIndices: The fans the helper actually found on this machine.
    /// - Throws: `AeolusXPCFault.invalidParameter` named `fanIndices`.
    public static func validateFanIndices(
        _ indices: [Int],
        enumeratedFanIndices: Set<Int>
    ) throws {
        guard !indices.isEmpty else {
            throw AeolusXPCFault.invalidParameter(
                name: "fanIndices",
                detail: "a lease must name at least one fan"
            )
        }
        guard Set(indices).count == indices.count else {
            throw AeolusXPCFault.invalidParameter(
                name: "fanIndices",
                detail: "contains a repeated fan index"
            )
        }
        // Refused as a set rather than one index at a time on purpose: naming the
        // offending index would echo client-chosen data into a helper log line, and the
        // client already knows what it asked for.
        guard Set(indices).isSubset(of: enumeratedFanIndices) else {
            throw AeolusXPCFault.invalidParameter(
                name: "fanIndices",
                detail: "names a fan this machine did not enumerate"
            )
        }
    }

    /// Checks a requested lease lifetime against `leaseTTLRange`.
    ///
    /// - Parameter timeToLive: The requested lifetime, in seconds.
    /// - Throws: `AeolusXPCFault.invalidParameter` named `timeToLive`.
    public static func validateTimeToLive(_ timeToLive: TimeInterval) throws {
        // Checked before the range comparison, not left to it. A range test rejects NaN
        // as a side effect of every comparison with NaN being false, which is the right
        // answer arrived at by accident — and it produces a message about bounds for a
        // value that has none.
        guard timeToLive.isFinite else {
            throw AeolusXPCFault.invalidParameter(
                name: "timeToLive",
                detail: "must be a finite number of seconds"
            )
        }
        guard leaseTTLRange.contains(timeToLive) else {
            throw AeolusXPCFault.invalidParameter(
                name: "timeToLive",
                detail: """
                    must be between \(Int(leaseTTLRange.lowerBound)) and \
                    \(Int(leaseTTLRange.upperBound)) seconds
                    """
            )
        }
    }

    /// Checks a `LeaseRequest.holderDescription`.
    ///
    /// - Parameter description: The client-supplied holder name.
    /// - Throws: `AeolusXPCFault.invalidParameter` named `holderDescription`.
    public static func validateHolderDescription(_ description: String) throws {
        try validateDescription(
            description,
            name: "holderDescription",
            maxLength: maxHolderDescriptionLength,
            maxUTF8Bytes: maxHolderDescriptionUTF8Bytes
        )
    }

    // MARK: - Lease identifiers

    /// Checks a lease ID a client presented.
    ///
    /// `Lease.id` is a `UUID`, but it crosses the boundary as a `String`, because that is
    /// what an `@objc` method signature can carry. That widens the type from 128 bits to
    /// anything a client can put in a string, and the helper then logs what it refused —
    /// identifier, team, and reason, per
    /// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) — which puts a client-chosen
    /// string on a root daemon's log line. That is the same pair of harms
    /// `holderDescription` is already guarded against: a newline forges a second log
    /// entry, and an unbounded string is an unbounded write.
    ///
    /// Narrowing back to a UUID closes both at once. Refused, never repaired: an ID that
    /// is not a UUID names no lease this helper ever issued, so there is nothing to repair
    /// it into.
    ///
    /// - Parameter id: The lease ID the client presented.
    /// - Throws: `AeolusXPCFault.invalidParameter` named `leaseID`.
    public static func validateLeaseID(_ id: String) throws {
        // The length is checked before the parse, and is not redundant with it.
        // `UUID(uuidString:)` accepts a trailing NUL — "…-426614174000\0" parses, and
        // returns the same UUID as the string without it. NUL is exactly what
        // `validateDescription` refuses a display string for: anything reading the value
        // as C truncates at it, so an ID carrying one is not the ID it will later be
        // compared or logged as. The parse alone is therefore not a narrowing back to 128
        // bits; the length is what makes it one. It also bounds the input in bytes before
        // any parsing happens at all.
        guard id.utf8.count == leaseIDLength, UUID(uuidString: id) != nil else {
            throw AeolusXPCFault.invalidParameter(
                name: "leaseID",
                detail: "must be a UUID in canonical \(leaseIDLength)-character form"
            )
        }
    }

    // MARK: - Handshake

    /// Decodes and validates a `HelloRequest` that arrived over the boundary.
    ///
    /// - Parameters:
    ///   - payload: The JSON the client sent.
    ///   - helperRange: The versions this helper speaks.
    /// - Returns: The request, when every check passed.
    /// - Throws: `AeolusXPCFault.malformedPayload`,
    ///   `AeolusXPCFault.invalidParameter`, or `AeolusXPCFault.versionMismatch`.
    public static func helloRequest(
        from payload: Data,
        helperRange: ProtocolVersionRange = AeolusXPCVersion.supportedRange
    ) throws -> HelloRequest {
        let request = try decodeHelloRequest(from: payload)
        try validate(request, helperRange: helperRange)
        return request
    }

    /// Decodes a `HelloRequest` without validating it.
    ///
    /// - Parameter payload: The JSON the client sent.
    /// - Returns: The decoded request.
    /// - Throws: `AeolusXPCFault.malformedPayload`.
    public static func decodeHelloRequest(from payload: Data) throws -> HelloRequest {
        do {
            return try AeolusXPCCoding.decoder().decode(HelloRequest.self, from: payload)
        } catch {
            throw AeolusXPCFault.malformedPayload(detail: malformedDetail(for: error))
        }
    }

    /// Checks an already-decoded `HelloRequest`.
    ///
    /// The description is checked before the version, so a client that is both
    /// out-of-range and misbehaved is told about the misbehaviour: a version mismatch is
    /// fixed by updating, and reporting it first would hide a bug the update will not
    /// fix.
    ///
    /// - Parameters:
    ///   - request: The decoded request.
    ///   - helperRange: The versions this helper speaks.
    /// - Throws: `AeolusXPCFault.invalidParameter` or `AeolusXPCFault.versionMismatch`.
    public static func validate(
        _ request: HelloRequest,
        helperRange: ProtocolVersionRange = AeolusXPCVersion.supportedRange
    ) throws {
        try validateClientDescription(request.clientDescription)
        guard helperRange.accepts(clientVersion: request.clientProtocolVersion) else {
            throw AeolusXPCFault.versionMismatch(
                clientVersion: request.clientProtocolVersion,
                helperRange: helperRange
            )
        }
    }

    /// Checks a `HelloRequest.clientDescription`.
    ///
    /// - Parameter description: The client-supplied client name.
    /// - Throws: `AeolusXPCFault.invalidParameter` named `clientDescription`.
    public static func validateClientDescription(_ description: String) throws {
        try validateDescription(
            description,
            name: "clientDescription",
            maxLength: maxClientDescriptionLength,
            maxUTF8Bytes: maxClientDescriptionUTF8Bytes
        )
    }

    // MARK: - Shared

    /// The one place a client-supplied display string is judged.
    ///
    /// These strings are the project's clearest case of hostile input: chosen entirely by
    /// the client, stored by a root daemon, and rendered verbatim into a UI row and a
    /// `log show` line that a human then reads and acts on. A newline forges a second log
    /// entry, U+202E reverses the reading order of everything after it, and a
    /// megabyte-long name is a denial of service against whoever is reading the log.
    ///
    /// Refused rather than sanitised. Stripping the characters and carrying on would
    /// display a name the client did not choose as though it had, which is a quiet
    /// misidentification of who is holding the fans — and a client sending a control
    /// character has a bug worth surfacing rather than absorbing.
    private static func validateDescription(
        _ description: String,
        name: String,
        maxLength: Int,
        maxUTF8Bytes: Int
    ) throws {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AeolusXPCFault.invalidParameter(
                name: name,
                detail: "must not be empty"
            )
        }
        guard description.count <= maxLength else {
            throw AeolusXPCFault.invalidParameter(
                name: name,
                detail: "must be at most \(maxLength) characters"
            )
        }
        guard description.utf8.count <= maxUTF8Bytes else {
            throw AeolusXPCFault.invalidParameter(
                name: name,
                detail: "must be at most \(maxUTF8Bytes) bytes when encoded as UTF-8"
            )
        }
        // .controlCharacters is Unicode categories Cc and Cf, which is both halves of the
        // problem: Cc covers NUL, the C0 range, and the newline that forges a log entry;
        // Cf covers the bidirectional overrides that rewrite a line without adding a
        // visible character to it.
        guard
            description.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw AeolusXPCFault.invalidParameter(
                name: name,
                detail: "must not contain control or formatting characters"
            )
        }
    }

    /// Describes a decoding failure without quoting the payload back.
    ///
    /// `DecodingError`'s own description embeds the offending value, which is
    /// client-chosen data on its way to a helper log line. The coding path is enough for
    /// a developer and is drawn from this project's own key names, not the client's.
    private static func malformedDetail(for error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return "could not be decoded"
        }
        switch decodingError {
        case .keyNotFound(let key, _):
            return "required field '\(key.stringValue)' is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty
                ? "a field has the wrong type" : "field '\(path)' has the wrong type"
        case .dataCorrupted:
            return "is not well-formed JSON"
        @unknown default:
            return "could not be decoded"
        }
    }
}
