import Foundation
import Testing

@testable import AeolusXPC
@testable import AeolusXPCClient

/// The shipping pinning policy, executed rather than pattern-matched.
///
/// `SignedHelperPinning` is the default `pinning` in `HelperClient.init` and the only policy
/// that ships, and until this file existed **nothing called it**: every client test injects
/// a double, and the one test that named it matched its declaration text against a regex.
/// A mutation replacing its refusal arm with `return transport.makeConnection()` — a client
/// that, when it cannot verify the helper, connects anyway on an unpinned connection — left
/// the whole suite green at 1365 tests. That is `CLAUDE.md` rule 8, "being able to connect is
/// not authorisation", with nothing behind it.
///
/// **This is not the survivor ADR 0005 records.** That one is
/// `connection.setCodeSigningRequirement(requirement.text)`, which genuinely needs a
/// Developer ID-signed helper and a foreign-signed client and genuinely cannot be killed in
/// process. The refuse-or-connect decision four lines above it needs no certificate at all.
@Suite("The shipping client pinning policy")
struct HelperClientPinningTests {

    /// The policy's answer agrees with this host's own signature — and under every build
    /// that is not the maintainer's, that answer is a refusal.
    ///
    /// Written as an exhaustive switch on the host rather than a flat equality, for the
    /// reason `HelperRequirementTextTests.productionEntryPointMatchesTheHost` gives: the
    /// host is ad-hoc signed under `swift test` on CI and on `Mac16,5` alike, so
    /// `.noTeamIdentifier` is the arm that runs — but if this suite is ever run from a
    /// signed host it must assert the *other* branch rather than go red for the mechanism
    /// working. No arm fabricates an identity; each reads the answer the host actually gives.
    ///
    /// The refusal must happen **before a connection object exists**, which is what the
    /// third expectation is for: an unpinned connection that is merely never resumed is
    /// still a connection a later edit can resume.
    ///
    /// **Mutation:** in `SignedHelperPinning.pinnedConnection(over:)`, replace
    /// `case .failure(let refusal): throw …` with `return transport.makeConnection()`.
    /// Run: red — `#expect(throws:)` records that nothing was thrown.
    @Test("A client that cannot verify itself refuses to build a connection at all")
    func theShippingPolicyRefusesAHostThatCannotVerifyItself() throws {
        let listener = NSXPCListener.anonymous()
        defer { listener.invalidate() }
        let transport = HelperClientTransport.endpoint(listener.endpoint)

        switch HelperSigningIdentity.inspect() {
        case .noTeamIdentifier:
            #expect(
                throws: HelperClientError.clientCannotVerifyHelper(
                    .runningProcessHasNoTeamIdentifier)
            ) {
                _ = try SignedHelperPinning().pinnedConnection(over: transport)
            }
        case .inspectionFailed(let status):
            #expect(
                throws: HelperClientError.clientCannotVerifyHelper(.selfInspectionFailed(status))
            ) {
                _ = try SignedHelperPinning().pinnedConnection(over: transport)
            }
        case .teamIdentifier(let team):
            // The maintainer's signed host. The requirement resolves, so a connection comes
            // back — unresumed, as the protocol requires, and this test's only business with
            // it is to invalidate it again.
            let connection = try SignedHelperPinning().pinnedConnection(over: transport)
            connection.invalidate()
            #expect(!team.isEmpty)
        }
    }
}
