/// What a client said about itself when its handshake succeeded.
///
/// **Self-described, never verified.** The description has been through
/// `AeolusXPCValidation.validateClientDescription(_:)` — bounded in characters and in
/// bytes, no control characters, no bidirectional overrides — so it is safe to put in a
/// log line. That is a different claim from knowing who the client is. What authorises a
/// client is the code-signing requirement libxpc enforces, and that never yields a name to
/// this layer.
///
/// Declared in its own file rather than beside `HelperConnectionSession`, so that everything
/// at member indent in `HelperConnectionSession.swift` is a member of the actor.
/// `HelperConnectionSessionAccessTests` reads that indent to decide what has been widened,
/// and a second type in the file would put three declarations it cannot classify in front
/// of it.
struct NegotiatedClient: Sendable, Hashable {
    let protocolVersion: Int
    let clientDescription: String

    var logDescription: String { "\"\(clientDescription)\" (v\(protocolVersion))" }
}
