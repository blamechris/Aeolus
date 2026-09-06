import Foundation

/// The handshake half of `AeolusXPCValidation`.
///
/// Its own file because the boundary's validation surface has two halves that share only
/// their rules — what a client says about *itself* when it introduces itself, and what it
/// asks for afterwards — and because keeping them together pushed the file past this
/// repository's 400-line limit when `decodeFanSettings` was added. Split along the seam
/// that was already there rather than at an arbitrary line count.
extension AeolusXPCValidation {

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
    /// The envelope is bounded before anything is decoded — see `AeolusXPCPayloadBounds`.
    /// This is the message that most needs it: `hello` is reachable before the handshake
    /// because it *is* the handshake, so this decode is the helper's pre-authentication
    /// surface.
    ///
    /// - Parameter payload: The JSON the client sent.
    /// - Returns: The decoded request.
    /// - Throws: `AeolusXPCFault.malformedPayload`, for an over-size envelope as well as
    ///   for JSON that does not decode.
    public static func decodeHelloRequest(from payload: Data) throws -> HelloRequest {
        try AeolusXPCPayloadBounds.requireWithinEnvelope(
            payload, limit: AeolusXPCPayloadBounds.maxHelloRequestBytes)
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
}
