import Testing

/// This tool's brief is explicit about what it must never do: veto a sleep it was only
/// asked whether it could, touch the SMC by any route, or import the privileged helper.
/// `ToolsSeamScanner` is what checks that against the source rather than against a reader's
/// memory of it — the same argument `Tests/AeolusHelperTests/SeamScanner.swift`'s suites
/// make for `Sources/AeolusHelper`, applied to `Tools/` with a scanner of its own. See
/// `ToolsSeamScanner`'s header note for why the two do not share an implementation.
@Suite("Tools/ forbidden tokens")
struct ToolsSeamTests {

    /// The full list this suite enforces. Mutating this to drop or rename an entry is the
    /// tripwire's own mutation — see the PR body's mutations table — because a source
    /// scanner that always finds nothing is not a guard, it is a decoration.
    static let forbiddenTokens = [
        "IOCancelPowerChange",
        "AppleSMC",
        "SMCCore",
        "AeolusHelper",
    ]

    @Test("no forbidden token appears under Tools/", arguments: forbiddenTokens)
    func toolsNeverNamesAForbiddenToken(_ token: String) throws {
        #expect(
            try !ToolsSeamScanner.anyFileContains(token),
            "Tools/ must never name \(token) — see Tools/PowerObserver's brief.")
    }

    /// The parameterized test above can only fail loud when a token is *in* the list and
    /// the source names it. Dropping a token from `forbiddenTokens` instead makes that test
    /// case simply not run, which is silent rather than red — precisely the "mutating the
    /// code the guard watches does not test it" trap a source-scanning tripwire falls into
    /// when only the scan itself is asserted. This is the guard's own completeness check:
    /// it fails the moment `forbiddenTokens` stops naming all four, independent of what
    /// `Tools/` currently contains.
    @Test("the forbidden list names all four tokens the brief requires")
    func theForbiddenListIsComplete() {
        #expect(Self.forbiddenTokens.contains("IOCancelPowerChange"))
        #expect(Self.forbiddenTokens.contains("AppleSMC"))
        #expect(Self.forbiddenTokens.contains("SMCCore"))
        #expect(Self.forbiddenTokens.contains("AeolusHelper"))
    }
}
