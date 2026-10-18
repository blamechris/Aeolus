import Testing

@testable import AeolusHelper

/// The helper's build string is how a person or an agent tells which daemon is answering.
/// It reaches `HelloReply.helperBuild`, which `fanctl status` prints, and the listening line.
///
/// On `e4/bring-up` it says so. Every helper built from the branch is then identifiable at the
/// point where someone decides whether to trust a hardware run, and a build of `main` cannot be
/// mistaken for one.
@Suite("The helper names the branch it was built from")
struct HelperBuildStringTests {

    /// This pins the value, not the idea, and it guards one direction only. A sync from `main`
    /// that resolves the constant to `main`'s string fails here. The E4 merge does not: the
    /// constant and this test arrive on `main` together, still agreeing. So reverting it to
    /// a release value and deleting this test is a named step of the E4 merge (#9), not something
    /// this test enforces.
    ///
    /// **Mutation:** set `HelperBuild.string` back to `"0.0.0 (E2)"`. Run: red here.
    @Test("The branch build says it is the E4 bring-up build")
    func theBranchBuildIdentifiesItself() {
        #expect(HelperBuild.string == "0.0.0 (E4 bring-up)")
    }
}
