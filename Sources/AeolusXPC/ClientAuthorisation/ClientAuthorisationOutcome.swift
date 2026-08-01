import Foundation

/// A requirement string that has been built, compiled, and survived the negative control.
///
/// The type exists so that "I have a requirement to enforce" is a thing the type system
/// can express and the caller cannot fake. There is no initialiser reachable from outside
/// this file and no way to construct one from a bare string: the only producer is
/// `ClientAuthorisationBuilder`, and it produces one only after
/// `SecRequirementCreateWithString` accepted the text *and* the text refused a foreign
/// Apple-signed binary. A caller holding one of these therefore knows more than "somebody
/// concatenated a string".
///
/// `text` — not a compiled `SecRequirement` — is what crosses onward, because
/// `NSXPCConnection.setCodeSigningRequirement(_:)` takes a string and compiles it inside
/// libxpc. Compiling it here first is validation, not the enforcement path: it is how the
/// fail-closed row "never pass an uncompiled string onward" is honoured.
///
/// That row is load-bearing rather than tidy, and #72 measured why. A malformed
/// requirement makes `setCodeSigningRequirement` raise an uncatchable
/// `NSInvalidArgumentException` **inside `listener(_:shouldAcceptNewConnection:)`**, on a
/// libxpc event thread: SIGABRT, exit 134. In a launchd on-demand root daemon that is an
/// abort on every connection attempt — a denial of service caused by a bad string rather
/// than by an attacker. See [ADR 0005](../../../docs/ADR/0005-xpc-authorisation.md)'s
/// verification log.
public struct AuthorisedClientRequirement: Sendable, Hashable {
    /// The requirement, ready for `NSXPCConnection.setCodeSigningRequirement(_:)`.
    ///
    /// **The only string that may ever reach that call.** Nothing may build, concatenate,
    /// or default a requirement at the listener; see the type's documentation for what a
    /// malformed one does to a root daemon.
    public let text: String

    /// The Team ID the requirement pins, for logging. Read from the helper's own
    /// signature, never from a client or a config file.
    public let teamIdentifier: String

    /// True when this build's requirement admits Development-signed and debuggable
    /// clients. Always false in a Release build — see `ClientRequirementVariant`.
    public let isRelaxedForDevelopment: Bool

    /// Deliberately not `public`: see the type's documentation.
    fileprivate init(text: String, teamIdentifier: String, isRelaxedForDevelopment: Bool) {
        self.text = text
        self.teamIdentifier = teamIdentifier
        self.isRelaxedForDevelopment = isRelaxedForDevelopment
    }

    /// The one producer. `fileprivate` reach into `init` is why it lives here.
    static func sealed(
        text: String,
        teamIdentifier: String,
        variant: ClientRequirementVariant
    ) -> AuthorisedClientRequirement {
        AuthorisedClientRequirement(
            text: text,
            teamIdentifier: teamIdentifier,
            isRelaxedForDevelopment: variant.isRelaxedForDevelopment
        )
    }
}

/// Why the helper must refuse every connection.
///
/// Every case is terminal. None of them degrades into a weaker requirement, because a
/// weaker requirement is the failure mode this module exists to prevent.
public enum ClientAuthorisationRefusal: Sendable, Hashable {
    /// The helper's own signature carries no Team ID: it is ad-hoc signed or unsigned, so
    /// "signed by whoever signed me" names nobody. An accidentally ad-hoc-signed helper is
    /// inert by construction rather than by vigilance.
    case helperHasNoTeamIdentifier

    /// The Security framework would not describe this process at all.
    case selfInspectionFailed(OSStatus)

    /// The Team ID read from our own signature could not be safely quoted into a
    /// requirement clause.
    case teamIdentifierNotWellFormed(TeamIdentifierRejection)

    /// `SecRequirementCreateWithString` rejected the text. The text is discarded here and
    /// never handed onward — an uncompilable requirement passed to libxpc would be an
    /// error at connection time at best, and this module's whole job is to not find that
    /// out later.
    case requirementDidNotCompile(OSStatus)

    /// The negative control could not be run: the probe binary was missing or unreadable.
    /// Inconclusive is not the same as passing, so it refuses.
    case negativeControlUnavailable(OSStatus)

    /// The negative control fired. An Apple-signed binary from another team satisfied the
    /// requirement, so the requirement does not mean what this file says it means. This is
    /// the loudest failure in the module.
    case negativeControlAdmittedForeignCode
}

/// The result of deciding who this helper will talk to.
///
/// Two cases, no third, and no optional to forget to unwrap: a caller must switch, and the
/// only branch that yields a requirement yields one that has already been validated.
/// Refusal is what is left when acceptance was not explicitly earned.
public enum ClientAuthorisationOutcome: Sendable, Hashable {
    /// Enforce this requirement on every connection before resuming it.
    case enforce(AuthorisedClientRequirement)

    /// Refuse every connection, and say why in the log.
    case refuseAll(ClientAuthorisationRefusal)

    /// Convenience for assertions and for logging. Never use this in place of the switch:
    /// a caller that treats `false` as "carry on without a requirement" has inverted the
    /// entire point.
    public var permitsAnyConnection: Bool {
        switch self {
        case .enforce: return true
        case .refuseAll: return false
        }
    }
}

extension ClientAuthorisationRefusal: CustomStringConvertible {
    public var description: String {
        switch self {
        case .helperHasNoTeamIdentifier:
            return
                "the helper's own signature carries no Team ID (ad-hoc signed or unsigned)"
        case .selfInspectionFailed(let status):
            return "could not read the helper's own code signature (OSStatus \(status))"
        case .teamIdentifierNotWellFormed(let rejection):
            return "the helper's own Team ID is not usable in a requirement (\(rejection))"
        case .requirementDidNotCompile(let status):
            return "the requirement text did not compile (OSStatus \(status))"
        case .negativeControlUnavailable(let status):
            return "the startup negative control could not run (OSStatus \(status))"
        case .negativeControlAdmittedForeignCode:
            return
                "the startup negative control fired: an Apple-signed binary from another "
                + "team satisfied the requirement, so the requirement is broken"
        }
    }
}
