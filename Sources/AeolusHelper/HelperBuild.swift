/// The helper's build string, out of `AeolusHelperMain` so a test can pin it without naming the
/// entry point, which is `private` (see it).
enum HelperBuild {

    /// Advertised in `HelloReply.helperBuild`. Display-grade: never parsed to decide
    /// behaviour, because that would be a second version vocabulary competing with
    /// `helperProtocolRange`.
    ///
    /// On `e4/bring-up` this names the branch, so a helper built from it says so in
    /// `fanctl status` and in the listening line. `HelperBuildStringTests` pins the value, so
    /// changing it at the E4 merge is an edit to both.
    static let string = "0.0.0 (E4 bring-up)"
}
