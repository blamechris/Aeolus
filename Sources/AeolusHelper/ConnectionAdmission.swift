import AeolusXPC
import Foundation

/// What happens to a connection before it is configured: it is either admitted under a
/// code-signing requirement, or refused.
enum AdmissionDecision: Sendable, Hashable {
    /// The requirement was applied. `teamIdentifier` is for the log line and says which
    /// team the requirement pins — **not** who connected, which is not knowable here.
    case admitted(teamIdentifier: String)
    /// Nothing was configured and the delegate must return `false`.
    case refused(ClientAuthorisationRefusal)
}

/// The single place a connection acquires its code-signing requirement.
///
/// A protocol with exactly two conformers in `Sources/` — one that enforces a sealed
/// requirement, one that refuses everything — because
/// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) names the delegate as the place a
/// hand-rolled audit-token fallback would be swapped in if `setCodeSigningRequirement` is
/// ever found to misbehave on a supported macOS. Keeping that swap to one small type is
/// the reason this is a seam at all.
///
/// ## What it deliberately does not admit
///
/// There is no conformer in `Sources/` that skips the requirement. That is not an
/// oversight and it is not a `TODO`: this project's integration tests need a listener they
/// can drive on CI with no signing identity, and the way they get one is by declaring
/// their own conformer **in the test target**, where production code cannot name it. A
/// "no requirement" type living here would be one mis-wired initialiser away from a root
/// daemon that obeys anybody.
protocol ConnectionAdmission: Sendable {
    func admit(_ connection: NSXPCConnection) -> AdmissionDecision
}

/// Applies a requirement that `ClientAuthorisation` built, compiled, and ran the negative
/// control against.
///
/// The only string this type can pass to `setCodeSigningRequirement` is the sealed `text`
/// out of an `AuthorisedClientRequirement`, and that type has no initialiser reachable from
/// here. That is load-bearing rather than tidy: measured on `Mac16,5` / macOS 26.5.2, a
/// malformed requirement raises an uncatchable `NSInvalidArgumentException` **inside**
/// `listener(_:shouldAcceptNewConnection:)`, on a libxpc event thread — SIGABRT, exit 134.
/// In an on-demand root daemon that is an abort on every connection attempt: a denial of
/// service caused by a bad string rather than by an attacker. Nothing in this file builds,
/// concatenates, or defaults a requirement, and nothing in this target may start.
struct SealedRequirementAdmission: ConnectionAdmission {
    let requirement: AuthorisedClientRequirement

    func admit(_ connection: NSXPCConnection) -> AdmissionDecision {
        // Applied before `resume()` by the caller's ordering — refusal is the default,
        // acceptance the explicit act. Enforcement itself is per message, not at accept
        // time: this call configures the connection, it does not authenticate the peer.
        connection.setCodeSigningRequirement(requirement.text)
        return .admitted(teamIdentifier: requirement.teamIdentifier)
    }
}

/// Refuses every connection, because this helper could not establish who it should obey.
///
/// Every row of ADR 0005's fail-closed table lands here: no Team ID in the helper's own
/// signature, a requirement that would not compile, a startup negative control that fired
/// or could not be run. None of them degrades to a weaker requirement, because a weaker
/// requirement is the failure this whole module exists to prevent.
struct RefuseAllAdmission: ConnectionAdmission {
    let refusal: ClientAuthorisationRefusal

    func admit(_ connection: NSXPCConnection) -> AdmissionDecision {
        .refused(refusal)
    }
}

extension ClientAuthorisationOutcome {
    /// The admission policy for this outcome. A `switch` with no default, so a third
    /// outcome could not be added without this failing to compile.
    var admission: any ConnectionAdmission {
        switch self {
        case .enforce(let requirement):
            return SealedRequirementAdmission(requirement: requirement)
        case .refuseAll(let refusal):
            return RefuseAllAdmission(refusal: refusal)
        }
    }
}
