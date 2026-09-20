import Foundation

/// The one description of what "the XPC client's sources" means.
///
/// Three suites assert over that set — `HelperClientSeamTests` for what this target's sources
/// and build graphs must *contain*, `HelperClientSendPathSeamTests` for what the send path may not
/// *do*, and `HelperClientStateSeamTests` for what the client may not *keep* — and a second copy
/// of "enumerate the target's files and strip their comments" is precisely the drift all three of
/// them exist to catch. It lives here rather than in any of them so that none owns it.
enum HelperClientSources {

    static let target = "AeolusXPCClient"

    /// Every file in the target, comments stripped.
    ///
    /// Stripped because the prose in this target discusses the forbidden shapes at length — a
    /// stored snapshot, a retry loop, a bare `remoteObjectProxy` — and a tripwire that fires on
    /// the sentence explaining the rule is a tripwire nobody keeps.
    static func all() throws -> [(file: String, code: String)] {
        try SeamScanner.swiftFiles(under: target).map {
            (
                file: $0.lastPathComponent,
                code: SeamScanner.strippingComments(try String(contentsOf: $0, encoding: .utf8))
            )
        }
    }
}
