import Foundation
import Security

/// Checks a compiled requirement against a binary it must *not* admit.
///
/// A requirement string that compiles is not necessarily a requirement that means
/// anything. `anchor apple` compiles perfectly and admits every binary Apple ships. The
/// compile step catches syntax and nothing catches semantics, so this asserts the one
/// thing that must be true of any correct Aeolus client requirement: an Apple-signed
/// binary from Apple's own team is not an Aeolus client.
///
/// **What this covers, measured rather than assumed.** The probe is Apple-team platform
/// code, so the only requirements this control can catch are ones that admit Apple
/// platform binaries — the "collapsed into an Apple-wide requirement" class. Clause-level
/// damage does not reach it: a requirement that lost only its Team ID clause, or only its
/// certificate chain clauses, or that lost the parentheses around the identifier
/// disjunction, still rejects `/bin/ls` and this control stays silent. Those are caught by
/// the exact-match requirement text tests in `ClientRequirementTextTests`, which is where
/// a reader should look for clause-level coverage — not here.
///
/// Bounded and local by construction: one file on the boot volume, one
/// `SecStaticCodeCheckValidity` call with `.noNetworkAccess`, no network, no unbounded
/// wait.
struct RequirementNegativeControl: Sendable {
    /// A binary that is validly signed, is not ours, and exists on every Mac.
    static let systemProbePath = "/bin/ls"

    /// The flags every validity check in this module uses.
    ///
    /// `.noNetworkAccess` is what makes "bounded and local" true rather than merely
    /// intended: without it, validation may reach the network for revocation and
    /// notarization checks, and a root daemon's startup would then depend on the machine
    /// having working DNS. It also makes the result deterministic on CI. It can only make
    /// validation stricter, so it cannot turn a rejection into an admission.
    ///
    /// Named rather than inlined so that removing it is a visible edit to a documented
    /// constant with a test on it, instead of a silent deletion inside a call.
    static let validationFlags: SecCSFlags = .noNetworkAccess

    let probePath: String

    static let system = RequirementNegativeControl(probePath: systemProbePath)

    enum Outcome: Sendable, Hashable {
        /// The probe was rejected. The requirement discriminates, as it must.
        case rejectedProbe
        /// The probe was accepted. The requirement is broken.
        case admittedProbe
        /// The probe could not be evaluated. Inconclusive, which is not a pass.
        case probeUnavailable(OSStatus)
    }

    func evaluate(_ requirement: SecRequirement) -> Outcome {
        var probe: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: probePath) as CFURL,
            [],
            &probe
        )
        guard creationStatus == errSecSuccess, let probe else {
            return .probeUnavailable(creationStatus)
        }

        let validity = SecStaticCodeCheckValidity(probe, Self.validationFlags, requirement)
        // Only two statuses are conclusive. `errSecCSReqFailed` means the probe really was
        // evaluated against the requirement and really was rejected — that, and only that,
        // is the control passing. Every other failure means the probe was never evaluated
        // against the requirement at all: an unsigned or damaged probe reports
        // `errSecCSUnsigned` (-67062) long before the requirement is consulted, and
        // treating that as a rejection would let `anchor apple` — the module's own
        // canonical example of a broken requirement — sail through this check.
        // Inconclusive is not a pass; it is a refusal, decided by the caller.
        switch validity {
        case errSecSuccess: return .admittedProbe
        case errSecCSReqFailed: return .rejectedProbe
        default: return .probeUnavailable(validity)
        }
    }
}
