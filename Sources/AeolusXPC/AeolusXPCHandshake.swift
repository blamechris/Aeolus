import Foundation

/// The protocol versions one peer will talk.
///
/// Deliberately a named pair rather than a `ClosedRange<Int>`. The stdlib's `Codable`
/// conformance for `ClosedRange` encodes an unlabelled two-element array, which puts a
/// bounds invariant into a wire format where a malformed value has to be handled rather
/// than trusted — and makes `[1,1]` in a log line something a reader has to decode. A
/// struct with two named fields says what it is.
public struct ProtocolVersionRange: Sendable, Hashable, Codable {
    /// The oldest client version this peer still accepts.
    public let minimumSupported: Int
    /// The newest version this peer speaks.
    public let current: Int

    public init(minimumSupported: Int, current: Int) {
        self.minimumSupported = minimumSupported
        self.current = current
    }

    /// `false` for an inverted range, which no correct peer emits.
    public var isWellFormed: Bool {
        minimumSupported <= current
    }

    /// Whether this peer will talk to a client speaking `clientVersion`.
    ///
    /// A malformed range accepts **nothing**. That is the fail-closed direction: a
    /// received range that makes no sense means the peer or the wire is not what this
    /// code thinks it is, and the safe reading of "I do not understand you" is silence,
    /// not agreement.
    public func accepts(clientVersion: Int) -> Bool {
        // Redundant with the comparison below, and deliberately kept. An inverted range
        // already satisfies neither bound, so this guard cannot change an answer today —
        // it is here because the obvious "simplification" of the line under it is
        // `(minimumSupported...current).contains(clientVersion)`, and constructing that
        // `ClosedRange` from an inverted pair traps. A trap inside a root daemon is not a
        // refactor this code should be one edit away from. Stated rather than implied,
        // because a guard that looks load-bearing and is not is its own kind of defect.
        guard isWellFormed else { return false }
        return clientVersion >= minimumSupported && clientVersion <= current
    }
}

/// A client introducing itself. The first message on every connection.
public struct HelloRequest: Sendable, Hashable, Codable {
    /// The protocol version this client binary was compiled against — a compile-time
    /// fact about the client, never a value the client chooses at runtime to get past a
    /// check.
    public let clientProtocolVersion: Int
    /// Identifies the client for logs and diagnostics, e.g. `Aeolus.app 0.3.0`.
    ///
    /// Hostile input on the helper's side of the boundary: it is rendered into
    /// `log show` output that a human then reads. Validated by
    /// `AeolusXPCValidation.validateClientDescription(_:)`, which refuses rather than
    /// repairs.
    public let clientDescription: String

    public init(clientProtocolVersion: Int, clientDescription: String) {
        self.clientProtocolVersion = clientProtocolVersion
        self.clientDescription = clientDescription
    }
}

/// The helper's answer to a `hello` it accepted.
///
/// A reply means the connection is open. A refusal is an `AeolusXPCFault`, not a
/// `HelloReply` carrying a "rejected" flag — there is no shape of this type that means
/// "no", so no caller can read one as "yes".
public struct HelloReply: Sendable, Hashable, Codable {
    /// What the helper speaks. Sent even on success so a client can report the skew
    /// precisely if a *later* message is refused.
    public let helperProtocolRange: ProtocolVersionRange
    /// The helper's own build identifier, for diagnostics. Display-grade: never parsed
    /// to decide behaviour, because that would be a second version vocabulary competing
    /// with `helperProtocolRange`.
    public let helperBuild: String
    /// Opaque, ignorable feature discovery. A capability may gate a convenience; it may
    /// **never** gate a safety mechanism. See `AeolusXPCVersion`'s bump policy.
    ///
    /// A client that does not recognise a capability ignores it. A client whose desired
    /// capability is absent does without it — it does not fall back to asking for the
    /// thing anyway and hoping.
    public let capabilities: [String]

    public init(
        helperProtocolRange: ProtocolVersionRange,
        helperBuild: String,
        capabilities: [String]
    ) {
        self.helperProtocolRange = helperProtocolRange
        self.helperBuild = helperBuild
        self.capabilities = capabilities
    }

    /// Whether the helper advertised `capability`. Convenience only, by construction:
    /// nothing safety-relevant may be behind this call.
    public func advertises(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }
}
