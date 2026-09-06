import Foundation

/// Builds the code-signing requirement a **client** pins on its connection to the helper,
/// per [ADR 0005](../../../docs/ADR/0005-xpc-authorisation.md): *"clients set the mirror
/// requirement on their side and always connect `.privileged`, so a per-user impostor
/// agent squatting the mach name is unreachable."*
///
/// The mirror of `ClientRequirementText`, and deliberately not a parameterisation of it.
/// The two requirements answer different questions — *may this peer command root?* versus
/// *is this peer the daemon we shipped?* — and they differ in the one clause a shared
/// builder would have to make configurable: the set of identifiers admitted. Sharing that
/// switch would mean one function that can produce either requirement, which is one
/// argument away from a client pinning a client.
///
/// What is shared instead is everything that must not drift: `ClientRequirementText.OID`,
/// `ClientRequirementText.debuggableEntitlement`, `ClientRequirementText.validate`, and
/// `ClientRequirementVariant`. One table of OIDs, one validator, one variant selector.
///
/// Pure, like its sibling: no I/O, no globals, no clock, and exhaustively testable on CI,
/// which has no signing identity. What CI can never test is whether the resulting text
/// admits the *installed* helper — that needs a Developer ID signature and is E2.5's
/// manual `Mac16,5` checklist.
///
/// There is no production caller yet, by design. The `NSXPCConnection` that will use this
/// belongs to the `AeolusXPCClient` target (#158), which is deliberately not this module:
/// `AeolusXPC` is linked by the root daemon, and connection construction does not belong
/// in the module the privilege boundary is fingerprinted from.
enum HelperRequirementText {

    /// One table, next door. See `ClientRequirementText.OID` for why it is named at all.
    private typealias OID = ClientRequirementText.OID

    /// The helper's code-signing identifier.
    ///
    /// Fixed by `project.yml`, in two places that must agree: the `AeolusHelper` target's
    /// `PRODUCT_BUNDLE_IDENTIFIER` and the `CFBundleIdentifier` of the Info.plist embedded
    /// in the binary. A command-line tool has nowhere else to put a plist, and that plist
    /// exists for this one reason — left to `codesign`'s default the identifier would be
    /// derived from the file name, which is a weaker thing for a client to pin.
    ///
    /// Nothing links this literal to the build definition at compile time, so
    /// `HelperIdentifierDriftTests` reads `project.yml` and asserts both values against it.
    /// A drift here is silent in the worst way: the helper still installs, the client still
    /// connects, and the pin refuses the very daemon it was written to trust.
    static let helperIdentifier = "com.blamechris.Aeolus.Helper"

    /// Builds the requirement text, validating the Team ID on the way through.
    ///
    /// Validation is inside this function rather than beside it, for the reason its sibling
    /// gives: there must be no unvalidated path to a requirement string, and no overload
    /// that skips it. The Team ID is read from the *client's own* signature, so this is not
    /// untrusted input in the usual sense; it is validated anyway because a quote or
    /// backslash escaping the string literal would rewrite what the requirement means, and
    /// would do it silently.
    static func build(
        teamIdentifier: String,
        variant: ClientRequirementVariant
    ) -> Result<String, TeamIdentifierRejection> {
        ClientRequirementText.validate(teamIdentifier: teamIdentifier).map { team in
            clauses(teamIdentifier: team, variant: variant).joined(separator: " and ")
        }
    }

    /// The clauses, in the order ADR 0005 gives them. Every clause narrows; none widens. A
    /// reader checking this against the ADR should be able to go line by line, and against
    /// `ClientRequirementText.clauses` side by side.
    private static func clauses(
        teamIdentifier: String,
        variant: ClientRequirementVariant
    ) -> [String] {
        var clauses = [
            "anchor apple generic",
            certificateChainClause(variant: variant),
            "certificate leaf[subject.OU] = \"\(teamIdentifier)\"",
            "identifier \"\(helperIdentifier)\"",
        ]
        if !variant.isRelaxedForDevelopment {
            clauses.append("!entitlement[\"\(ClientRequirementText.debuggableEntitlement)\"]")
        }
        return clauses
    }

    /// Release pins the Developer ID chain outright. Debug additionally admits an Apple
    /// Development chain, because the helper a developer builds and installs locally is
    /// Development-signed and a Debug client that refused it could not be used at all.
    ///
    /// The Development disjunct pins its own intermediate rather than only swapping the
    /// leaf OID, so the relaxation stays a second complete chain rather than a hole in the
    /// first one. `anchor apple generic` and the Team ID clause still apply to both.
    private static func certificateChainClause(variant: ClientRequirementVariant) -> String {
        let developerID = """
            certificate 1[field.\(OID.developerIDIntermediate)] \
            and certificate leaf[field.\(OID.developerIDLeaf)]
            """
        guard variant.isRelaxedForDevelopment else { return developerID }
        let appleDevelopment = """
            certificate 1[field.\(OID.appleDevelopmentIntermediate)] \
            and certificate leaf[field.\(OID.appleDevelopmentLeaf)]
            """
        return "((\(developerID)) or (\(appleDevelopment)))"
    }
}
