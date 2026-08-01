import Foundation
import Security
import os

/// Decides which clients the privileged helper will obey, per
/// [ADR 0005](../../../docs/ADR/0005-xpc-authorisation.md).
///
/// The mechanism is `NSXPCConnection.setCodeSigningRequirement(_:)`: enforcement happens
/// inside libxpc, keyed on the connection's audit token, before any message is delivered.
/// PID-based identity was rejected outright (PID reuse, exec-after-check); hand-rolled
/// audit-token validation remains the documented fallback behind this same seam. The
/// residual risk of the chosen mechanism is a *wrong requirement string*, which is why
/// everything that produces one lives here, is pure, and is tested row by row.
///
/// ## What this module is not
///
/// It does not touch `NSXPCConnection`, `NSXPCListener`, or any live connection. Wiring
/// this outcome into `listener(_:shouldAcceptNewConnection:)` is E2.3's work. The split is
/// deliberate: the decision is testable without a listener, and the listener has one
/// decision to consult rather than a policy to re-derive.
///
/// ## What CI can and cannot verify — read this before adding a test
///
/// CI can verify the **builder** exhaustively, and does: both variants of the requirement
/// text, every fail-closed row, the negative control including a mutation that makes it
/// fire. All of that runs with no signing identity and no SMC.
///
/// CI can **never** verify the production requirement itself. Proving that the text admits
/// the real Aeolus.app and the real `fanctl`, and refuses everything else, needs a
/// Developer ID signature — which exists on exactly one machine. That check is E2.5's
/// manual `Mac16,5` checklist, whose load-bearing item is "an ad-hoc-built client is
/// refused by the installed helper". A green CI run says the builder is correct. It does
/// not say the boundary holds.
package enum ClientAuthorisation {

    private static let log = Logger(
        subsystem: "dev.aeolus.AeolusXPC",
        category: "ClientAuthorisation"
    )

    /// Decides the policy for this process, reading this process's own signature.
    ///
    /// Takes no arguments on purpose. A caller cannot select the relaxed Debug variant,
    /// cannot supply a Team ID, and cannot substitute the negative control, so no call site
    /// anywhere can weaken the requirement — the worst a caller can do is mishandle the
    /// answer, and the answer is an enum with no optional to drop and no default to fall
    /// through to.
    ///
    /// Intended to be called once at startup and the result held; it does file I/O for the
    /// negative control and should not be on a per-connection path.
    package static func resolveForRunningProcess() -> ClientAuthorisationOutcome {
        let outcome = ClientAuthorisationBuilder.build(
            inspection: HelperSigningIdentity.system.inspect(),
            variant: .forRunningProcess,
            negativeControl: .system
        )
        record(outcome)
        return outcome
    }

    private static func record(_ outcome: ClientAuthorisationOutcome) {
        switch outcome {
        case .enforce(let requirement):
            log.notice(
                """
                Client authorisation active for team \
                \(requirement.teamIdentifier, privacy: .public), \
                development relaxation: \
                \(requirement.isRelaxedForDevelopment, privacy: .public)
                """
            )
        case .refuseAll(let refusal):
            // Fault level: this is not a degraded mode, it is a helper that will obey
            // nobody. Someone reading `log show` after "Aeolus does nothing" must find
            // this without knowing to look for it.
            log.fault(
                """
                Refusing all XPC connections — \(refusal.description, privacy: .public)
                """
            )
        }
    }
}

/// The pure half: everything from a Team ID to a validated requirement, with no ambient
/// input. Exposed as its own type so tests can drive every branch by argument rather than
/// by arranging the world.
enum ClientAuthorisationBuilder {

    /// Builds the policy.
    ///
    /// Refusal is the default and acceptance the explicit act: the function has exactly
    /// one `return .enforce(...)`, it is the last statement, and every step before it can
    /// only either continue or refuse. Adding a step cannot accidentally skip the
    /// remaining ones.
    static func build(
        inspection: SelfSigningInspection,
        variant: ClientRequirementVariant,
        negativeControl: RequirementNegativeControl
    ) -> ClientAuthorisationOutcome {
        let team: String
        switch inspection {
        case .teamIdentifier(let value): team = value
        case .noTeamIdentifier: return .refuseAll(.helperHasNoTeamIdentifier)
        case .inspectionFailed(let status): return .refuseAll(.selfInspectionFailed(status))
        }

        switch ClientRequirementText.validate(teamIdentifier: team) {
        case .failure(let rejection):
            return .refuseAll(.teamIdentifierNotWellFormed(rejection))
        case .success:
            break
        }

        guard let text = ClientRequirementText.build(teamIdentifier: team, variant: variant)
        else {
            // Unreachable while `build` and `validate` agree on what a usable Team ID is.
            // Kept as a refusal rather than a `fatalError` because a root daemon that
            // crashes on a policy question is worse than one that obeys nobody.
            return .refuseAll(.teamIdentifierNotWellFormed(.unacceptableCharacters))
        }

        return seal(
            text: text,
            teamIdentifier: team,
            variant: variant,
            negativeControl: negativeControl
        )
    }

    /// Compiles the text, runs the negative control, and only then seals it.
    ///
    /// Split out so the "did not compile" and "negative control fired" rows of the
    /// fail-closed table are reachable from a test: the production path above cannot
    /// produce text that fails either check — which is the point, and also why those two
    /// branches would otherwise never be executed by anything.
    ///
    /// Internal, and the only production caller is `build` immediately above, so no code
    /// outside this file can seal text of its own choosing.
    static func seal(
        text: String,
        teamIdentifier: String,
        variant: ClientRequirementVariant,
        negativeControl: RequirementNegativeControl
    ) -> ClientAuthorisationOutcome {
        var compiled: SecRequirement?
        let compileStatus = SecRequirementCreateWithString(text as CFString, [], &compiled)
        guard compileStatus == errSecSuccess, let compiled else {
            return .refuseAll(.requirementDidNotCompile(compileStatus))
        }

        switch negativeControl.evaluate(compiled) {
        case .rejectedProbe:
            break
        case .admittedProbe:
            return .refuseAll(.negativeControlAdmittedForeignCode)
        case .probeUnavailable(let status):
            return .refuseAll(.negativeControlUnavailable(status))
        }

        return .enforce(
            AuthorisedClientRequirement.sealed(
                text: text,
                teamIdentifier: teamIdentifier,
                variant: variant
            )
        )
    }
}
