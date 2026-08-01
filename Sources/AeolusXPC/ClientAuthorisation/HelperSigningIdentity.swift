import Foundation
import Security

/// What reading this process's own code signature produced.
enum SelfSigningInspection: Sendable, Hashable {
    /// The process is signed and its signature carries a Team ID.
    case teamIdentifier(String)
    /// The process is ad-hoc signed or unsigned: a signature may exist, but there is no
    /// Team ID in it, so "signed by whoever signed me" names nobody.
    case noTeamIdentifier
    /// The Security framework refused to describe this process at all.
    case inspectionFailed(OSStatus)
}

/// Reads the Team ID out of the running process's own signature.
///
/// This is the one impure input to the whole module. It carries no injection seam of its
/// own on purpose: `ClientAuthorisationBuilder.build` takes a `SelfSigningInspection` as a
/// parameter, so every test drives the interesting cases by argument, and a second way to
/// substitute a Team ID would be a second thing that could be substituted in production.
///
/// Under `swift test` the host is always ad-hoc signed, so this returns `.noTeamIdentifier`
/// on CI and on the maintainer's machine alike. That is not a gap in the tests — it is the
/// fail-closed row "the helper is ad-hoc signed" being exercised by the test runner itself,
/// for free, on every CI run.
enum HelperSigningIdentity {

    /// `SecCodeCopySelf` → `SecCodeCopySigningInformation` → `kSecCodeInfoTeamIdentifier`.
    static func inspect() -> SelfSigningInspection {
        var selfCode: SecCode?
        let copyStatus = SecCodeCopySelf([], &selfCode)
        guard copyStatus == errSecSuccess, let selfCode else {
            return .inspectionFailed(copyStatus)
        }

        // SecCodeCopySigningInformation wants a SecStaticCodeRef. Passing the SecCodeRef
        // straight in would work — CSCommon.h says a SecCodeRef supplied where a
        // SecStaticCodeRef is expected "performs an implicit SecCodeCopyStaticCode call and
        // operates on the result" — but Swift imports the two as unrelated classes, so
        // saying so would take an unsafeBitCast. This is that same implicit call, made
        // explicitly, through the API that exists for it.
        //
        // It buys no TOCTOU protection and does not claim to: the implicit conversion and
        // this explicit one are the same operation, and SecCodeCopySigningInformation's own
        // documentation notes that for Code objects some of the returned information comes
        // from disk regardless. Measured both ways in one process: identical status,
        // identical dictionaries. What it buys is one fewer unsafeBitCast in code that runs
        // as root.
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(selfCode, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return .inspectionFailed(staticStatus)
        }

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard informationStatus == errSecSuccess else {
            return .inspectionFailed(informationStatus)
        }
        guard let attributes = information as? [String: Any] else {
            // Success with a dictionary we cannot read. Reported as a failure to inspect,
            // not as "no Team ID": we did not establish that there is no Team ID, we
            // failed to look, and the fault log should say which. `errSecSuccess` is
            // deliberately not the status carried here — "failed with OSStatus 0" is the
            // kind of log line that sends a reader down the wrong path.
            return .inspectionFailed(errSecCSInternalError)
        }

        guard
            let team = attributes[kSecCodeInfoTeamIdentifier as String] as? String,
            !team.isEmpty
        else {
            return .noTeamIdentifier
        }
        return .teamIdentifier(team)
    }
}
