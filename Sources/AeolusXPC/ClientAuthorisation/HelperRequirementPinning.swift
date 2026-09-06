import Foundation
import Security

/// A helper-pinning requirement that has been built, compiled, and survived the negative
/// control.
///
/// The client-side twin of `AuthorisedClientRequirement`, and it exists for the same
/// reason: *"I have a requirement to enforce"* should be a thing the type system can
/// express and the caller cannot fake. There is no initialiser reachable from outside this
/// file and no way to make one from a bare string, so a caller holding one knows more than
/// "somebody concatenated a string".
///
/// `text` — not a compiled `SecRequirement` — is what crosses onward, because
/// `NSXPCConnection.setCodeSigningRequirement(_:)` takes a string and compiles it inside
/// libxpc. Compiling it here first is validation, not the enforcement path; it is how
/// "never pass an uncompiled string onward" is honoured on this side of the connection.
///
/// That row is load-bearing on the client side too, and for a different reason than on the
/// helper's. ADR 0005's verification log measured a malformed requirement raising an
/// uncatchable `NSInvalidArgumentException` on a libxpc event thread: SIGABRT, exit 134.
/// In the root daemon that is a denial of service; in `Aeolus.app` it is a crash in the
/// user's face on every attempt to reach the helper, and the crash report names libxpc
/// rather than the string that caused it.
public struct PinnedHelperRequirement: Sendable, Hashable {
    /// The requirement, ready for `NSXPCConnection.setCodeSigningRequirement(_:)`.
    ///
    /// **The only string that may ever reach that call.** Nothing may build, concatenate,
    /// or default a requirement at the connection.
    public let text: String

    /// The Team ID the requirement pins, for logging. Read from the *client's own*
    /// signature — same-team-as-self, never a literal in the repository and never a value
    /// from a config file.
    public let teamIdentifier: String

    /// True when this build's requirement admits a Development-signed and debuggable
    /// helper. Always false in a Release build — see `ClientRequirementVariant`.
    public let isRelaxedForDevelopment: Bool

    /// Deliberately not `public`: see the type's documentation.
    fileprivate init(text: String, teamIdentifier: String, isRelaxedForDevelopment: Bool) {
        self.text = text
        self.teamIdentifier = teamIdentifier
        self.isRelaxedForDevelopment = isRelaxedForDevelopment
    }

    /// The one producer. The `fileprivate` reach into `init` is why it lives here.
    fileprivate static func sealed(
        text: String,
        teamIdentifier: String,
        variant: ClientRequirementVariant
    ) -> PinnedHelperRequirement {
        PinnedHelperRequirement(
            text: text,
            teamIdentifier: teamIdentifier,
            isRelaxedForDevelopment: variant.isRelaxedForDevelopment
        )
    }
}

/// Why a client cannot pin the helper, and must therefore not connect to it.
///
/// Every case is terminal. None of them degrades into a weaker requirement or into an
/// unpinned connection: a client that cannot establish who it is talking to has nothing
/// safe to fall back to, because the fallback would be trusting whoever answered.
public enum HelperPinningRefusal: Sendable, Hashable, Error {
    /// This process's signature carries no Team ID: it is ad-hoc signed or unsigned, so
    /// "the helper signed by whoever signed me" names nobody.
    ///
    /// This is the ordinary outcome of a `Monitor` build, a `swift build`, and `swift
    /// test`, and ADR 0005 already accepts its consequence: a from-source `fanctl` can
    /// never command an installed helper. Reads never needed the helper; recovery without
    /// a signed client is `sudo launchctl bootout`, per `docs/RECOVERY.md`.
    case runningProcessHasNoTeamIdentifier

    /// The Security framework would not describe this process at all. Distinct from the
    /// case above: we did not establish that there is no Team ID, we failed to look.
    case selfInspectionFailed(OSStatus)

    /// The Team ID read from our own signature could not be safely quoted into a
    /// requirement clause.
    case teamIdentifierNotWellFormed(TeamIdentifierRejection)

    /// `SecRequirementCreateWithString` rejected the text. The text is discarded here and
    /// never handed onward; see `PinnedHelperRequirement` for what happens when it is not.
    case requirementDidNotCompile(OSStatus)

    /// The negative control could not be run. Inconclusive is not the same as passing.
    case negativeControlUnavailable(OSStatus)

    /// The negative control fired: an Apple-signed binary from another team satisfied the
    /// requirement, so the requirement does not pin the helper — it pins "something Apple
    /// signed", which is the impostor case this whole mechanism exists to exclude.
    case negativeControlAdmittedForeignCode
}

/// Derives the requirement a client pins on the helper, from the client's own signature.
///
/// The public face of this file, and deliberately the smallest one that lets the future
/// `AeolusXPCClient` target work without seeing anything `internal`. Two entry points, and
/// neither takes a Team ID or a variant: a caller cannot select the relaxed Debug shape,
/// cannot supply a foreign team, and cannot substitute the negative control. The worst a
/// caller can do is mishandle the answer, and the answer is a `Result` with no optional to
/// drop and no default to fall through to.
///
/// `resolveForRunningProcess()` does file I/O for the negative control. Call it once when
/// a connection is established and hold the result; it is not a per-message path.
public enum HelperRequirementPinning {

