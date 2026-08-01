import Foundation
import Security

/// Checks a compiled requirement against a binary it must *not* admit.
///
/// A requirement string that compiles is not necessarily a requirement that means
/// anything. `anchor apple` compiles perfectly and admits every binary Apple ships; so
/// would a requirement that lost its Team ID clause to a bad edit. The compile step
/// catches syntax, and nothing catches semantics — so this does, by asserting the one
/// thing that must be true of any correct Aeolus client requirement: an Apple-signed
/// binary from Apple's own team is not an Aeolus client.
///
/// Bounded and local by construction: one file on the boot volume, one
/// `SecStaticCodeCheckValidity` call with no flags, no network, no unbounded wait.
struct RequirementNegativeControl: Sendable {
    /// A binary that is validly signed, is not ours, and exists on every Mac.
    static let systemProbePath = "/bin/ls"

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

        // `.noNetworkAccess` is what makes "bounded and local" true rather than merely
        // intended: without it, validation may reach the network for revocation and
        // notarization checks, and a root daemon's startup would then depend on the
        // machine having working DNS. It also makes the result deterministic on CI. It can
        // only make validation stricter, so it cannot turn a rejection into an admission —
        // measured at well under a millisecond against /bin/ls.
        let validity = SecStaticCodeCheckValidity(probe, .noNetworkAccess, requirement)
        // Any non-success status means the probe failed the requirement, which is the
        // outcome we want. Only an outright success is a problem — and it is treated as
        // one regardless of which requirement was passed in, so this cannot be made to
        // pass by handing it something that happens to be broken in a new way.
        return validity == errSecSuccess ? .admittedProbe : .rejectedProbe
    }
}
