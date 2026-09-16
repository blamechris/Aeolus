import Foundation

/// The one description of what "the XPC client's sources" means.
///
/// Two suites assert over that set — `HelperClientSeamTests` for what the client *does* and
/// `HelperClientStateSeamTests` for what it *keeps* — and a second copy of "enumerate the
/// target's files and strip their comments" is precisely the drift both of them exist to catch.
/// It lives here rather than in either of them so that neither owns it.
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
