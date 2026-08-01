import Foundation

/// The bundle identifiers the helper will obey.
///
/// Two, and only two. A client that is not one of these is refused however it is signed,
/// so a same-team binary that is not Aeolus cannot command the daemon either.
enum AeolusClientIdentifier {
    static let app = "com.blamechris.Aeolus"
    static let commandLine = "com.blamechris.fanctl"

    /// Sorted so the requirement text is a deterministic function of its inputs — a
    /// requirement whose text depends on `Set` iteration order cannot be diffed or
    /// asserted on.
    static let all: [String] = [app, commandLine].sorted()
}

/// Which shape of requirement to build.
///
/// Deliberately **not** `public` or `package`. There is no API anywhere in Aeolus that
/// lets a caller ask for the relaxed variant: `ClientAuthorisation.resolveForRunningProcess()`
/// takes no arguments, and the selection below is a compile-time constant. The variant is
/// a property of the build, never of runtime data.
enum ClientRequirementVariant: Sendable, Hashable, CaseIterable {
    /// Developer ID chain only, and the client must not carry
    /// `com.apple.security.get-task-allow`.
    case release

    /// Additionally accepts Apple Development leaf certificates of the same team, and
    /// tolerates `get-task-allow`. Only ever selected by a Debug build — see
    /// `forRunningProcess`.
    case debug

    /// The variant a running Aeolus process uses.
    ///
    /// This is the **only** place a variant is chosen for production use. In a Release
    /// build the `.debug` branch is not compiled, so a Release helper cannot select the
    /// relaxed requirement even if a later edit made this property consult runtime state:
    /// there is no runtime state to consult, and the branch that would return `.debug`
    /// does not exist in the binary.
    ///
    /// Both arms are exercised on CI. A plain `swift test` builds Debug and takes the
    /// `.debug` branch; a second CI step runs
    /// `swift test -c release -Xswiftc -enable-testing` and takes the `.release` one. That
    /// second step is what catches this property being edited to return `.debug`
    /// unconditionally — a Release helper shipping the relaxed development requirement,
    /// which a Debug-only test run cannot see because the test mirrors the same `#if`.
    /// What neither can establish is that the resulting text admits the right binaries;
    /// that is E2.5's checklist item "an ad-hoc-built client is refused by the installed
    /// helper", on `Mac16,5`.
    static var forRunningProcess: ClientRequirementVariant {
        #if DEBUG
        return .debug
        #else
        return .release
        #endif
    }

    /// True when this variant accepts clients a Release helper must never accept.
    var isRelaxedForDevelopment: Bool {
        switch self {
        case .release: return false
        case .debug: return true
        }
    }
}

/// Why a Team ID was refused as a requirement input.
///
/// `package` rather than nested-and-internal only so `ClientAuthorisationRefusal` can
/// carry it into the helper's fault log; nothing outside this module produces one.
package enum TeamIdentifierRejection: Sendable, Hashable, Error {
    case empty
    case unacceptableCharacters
    case tooLong
}

/// Builds the code-signing requirement text, per
/// [ADR 0005](../../../docs/ADR/0005-xpc-authorisation.md).
///
/// A pure function of a Team ID and a variant: no I/O, no globals, no clock. Every row of
/// the fail-closed table and both variants are exhaustively testable on CI, which has no
/// signing identity. What CI can *never* test is whether the resulting text admits the
/// right binaries on real hardware — that needs a Developer ID signature and is E2.5's
/// manual checklist. Keep that line where it is: this file is the CI-testable half.
enum ClientRequirementText {

    /// Object identifiers from Apple's certificate policy extensions. Named rather than
    /// inlined because a transposed digit in an OID is invisible in a string literal but
    /// obvious in a constant with a name next to it.
    private enum OID {
        /// Developer ID Certification Authority, the intermediate in a Developer ID chain.
        static let developerIDIntermediate = "1.2.840.113635.100.6.2.6"
        /// Developer ID Application, the leaf of a Developer ID chain.
        static let developerIDLeaf = "1.2.840.113635.100.6.1.13"
        /// Apple Worldwide Developer Relations CA, the intermediate in a Development chain.
        static let appleDevelopmentIntermediate = "1.2.840.113635.100.6.2.1"
        /// Apple Development / Mac Developer, the leaf of a Development chain.
        static let appleDevelopmentLeaf = "1.2.840.113635.100.6.1.12"
    }

    /// The entitlement whose presence means the client's task port can be claimed by a
    /// debugger — and therefore that the client can be puppeted into commanding root.
    static let debuggableEntitlement = "com.apple.security.get-task-allow"

    /// The longest Team ID accepted. Apple issues ten characters; the cap exists so a
    /// pathological value cannot become a pathological requirement string, not to police
    /// a format Apple owns.
    static let maximumTeamIdentifierLength = 64

    /// Validates a Team ID before it is interpolated into a quoted requirement clause.
    ///
    /// The Team ID is read from the helper's *own* signature, so this is not untrusted
    /// input in the usual sense. It is validated anyway because the failure it prevents —
    /// a quote or backslash escaping the string literal and rewriting the requirement —
    /// is silent, and a requirement that parses into something other than what this file
    /// describes is precisely the defect the whole module exists to make impossible.
    ///
    /// What is checked is the character set, plus a generous length cap. What is
    /// deliberately *not* checked is the shape — Apple issues ten-character Team IDs today,
    /// and pinning that here would make every helper inert if Apple ever changed it, for no
    /// security gain: an ASCII-alphanumeric value cannot escape quoting at any length.
    static func validate(teamIdentifier: String) -> Result<String, TeamIdentifierRejection> {
        guard !teamIdentifier.isEmpty else { return .failure(.empty) }
        guard teamIdentifier.count <= maximumTeamIdentifierLength else { return .failure(.tooLong) }
        let acceptable = teamIdentifier.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
        guard acceptable else { return .failure(.unacceptableCharacters) }
        return .success(teamIdentifier)
    }

    /// Builds the requirement text, validating the Team ID on the way through.
    ///
    /// Validation is inside this function rather than beside it so there is no unvalidated
    /// path to a requirement string at all. There is deliberately no overload that skips
    /// it, because "build a requirement from whatever you have" is the call a tired reader
    /// would make at 2am.
    static func build(
        teamIdentifier: String,
        variant: ClientRequirementVariant
    ) -> Result<String, TeamIdentifierRejection> {
        validate(teamIdentifier: teamIdentifier).map { team in
            clauses(teamIdentifier: team, variant: variant).joined(separator: " and ")
        }
    }

    /// The clauses, in the order they appear in ADR 0005. Every clause narrows; none
    /// widens. A reader checking this against the ADR should be able to go line by line.
    private static func clauses(
        teamIdentifier: String,
        variant: ClientRequirementVariant
    ) -> [String] {
        var clauses = [
            "anchor apple generic",
            certificateChainClause(variant: variant),
            "certificate leaf[subject.OU] = \"\(teamIdentifier)\"",
            identifierClause(),
        ]
        if !variant.isRelaxedForDevelopment {
            clauses.append("!entitlement[\"\(debuggableEntitlement)\"]")
        }
        return clauses
    }

    /// Release pins the Developer ID chain outright. Debug additionally admits an Apple
    /// Development chain — the maintainer's local clients are Development-signed, and a
    /// Debug helper that refused them would simply not be usable during development.
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

    private static func identifierClause() -> String {
        let alternatives = AeolusClientIdentifier.all.map { "identifier \"\($0)\"" }
        return "(\(alternatives.joined(separator: " or ")))"
    }
}