    /// The Team ID this process can prove, or `nil` when it can prove none.
    ///
    /// **`nil` is the truthful answer under a `Monitor` build, a plain `swift build`, and
    /// `swift test`** — every build produced without a Developer ID, which is every build
    /// on CI and most builds on the development machine. A Developer ID-signed host is the
    /// only place this returns a value, and no test may fabricate one.
    ///
    /// The consequence, which ADR 0005 accepts explicitly: a client that cannot verify
    /// itself cannot derive the helper's requirement, so it refuses to connect at all
    /// rather than connecting unpinned. A `swift build` `fanctl` can never command an
    /// installed helper. That is the mechanism working, and a client showing this to a user
    /// should say so — an unsigned build, not a missing daemon.
    ///
    /// Deliberately collapses `SelfSigningInspection`'s two failures into one `nil`. They
    /// differ in the log line and not in the action: whether we established that there is
    /// no Team ID or merely failed to look, the client has nothing to pin with. A caller
    /// wanting the distinction should use `resolveForRunningProcess()`, which keeps it.
    public static func teamIdentifierForRunningProcess() -> String? {
        switch HelperSigningIdentity.inspect() {
        case .teamIdentifier(let value): return value
        case .noTeamIdentifier, .inspectionFailed: return nil
        }
    }

    /// Derives, compiles and seals the requirement for this process.
    ///
    /// Refusal is the default and pinning the explicit act: there is exactly one path to a
    /// `PinnedHelperRequirement`, it runs last, and every step before it can only continue
    /// or refuse.
    public static func resolveForRunningProcess() -> Result<
        PinnedHelperRequirement, HelperPinningRefusal
    > {
        let team: String
        switch HelperSigningIdentity.inspect() {
        case .teamIdentifier(let value): team = value
        case .noTeamIdentifier: return .failure(.runningProcessHasNoTeamIdentifier)
        case .inspectionFailed(let status): return .failure(.selfInspectionFailed(status))
        }
        return seal(
            teamIdentifier: team,
            variant: .forRunningProcess,
            negativeControl: .system
        )
    }

    /// Validates the Team ID, builds the text, and seals it.
    ///
    /// Internal, and its only production caller is `resolveForRunningProcess` above, so no
    /// code outside this module can choose a team or a variant.
    static func seal(
        teamIdentifier: String,
        variant: ClientRequirementVariant,
        negativeControl: RequirementNegativeControl
    ) -> Result<PinnedHelperRequirement, HelperPinningRefusal> {
        switch HelperRequirementText.build(teamIdentifier: teamIdentifier, variant: variant) {
        case .failure(let rejection):
            return .failure(.teamIdentifierNotWellFormed(rejection))
        case .success(let text):
            return seal(
                text: text,
                teamIdentifier: teamIdentifier,
                variant: variant,
                negativeControl: negativeControl
            )
        }
    }

    /// Compiles the text, runs the negative control, and only then seals it.
    ///
    /// Split out for the reason its sibling is: the "did not compile" and "negative control
    /// fired" rows are otherwise unreachable from a test, because the path above cannot
    /// produce text that fails either check. That is the point of the path above, and also
    /// why those two branches would never be executed by anything.
    ///
    /// The negative control matters as much here as on the helper's side, and against a
    /// closer threat. A requirement that compiled but collapsed into `anchor apple` would
    /// let a client trust any Apple-signed process that reached the mach name first — the
    /// per-user impostor ADR 0005 names. Compilation catches syntax; nothing but a probe
    /// catches that.
    static func seal(
        text: String,
        teamIdentifier: String,
        variant: ClientRequirementVariant,
        negativeControl: RequirementNegativeControl
    ) -> Result<PinnedHelperRequirement, HelperPinningRefusal> {
        var compiled: SecRequirement?
        let compileStatus = SecRequirementCreateWithString(text as CFString, [], &compiled)
        guard compileStatus == errSecSuccess, let compiled else {
            return .failure(.requirementDidNotCompile(compileStatus))
        }

        switch negativeControl.evaluate(compiled) {
        case .rejectedProbe:
            break
        case .admittedProbe:
            return .failure(.negativeControlAdmittedForeignCode)
        case .probeUnavailable(let status):
            return .failure(.negativeControlUnavailable(status))
        }

        return .success(
            PinnedHelperRequirement.sealed(
                text: text,
                teamIdentifier: teamIdentifier,
                variant: variant
            )
        )
    }
}

extension HelperPinningRefusal: CustomStringConvertible {
    public var description: String {
        switch self {
        case .runningProcessHasNoTeamIdentifier:
            return
                "this build carries no Team ID (ad-hoc signed or unsigned), so it cannot "
                + "verify the helper it is talking to"
        case .selfInspectionFailed(let status):
            return "could not read this process's own code signature (OSStatus \(status))"
        case .teamIdentifierNotWellFormed(let rejection):
            return "this process's own Team ID is not usable in a requirement (\(rejection))"
        case .requirementDidNotCompile(let status):
            return "the helper requirement text did not compile (OSStatus \(status))"
        case .negativeControlUnavailable(let status):
            return "the helper requirement's negative control could not run (OSStatus \(status))"
        case .negativeControlAdmittedForeignCode:
            return
                "the helper requirement's negative control fired: an Apple-signed binary "
                + "from another team satisfied it, so the requirement pins nothing"
        }
    }
}
