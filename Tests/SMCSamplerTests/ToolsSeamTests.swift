import Testing

/// `smc-sampler`'s brief is explicit about the one thing it must never become: a second
/// route to the SMC write path, or a dependency on the privilege boundary it has no reason
/// to touch. `ToolsSeamScanner` is what checks that against the source rather than against
/// a reader's memory of it — the same argument `Tests/PowerObserverTests/ToolsSeamTests.swift`
/// makes for `power-observer`, applied here to a tool whose brief is the mirror image: this
/// one is *allowed* to name `SMCCore` and `FanKit`, so those are not on the forbidden list.
@Suite("Tools/SMCSampler forbidden tokens")
struct ToolsSeamTests {

    /// The full list this suite enforces. Mutating this to drop or rename an entry is the
    /// tripwire's own mutation — a source scanner that always finds nothing is not a guard,
    /// it is a decoration.
    static let forbiddenTokens = [
        "AeolusHelper",
        "@_spi(FanWrite)",
        "SMCConnection.write",
    ]

    @Test("no forbidden token appears under Tools/SMCSampler", arguments: forbiddenTokens)
    func toolsNeverNamesAForbiddenToken(_ token: String) throws {
        #expect(
            try !ToolsSeamScanner.anyFileContains(token),
            "Tools/SMCSampler must never name \(token) — see Tools/SMCSampler's brief.")
    }

    /// The parameterized test above can only fail loud when a token is *in* the list and
    /// the source names it. Dropping a token from `forbiddenTokens` instead makes that test
    /// case simply not run, which is silent rather than red. This is the guard's own
    /// completeness check: it fails the moment `forbiddenTokens` stops naming all three,
    /// independent of what `Tools/SMCSampler` currently contains.
    @Test("the forbidden list names all three tokens the brief requires")
    func theForbiddenListIsComplete() {
        #expect(Self.forbiddenTokens.contains("AeolusHelper"))
        #expect(Self.forbiddenTokens.contains("@_spi(FanWrite)"))
        #expect(Self.forbiddenTokens.contains("SMCConnection.write"))
    }

    /// The mirror image of the forbidden list: `smc-sampler` is *allowed* to name these,
    /// and this suite would be trivially green for the wrong reason if its scanner somehow
    /// found no files at all (the `#expect(!files.isEmpty, …)` inside
    /// `ToolsSeamScanner.swiftFiles()` guards exactly that, but this is the same coverage
    /// argument stated from the allowed side too — a scanner that could not see `SMCCore`
    /// here would just as easily fail to see `AeolusHelper`).
    @Test("smc-sampler does name SMCCore and FanKit — proving the scanner reads real source")
    func scannerSeesTheAllowedDependencies() throws {
        #expect(try ToolsSeamScanner.anyFileContains("SMCCore"))
        #expect(try ToolsSeamScanner.anyFileContains("FanKit"))
    }
}
