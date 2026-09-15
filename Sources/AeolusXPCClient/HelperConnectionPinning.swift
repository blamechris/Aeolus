import AeolusXPC
import Foundation

/// The single place a client connection acquires the requirement it pins on the helper.
///
/// The client-side twin of the helper's `ConnectionAdmission`, and it is a protocol for
/// the same reason: [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) names one small
/// type as the place a different mechanism would be swapped in if
/// `setCodeSigningRequirement` were ever found to misbehave on a supported macOS.
///
/// ## Why it makes the connection rather than being handed one
///
/// The obvious shape — `func requirement() throws -> String?`, applied by the caller — is
/// the shape `HelperRequirementPinning`'s own documentation records cutting in review. An
/// optional invites a caller that satisfies itself it is signed, builds a connection, and
/// never calls `setCodeSigningRequirement`; that connection reaches exactly the per-user
/// impostor ADR 0005 exists to exclude, and no type system can object to it, because a
/// `String?` is not a requirement.
///
/// So the requirement is resolved **before any connection object exists** and the two
/// steps cannot be separated: a conformer that cannot verify the helper throws, and there
/// is nothing to resume. What comes back is a connection that already carries whatever
/// requirement this policy applies — unresumed, so `HelperClient` can attach its handlers
/// before the first message can arrive.
///
/// ## What it deliberately does not admit
///
/// There is no conformer in `Sources/` that skips the requirement, and
/// `HelperClientSeamTests` asserts that by counting them. That is not an oversight: the
/// suite needs a client it can drive on CI with no signing identity, and the way it gets
/// one is by declaring its own conformer **in the test target**, where production code
/// cannot name it — exactly as `UnenforcedAdmission` does on the helper's side. A
/// "no requirement" type living here would be one mis-wired initialiser away from a client
/// that talks to whoever answered.
public protocol HelperConnectionPinning: Sendable {

    /// A new connection over `transport`, with this policy's requirement already applied
    /// and **not yet resumed**.
    ///
    /// - Throws: `HelperClientError.clientCannotVerifyHelper` when this client cannot
    ///   establish who it would be talking to. Thrown before a connection is constructed:
    ///   there is no degraded, unpinned connection to fall back to, because the fallback
    ///   would be trusting whoever answered.
    func pinnedConnection(over transport: HelperClientTransport) throws -> NSXPCConnection
}

/// Pins the helper with the requirement `HelperRequirementPinning` derives from this
/// process's own signature, compiles, and runs the negative control against.
///
/// The only string this type can pass to `setCodeSigningRequirement` is the sealed `text`
/// out of a `PinnedHelperRequirement`, which has no initialiser reachable from here.
/// That is load-bearing rather than tidy: ADR 0005's verification log measured a malformed
/// requirement raising an uncatchable `NSInvalidArgumentException` on a libxpc event
/// thread — SIGABRT, exit 134. In `Aeolus.app` that is a crash in the user's face on every
/// attempt to reach the helper, and the crash report names libxpc rather than the string
/// that caused it.
///
/// **`.failure(.runningProcessHasNoTeamIdentifier)` is the truthful answer under a
/// `Monitor` build, a plain `swift build`, and `swift test`**, so under all three this
/// client refuses to connect at all. ADR 0005 accepts that consequence explicitly: a
/// from-source client can never command an installed helper, reads never needed the helper,
/// and recovery without a signed client is `sudo launchctl bootout` per `docs/RECOVERY.md`.
public struct SignedHelperPinning: HelperConnectionPinning {

    public init() {}

    public func pinnedConnection(
        over transport: HelperClientTransport
    ) throws -> NSXPCConnection {
        // Resolved first, and the connection built only afterwards: a refusal must leave
        // nothing behind that could be resumed. It does file I/O for the negative control,
        // which is why it is once per connection object and never per message.
        switch HelperRequirementPinning.resolveForRunningProcess() {
        case .failure(let refusal):
            throw HelperClientError.clientCannotVerifyHelper(refusal)
        case .success(let requirement):
            let connection = transport.makeConnection()
            connection.setCodeSigningRequirement(requirement.text)
            return connection
        }
    }
}
