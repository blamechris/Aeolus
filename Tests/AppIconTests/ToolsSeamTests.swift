import Testing

/// `Tools/AppIcon` draws a picture. It has no business near the SMC, the helper, or any
/// IPC, and the way to keep it that way is to check the source rather than a reader's
/// memory of the brief — the same argument the other two tools' seam suites make.
/// `ToolsSeamScanner` does the checking; `Tests/AeolusHelperTests/ToolsSeamCoverageTests`
/// is what insists every directory under `Tools/` owns a suite like this one.
@Suite("Tools/AppIcon forbidden tokens")
struct ToolsSeamTests {

    /// The full list this suite enforces. Mutating this to drop or rename an entry is the
    /// tripwire's own mutation: a source scanner that always finds nothing is not a guard,
    /// it is a decoration.
    static let forbiddenTokens = [
        "SMCCore",
        "AppleSMC",
        "IOKit",
        "AeolusHelper",
        "AeolusXPC",
        "NSXPCConnection",
    ]

    @Test("no forbidden token appears under Tools/AppIcon", arguments: forbiddenTokens)
    func toolsNeverNamesAForbiddenToken(_ token: String) throws {
        #expect(
            try !ToolsSeamScanner.anyFileContains(token),
            "Tools/AppIcon must never name \(token): it draws an image and touches nothing else.")
    }

    /// The parameterised test above can only fail loud when a token is in the list and the
    /// source names it. Dropping a token from `forbiddenTokens` makes that case simply not
    /// run, which is silent rather than red. This is the guard's own completeness check.
    @Test("the forbidden list names every token the brief requires")
    func theForbiddenListIsComplete() {
        for token in [
            "SMCCore", "AppleSMC", "IOKit", "AeolusHelper", "AeolusXPC", "NSXPCConnection",
        ] {
            #expect(Self.forbiddenTokens.contains(token), "forbiddenTokens lost \(token)")
        }
    }
}
