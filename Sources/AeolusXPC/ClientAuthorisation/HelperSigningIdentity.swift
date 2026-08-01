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
/// This is the one impure input to the whole module, which is why it is a value with a
/// swappable closure rather than a free function: every test in `ClientAuthorisationTests`
/// that needs a Team ID injects one, and the single test that exercises the real reader
/// asserts on whatever the host honestly is.
///
/// Under `swift test` the host is always ad-hoc signed, so the real reader returns
/// `.noTeamIdentifier` on CI and on the maintainer's machine alike. That is not a gap in
/// the tests — it is the fail-closed row "helper is ad-hoc signed" being exercised by the
/// test runner itself, for free, on every CI run.
struct HelperSigningIdentity: Sendable {
    private let read: @Sendable () -> SelfSigningInspection

    init(read: @escaping @Sendable () -> SelfSigningInspection) {
        self.read = read
    }

    func inspect() -> SelfSigningInspection { read() }

    /// The real reader: `SecCodeCopySelf` → `SecCodeCopySigningInformation` →
    /// `kSecCodeInfoTeamIdentifier`.
    static let system = HelperSigningIdentity(read: readSystemSigningInformation)

    private static func readSystemSigningInformation() -> SelfSigningInspection {
        var selfCode: SecCode?
        let copyStatus = SecCodeCopySelf([], &selfCode)
        guard copyStatus == errSecSuccess, let selfCode else {
            return .inspectionFailed(copyStatus)
        }

        // SecCodeRef and SecStaticCodeRef are the same underlying object in the Security
        // framework — the C headers document a SecCodeRef as usable wherever a
        // SecStaticCodeRef is required — but the Swift overlay imports them as unrelated
        // types, so the bridge has to be spelled out. There is no allocation or ownership
        // transfer here; both sides are the same retained CFType.
        let staticCode = unsafeBitCast(selfCode, to: SecStaticCode.self)

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard informationStatus == errSecSuccess,
            let attributes = information as? [String: Any]
        else {
            return .inspectionFailed(informationStatus)
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
