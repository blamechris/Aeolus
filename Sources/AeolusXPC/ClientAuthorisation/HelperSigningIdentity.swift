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

        // SecCodeRef and SecStaticCodeRef are the same C type. CSCommon.h declares them as
        //
        //     typedef struct __SecCode *SecCodeRef;
        //     typedef struct __SecCode const *SecStaticCodeRef;
        //
        // — one struct, differing only in constness — and the header documents a SecCodeRef
        // as usable wherever a SecStaticCodeRef is required. Swift imports them as two
        // unrelated classes, so the identity has to be restated. No allocation, no
        // ownership transfer: both sides are the same retained CFType.
        //
        // The alternative that avoids the cast is SecCodeCopyPath followed by
        // SecStaticCodeCreateWithPath, and it is worse here: it would read the binary on
        // disk rather than the running image, putting a time-of-check gap in exactly the
        // value the requirement is pinned to. A cast documented by the header beats a
        // supported API that answers a subtly different question.
        let staticCode = unsafeBitCast(selfCode, to: SecStaticCode.self)

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
