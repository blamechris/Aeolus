import AeolusXPC
import Foundation

/// Decides what happens to every inbound connection, and wires the one that is accepted.
///
/// Four things happen here and nowhere else, in this order:
///
/// 1. The connection is either admitted under a code-signing requirement or refused.
///    Refusal is the default and acceptance the explicit act — the function has exactly
///    one `return true`, it is the last statement, and every step before it can only
///    continue or refuse.
/// 2. It is given a `ConnectionID`, which is minted here and is the only identity the
///    layers below ever see.
/// 3. Its interruption and invalidation handlers are attached **before** `resume()`, so a
///    connection that dies between being configured and being resumed still reaches the
///    seam.
/// 4. It is resumed.
///
/// ## The invalidation handler is a safety mechanism, not bookkeeping
///
/// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) gives the lease two independent
/// teardown paths — connection death and the TTL — and requires that they share no code
/// path. This handler is the first of the two. It is what covers a client that crashed,
/// was `SIGKILL`ed, or logged out, within milliseconds, because the kernel tears the mach
/// port down regardless of how the process died.
///
/// It is wired in E2, when `ReadOnlyFanAuthority.connectionDidInvalidate(_:)` does nothing
/// with it, because the alternative is E5 having to edit this file to implement half of a
/// safety mechanism — and this delegate is the highest-review-bar code in the repository
/// precisely so that it is not edited often.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {

    /// Advertised in every `HelloReply`, and the only place a capability string is minted.
    ///
    /// `"ordered-messages"` says this helper honours the per-connection ordering
    /// `AeolusXPCProtocol` states, so a client that pipelines `hello` and `snapshot` can
    /// confirm afterwards that the helper it reached is one that permits it — and remember
    /// it for the next connection. It cannot be consulted *before* pipelining, because the
    /// reply carrying it is the round trip pipelining exists to skip; that is why the
    /// contract also names the fallback (`handshakeRequired` on the pipelined message is
    /// retryable, not fatal) rather than resting on this string.
    ///
    /// A capability is feature discovery and never authorisation: nothing in the helper
    /// reads this back, and no gate consults it. Adding a string here is additive under the
    /// bump policy, so ``AeolusXPCVersion/current`` does not move.
    static let advertisedCapabilities = ["ordered-messages"]

    private let admission: any ConnectionAdmission
    private let authority: any FanAuthority
    private let helperBuild: String
    private let log: HelperLog

    init(
        admission: any ConnectionAdmission,
        authority: any FanAuthority,
        helperBuild: String,
        log: HelperLog
    ) {
        self.admission = admission
        self.authority = authority
        self.helperBuild = helperBuild
        self.log = log
    }

    /// Convenience for `main`: the production wiring, from the outcome
    /// `ClientAuthorisation` resolved.
    convenience init(
        authorisation: ClientAuthorisationOutcome,
        authority: any FanAuthority,
        helperBuild: String,
        log: HelperLog
    ) {
        self.init(
            admission: authorisation.admission,
            authority: authority,
            helperBuild: helperBuild,
            log: log
        )
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let teamIdentifier: String
        switch admission.admit(connection) {
        case .refused(let refusal):
            log.refusedConnection(refusal)
            return false
        case .admitted(let team):
            teamIdentifier = team
        }

        let id = ConnectionID()
        let session = HelperConnectionSession(
            id: id,
            authority: authority,
            helperBuild: helperBuild,
            capabilities: Self.advertisedCapabilities,
            log: log
        )

        connection.exportedInterface = NSXPCInterface(with: AeolusXPCProtocol.self)
        connection.exportedObject = HelperXPCService(session: session)

        // Both handlers are attached before resume(). A connection resumed first could be
        // torn down before it had somewhere to report that, and the report is the safety
        // mechanism.
        connection.interruptionHandler = { [log] in
            log.connectionInterrupted(id)
        }
        connection.invalidationHandler = {
            // Detached rather than an implicit child of whatever context libxpc calls this
            // on: the connection is already gone, and this work must not be cancelled by
            // the disappearance of the thing that scheduled it.
            Task.detached { await session.invalidate() }
        }

        connection.resume()
        log.acceptedConnection(id, teamIdentifier: teamIdentifier)
        return true
    }
}
