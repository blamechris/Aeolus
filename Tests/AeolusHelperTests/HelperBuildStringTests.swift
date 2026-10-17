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

    /// This pins the value, not the idea. **Changing the string at the E4 merge is a deliberate
    /// edit to this test as well as to `AeolusHelperMain.build`**: a merge that takes the branch's
    /// string by accident, or drops it by accident, fails here instead of shipping a helper that
    /// misreports what it is.
    ///
    /// **Mutation:** in `AeolusHelperMain`, set `build` back to `"0.0.0 (E2)"`. Run: red here.
    @Test("The branch build says it is the E4 bring-up build")
    func theBranchBuildIdentifiesItself() {
        #expect(AeolusHelperMain.build == "0.0.0 (E4 bring-up)")
    }
}
