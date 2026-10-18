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

    /// The sampler's source is on the raw `_spi` census, because its header names the attribute,
    /// so this scan is the only guard on an import there. Each fixture is a spelling the compiler
    /// accepts that the literal match read as clean (#441, T07).
    ///
    /// **Mutation:** in `ToolsSeamScanner.normalised`, keep the backticks. Run: red here, at the
    /// backticked import. Keeping the whitespace instead is red at the next fixture.
    @Test("A forbidden token is found however the compiler lets it be spelled")
    func spellingsOfAForbiddenTokenAreFound() {
        let attribute = [
            "@_spi(FanWrite) import SMCCore",
            "@`_spi`(FanWrite) import SMCCore",
            "@_spi( FanWrite )\nimport SMCCore",
            "@_spi(\n    FanWrite\n) @testable public import SMCCore",
            "@`_spi`( FanWrite ) @`testable` import SMCCore",
        ]
        for source in attribute {
            #expect(ToolsSeamScanner.contains("@_spi(FanWrite)", inSource: source), "\(source)")
        }
        let write = [
            "try SMCConnection.write(bytes, to: key)",
            "try SMCConnection\n    .write(bytes, to: key)",
            "let submit = SMCConnection.`write`",
            "SMCConnection . write",
        ]
        for source in write {
            #expect(ToolsSeamScanner.contains("SMCConnection.write", inSource: source), "\(source)")
        }
        let clean = [
            "// @_spi(FanWrite) import SMCCore", "    // `@_spi`(FanWrite)", "import SMCCore",
            "@testable import SMCCore", "let write = 1", "try connection.read(key)",
            "let sampler = SMCConnection()",
        ]
        for source in clean {
            for token in Self.forbiddenTokens {
                #expect(!ToolsSeamScanner.contains(token, inSource: source), "\(source)")
            }
        }
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
