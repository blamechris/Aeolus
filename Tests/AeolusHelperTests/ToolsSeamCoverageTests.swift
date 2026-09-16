import Foundation
import Testing

/// The completeness check the per-tool seam scanners depend on but do not provide on their
/// own.
///
/// `Tests/PowerObserverTests/ToolsSeamScanner.swift` and
/// `Tests/SMCSamplerTests/ToolsSeamScanner.swift` each replaced one tripwire that covered all
/// of `Tools/` with a scanner scoped to a single tool directory — necessarily, since the two
/// tools have opposite briefs about naming `SMCCore`. What that split loses for free is the
/// property the blanket scanner used to have: a *third* tool dropped under `Tools/` with no
/// seam suite of its own is invisible to every existing test, because each one only ever
/// walks its own directory. This suite restores that property — not by scanning source, but
/// by scanning the test tree itself for the suite each tool directory is expected to own.
///
/// Round-2 delta review of #248 found the original version of this suite checked only that
/// `Tests/<Name>Tests/ToolsSeamTests.swift` *exists* — a file present on disk but never
/// compiled (no matching `.testTarget` in `Package.swift`) or containing no suite at all
/// satisfied it just as well as a real one. `everyToolHasARunningSeamSuite` below closes
/// both gaps: it additionally reads `Package.swift` as text for the target wiring, and the
/// seam file's own contents for a non-empty `forbiddenTokens` list under a `@Suite`.
@Suite("Tools/ directories each own a seam suite")
struct ToolsSeamCoverageTests {

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AeolusHelperTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    /// The name of every immediate, non-hidden subdirectory of `Tools/` — one per
    /// maintainer tool. `contentsOfDirectory(at:includingPropertiesForKeys:)` with no
    /// `.skipsHiddenFiles` option includes dotfiles/dot-directories, so an incidental
    /// `.DS_Store`-adjacent directory (or a stray `.build` someone points at `Tools/`)
    /// would otherwise demand its own `Tests/.buildTests/ToolsSeamTests.swift` and fail
    /// this suite for a directory that is not a tool at all.
    static func toolDirectoryNames() throws -> [String] {
        let toolsRoot = repositoryRoot.appendingPathComponent("Tools")
        let contents = try FileManager.default.contentsOfDirectory(
            at: toolsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        let names = try contents.filter { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true
        }.map(\.lastPathComponent)
        #expect(!names.isEmpty, "Tools/ contains no tool directories under \(toolsRoot.path)")
        return names
    }

    /// `Package.swift`'s full text, read once per test run. Read as text rather than
    /// parsed — the same "good enough for a tripwire, not a build-graph model" trade-off
    /// `ToolsSeamScanner` itself makes for `Tools/`'s own source.
    static func packageManifestText() throws -> String {
        let manifest = repositoryRoot.appendingPathComponent("Package.swift")
        return try String(contentsOf: manifest, encoding: .utf8)
    }

    /// Every `.testTarget(...)` call's argument text in `manifestText`, each one closed at
    /// its own matching close paren rather than at the next `.testTarget(` marker or the
    /// end of the file. Found by depth-counting parens from just after each `.testTarget(`
    /// — not by splitting on the literal marker and truncating each piece at the following
    /// occurrence, which is unambiguous for every block except the *last*: with nothing
    /// after it to split on, that final block ran to the end of the manifest and so
    /// included every subsequent `.target(...)`/`.executableTarget(...)` declaration and
    /// the closing `]`/`)` of the `targets:` array and `Package(...)` call themselves.
    /// Round-3 delta review of #248 flagged this as a note rather than a live gap — no
    /// non-test target today declares both a `name: "<Name>Tests"` and a matching
    /// `path: "Tests/<Name>Tests"` — but a future one placed after the last `.testTarget(`
    /// would have satisfied the check without a test target existing at all.
    static func testTargetBlocks(in manifestText: String) -> [Substring] {
        var blocks: [Substring] = []
        var searchStart = manifestText.startIndex
        while let markerRange = manifestText.range(
            of: ".testTarget(", range: searchStart..<manifestText.endIndex)
        {
            var depth = 1
            let start = markerRange.upperBound
            var index = start
            while index < manifestText.endIndex, depth > 0 {
                switch manifestText[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                index = manifestText.index(after: index)
            }
            blocks.append(manifestText[start..<index])
            searchStart = index
        }
        return blocks
    }

    /// Whether `manifestText` declares a `.testTarget` naming both `name: "<name>Tests"`
    /// and `path: "Tests/<name>Tests"` — not merely containing the two substrings
    /// somewhere in the file (which two unrelated targets could each satisfy half of), but
    /// within the same `.testTarget(...)` block, as delimited by `testTargetBlocks(in:)`.
    static func manifestDeclaresTestTarget(named name: String, in manifestText: String) -> Bool {
        let expectedName = "name: \"\(name)Tests\""
        let expectedPath = "path: \"Tests/\(name)Tests\""
        return testTargetBlocks(in: manifestText).contains { block in
            block.contains(expectedName) && block.contains(expectedPath)
        }
    }

    /// Whether `seamText` declares a non-empty `forbiddenTokens` array — not merely
    /// containing the word "forbiddenTokens" while lacking the exact single-line spelling
    /// `forbiddenTokens = []`. Round-3 delta review of #248 flagged that spelling as a
    /// substring test an empty list still satisfies two other ways both suites already use
    /// as their declaration style (`static let forbiddenTokens = [` on its own line): a
    /// type-annotated `forbiddenTokens: [String] = []`, and a multi-line `= [\n]`.
    ///
    /// Delta-3 review of this suite found that "locate the first `[` after the first
    /// mention of the word" is not the same test as "does the *declaration* have a
    /// non-empty literal", and is wrong in both directions: `static let forbiddenTokens:
    /// [String] = ["AeolusHelper"]` false-rejects (the bracket it inspects is the `[String]`
    /// annotation, whose body is `String` — no quote), and a doc comment naming the word
    /// next to any bracketed quoted string above a genuinely empty declaration — the house
    /// style in both existing seam suites — false-accepts.
    ///
    /// This instead walks every occurrence of "forbiddenTokens" looking for one shaped like
    /// a declaration: the word, an optional `: [...]` type annotation, then `=`, then the
    /// literal to inspect. A mention that is not followed by that shape (a doc comment
    /// prose reference, for instance) is skipped rather than trusted.
    static func declaresNonEmptyForbiddenTokens(in seamText: String) -> Bool {
        var searchStart = seamText.startIndex
        while let nameRange = seamText.range(
            of: "forbiddenTokens", range: searchStart..<seamText.endIndex)
        {
            searchStart = nameRange.upperBound
            var cursor = nameRange.upperBound
            skipWhitespace(in: seamText, from: &cursor)

            // Optional type annotation: `: [String]`.
            if cursor < seamText.endIndex, seamText[cursor] == ":" {
                cursor = seamText.index(after: cursor)
                skipWhitespace(in: seamText, from: &cursor)
                guard cursor < seamText.endIndex, seamText[cursor] == "[",
                    let annotationClose = seamText.range(
                        of: "]", range: cursor..<seamText.endIndex)
                else { continue }  // not a `: [...]` annotation after all — not a declaration
                cursor = annotationClose.upperBound
                skipWhitespace(in: seamText, from: &cursor)
            }

            guard cursor < seamText.endIndex, seamText[cursor] == "=" else { continue }
            cursor = seamText.index(after: cursor)
            skipWhitespace(in: seamText, from: &cursor)

            guard cursor < seamText.endIndex, seamText[cursor] == "[",
                let closeBracket = seamText.range(
                    of: "]", range: seamText.index(after: cursor)..<seamText.endIndex)
            else { continue }
            let body = seamText[seamText.index(after: cursor)..<closeBracket.lowerBound]
            if body.contains("\"") { return true }
            // This occurrence resolved to a real (but empty) declaration; a well-formed
            // seam file has only one, but keep scanning rather than assume that.
        }
        return false
    }

    /// Advances `index` past any run of whitespace (including newlines) starting at
    /// `index`, in `text`.
    static func skipWhitespace(in text: String, from index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
    }

    /// Fails the moment a tool directory arrives with no `<Name>Tests/ToolsSeamTests.swift`
    /// beside it, with that file compiled into a real test target, containing a `@Suite`,
    /// and declaring at least one forbidden token — the exact shape `Tools/PowerObserver`
    /// and `Tools/SMCSampler` both use.
    ///
    /// Mutation 1: create `Tools/ThirdTool/ThirdTool.swift` with no matching test target —
    /// red on the file-existence check.
    /// Mutation 2 (the gap the original version of this test missed): additionally create
    /// `Tests/ThirdToolTests/ToolsSeamTests.swift` containing only a comment, with no
    /// matching `.testTarget` added to `Package.swift` — red on the manifest-wiring check,
    /// where the original passed.
    @Test("every Tools/ directory has a compiled, non-empty seam suite")
    func everyToolHasARunningSeamSuite() throws {
        let manifestText = try Self.packageManifestText()
        for name in try Self.toolDirectoryNames() {
            let expected = Self.repositoryRoot
                .appendingPathComponent("Tests")
                .appendingPathComponent("\(name)Tests")
                .appendingPathComponent("ToolsSeamTests.swift")
            #expect(
                FileManager.default.fileExists(atPath: expected.path),
                """
                Tools/\(name) has no \(expected.path) — a new maintainer tool under Tools/ \
                needs its own forbidden-token seam suite, the way PowerObserver and \
                SMCSampler each do.
                """
            )
            #expect(
                Self.manifestDeclaresTestTarget(named: name, in: manifestText),
                """
                Package.swift has no .testTarget with both name: "\(name)Tests" and \
                path: "Tests/\(name)Tests" — a seam file that exists on disk but is never \
                compiled into a test target never runs, and CI stays green either way.
                """
            )

            guard let seamText = try? String(contentsOf: expected, encoding: .utf8) else {
                continue  // already reported by the fileExists expectation above
            }
            #expect(
                seamText.contains("@Suite"),
                """
                \(expected.path) exists but declares no @Suite — an empty file satisfies \
                the file-existence check for nothing.
                """
            )
            #expect(
                Self.declaresNonEmptyForbiddenTokens(in: seamText),
                """
                \(expected.path) declares no non-empty forbiddenTokens list — a seam suite \
                with nothing forbidden never fails, regardless of what Tools/\(name) does.
                """
            )
        }
    }

    /// Round-3 delta review of #248's Mutation D: append a non-test target after the last
    /// real `.testTarget(...)` in the manifest, naming `name: "FooTests"` and
    /// `path: "Tests/FooTests"` — the exact shape a component-split, truncate-at-next-marker
    /// scan would have folded into its final "block" and accepted. `testTargetBlocks(in:)`
    /// closes each block at its own matching paren, so a declaration after the true close
    /// of the last `.testTarget(...)` call is never included in any block.
    @Test("a non-test target declared after the last .testTarget(...) is not mistaken for one")
    func testTargetBlocksStopsAtItsOwnClose() {
        let manifest = """
            .testTarget(
                name: "RealTests",
                dependencies: ["Real"],
                path: "Tests/RealTests"
            ),
            .target(
                name: "FooTests",
                path: "Tests/FooTests"
            ),
            """
        #expect(!Self.manifestDeclaresTestTarget(named: "Foo", in: manifest))
        #expect(Self.manifestDeclaresTestTarget(named: "Real", in: manifest))
    }

    /// A `.testTarget(...)` block whose dependencies include a nested call —
    /// `.product(name: "Foo", package: "Bar")` — has more `)` characters before its own
    /// close than a naive "stop at the next `)`" scan would expect. `testTargetBlocks(in:)`
    /// depth-counts, so it is not fooled by the nesting.
    @Test("a .testTarget(...) block with a nested call closes at its own matching paren")
    func testTargetBlocksHandlesNestedParens() {
        let manifest = """
            .testTarget(
                name: "NestedTests",
                dependencies: [.product(name: "Foo", package: "Bar")],
                path: "Tests/NestedTests"
            ),
            """
        #expect(Self.manifestDeclaresTestTarget(named: "Nested", in: manifest))
    }

    /// Round-3 delta review of #248: the single-line spelling `forbiddenTokens = []` is not
    /// the only way to write an empty list. A type-annotated declaration and a multi-line
    /// empty literal both name the word "forbiddenTokens" while declaring nothing forbidden,
    /// and both must be rejected exactly like the single-line form.
    @Test(
        "an empty forbiddenTokens list is rejected in every spelling, not just the single-line one"
    )
    func declaresNonEmptyForbiddenTokensRejectsEveryEmptySpelling() {
        #expect(!Self.declaresNonEmptyForbiddenTokens(in: "static let forbiddenTokens = []"))
        #expect(
            !Self.declaresNonEmptyForbiddenTokens(
                in: "static let forbiddenTokens: [String] = []"))
        #expect(
            !Self.declaresNonEmptyForbiddenTokens(
                in: "static let forbiddenTokens: [String] = [\n]"))
        #expect(!Self.declaresNonEmptyForbiddenTokens(in: "// no forbiddenTokens here at all"))
    }

    @Test("a non-empty forbiddenTokens list is accepted")
    func declaresNonEmptyForbiddenTokensAcceptsARealList() {
        #expect(
            Self.declaresNonEmptyForbiddenTokens(
                in: """
                    static let forbiddenTokens = [
                        "AeolusHelper",
                    ]
                    """))
    }

    /// Round-4 delta review of #248: `declaresNonEmptyForbiddenTokensAcceptsARealList` above
    /// only ever exercised the un-annotated, single-mention spelling, so it proved nothing
    /// about the two failure modes this round actually found in the "first `[` after the
    /// first mention" helper — both are about *which* bracket gets inspected, not whether a
    /// quote is present once the right one is found.
    ///
    /// A type-annotated non-empty list was false-rejected, because the first `[` after the
    /// word is `[String]`'s own bracket, whose body ("String") has no quote. A doc comment
    /// naming the word next to any bracketed, quoted string — the house style both existing
    /// seam suites use — false-accepted a genuinely empty declaration underneath it, because
    /// the first `[` after the word's first mention is the comment's, not the declaration's.
    /// Anchoring on the declaration (word, optional `: [...]` annotation, `=`, then the
    /// literal) fixes both; these four spellings are what a reversion to the round-3 body
    /// gets wrong.
    @Test("forbiddenTokens is judged by its declaration, not by the first mention of the word")
    func declaresNonEmptyForbiddenTokensAnchorsOnTheDeclaration() {
        // Annotated, non-empty, single line.
        #expect(
            Self.declaresNonEmptyForbiddenTokens(
                in: "static let forbiddenTokens: [String] = [\"AeolusHelper\"]"))

        // Annotated, non-empty, multi-line.
        #expect(
            Self.declaresNonEmptyForbiddenTokens(
                in: """
                    static let forbiddenTokens: [String] = [
                        "AeolusHelper",
                    ]
                    """))

        // Annotated, empty — must be rejected because the declaration's own literal is
        // empty, not merely because the annotation's brackets happen to hold no quote.
        #expect(
            !Self.declaresNonEmptyForbiddenTokens(
                in: "static let forbiddenTokens: [String] = []"))

        // A doc comment naming the word beside a bracketed, quoted string, above a
        // genuinely empty declaration.
        #expect(
            !Self.declaresNonEmptyForbiddenTokens(
                in: """
                    /// forbiddenTokens is documented in ["docs/SAFETY.md"].
                    static let forbiddenTokens: [String] = []
                    """))
    }
}
