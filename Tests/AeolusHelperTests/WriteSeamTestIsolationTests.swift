import Foundation
import Testing

/// The test files that can name the SMC write never obtain an opened connection.
///
/// On `e4/bring-up`, `SMCConnection.write(_:to:)` has a body: one `WRITE_BYTES` round trip.
/// A test that opened a real connection and then wrote through it would write to this Mac's
/// SMC on every `swift test` — run by agents, while other agents build on the same machine.
/// Two facts make that combination checkable in the source:
/// - Naming `write` needs the `FanWrite` SPI opt-in, and an opt-in is per file. `@testable
///   import SMCCore` alone does not reach an SPI member: measured on Swift 6.4, a file with
///   only that import naming `write(_:to:)` fails with `'write' is inaccessible due to
///   '@_spi' protection level`. Nor does `@testable import AeolusHelper`: `SMCConnection`
///   conforms to no helper protocol an SPI member could witness
///   (`WriteChannelSeamTests.smcConnectionConformsToNoChannel`), and the daemon's forwarder is
///   `private` to `main`'s file (`WriteChannelSeamTests.theForwarderIsPinned`).
/// - So the test files that can write are exactly the test files that opt in, and those files
///   can be held to never opening a connection.
///
/// **The second bullet was false from #431 until #436's review.** An empty
/// `extension SMCConnection: SMCWriteChannel {}` in the helper let every
/// `@testable import AeolusHelper` test call the write with no opt-in. ADR 0014's B1 seam
/// amendment removed it, and the two tests the first bullet cites keep it removed.
///
/// The rules, each its own test:
/// 1. The only test files that opt into an SPI group are `allowedImporters`.
/// 2. Neither names `open` — called, referenced, or in a string — nor `SMCSensorProvider`,
///    the one SMCCore type that opens a connection it is handed.
/// 3. No test file at all declares an extension of `SMCConnection` or `SMCKeyType`, the shape
///    that would hand the seam to a file that may open one.
/// 4. The raw text under `Tests/` and `Tools/` holds the `_spi` token only in `spiMentioners`, so
///    no string, comment, backtick or lexer gap hides an ordinary opt-in from rule 1. It catches
///    accidents and every spelling met so far; against a test written to evade it, the compiler's
///    seam (ADR 0014's B1 seam amendment) is the control, a residual the B1 plan accepted.
/// 5. Everything an allowed file declares at its top level is `private`, its suites included, and
///    none of it is an extension, whose members a `private` does not bound. So the compiler
///    refuses any other file that names a helper there (#433 and #447's review, in
///    `WriteSeamTestPrivacyTests.swift`).
///
/// Every rule normalises before it matches: comments are removed, trailing ones included, and
/// every pattern allows whitespace and newlines wherever Swift does, so `open ()`,
/// `open\n(`, `.open` and `@_spi( FanWrite )\n@testable import` are the spellings they are.
///
/// This is a tripwire, not a proof. Until #433 a free function in an allowed file could write to a
/// connection another file opened and handed in; rule 5 makes that function private, and the
/// compiler refuses the call. What is still not caught is a test written to move a value rather
/// than a name: an allowed file that reads a connection out of state another file declares, or
/// stores a closure that writes into it. Access levels bound names, not values. What this catches
/// is the accident — a hardware suite gaining the opt-in, a write test gaining an `open()`, or a
/// helper here gaining a caller there — which is the realistic way a test would come to write.
@Suite("Test files that can name the SMC write never open a connection")
struct WriteSeamTestIsolationTests {

    /// Paths relative to `Tests/`.
    static let allowedImporters: Set<String> = [
        "SMCCoreTests/SMCConnectionTests.swift",
        "SMCCoreTests/SMCConnectionWriteTests.swift",
    ]

    /// What an allowed importer may not name: the call that opens a connection, and the type
    /// that opens one on the caller's behalf (`SMCSensorProvider.readAll()` and
    /// `read(keys:)` call `open()` on the connection they are given).
    static let forbiddenNames = ["open", "SMCSensorProvider"]

    // MARK: - The rules

    @Test("Only the two write-test files opt into an SPI group")
    func onlyTheWriteTestFilesOptIn() throws {
        var importers: [String: [String]] = [:]
        for file in try SeamScanner.swiftFilesUnderTests() {
            let groups = try Self.spiImportGroups(in: String(contentsOf: file, encoding: .utf8))
            guard !groups.isEmpty else { continue }
            let path = Self.relativePath(file)
            importers[path] = groups
            #expect(
                Self.allowedImporters.contains(path),
                """
                \(path) opts into the \(groups.joined(separator: ", ")) SPI group. A test file \
                that can name SMCConnection.write(_:to:) must never obtain an opened \
                connection, so only \(Self.allowedImporters.sorted()) may opt in. Put a \
                hardware test in a file without the opt-in.
                """
            )
        }

        // Coverage, not decoration: both allowed files opt in today, so an empty or partial
        // result means the scan is not reading the tree — or an allowance is stale.
        #expect(
            Set(importers.keys) == Self.allowedImporters,
            """
            The test files opting into an SPI group are \(importers.keys.sorted()), not \
            \(Self.allowedImporters.sorted()). Either the scan stopped matching the import, \
            or an allowed file no longer needs the opt-in and should leave this list.
            """
        )
    }

    @Test("A test file that can name the write never names open or SMCSensorProvider")
    func theWriteTestFilesNeverOpenAConnection() throws {
        for file in try Self.allowedImporterFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let named = try Self.forbiddenNamesMentioned(in: source)
            #expect(
                named.isEmpty,
                """
                \(Self.relativePath(file)) names \(named). It opts into the FanWrite SPI, so \
                it can call SMCConnection.write(_:to:), and a connection it opens is a real \
                SMC: the next swift test would write to this Mac. Move the test that needs an \
                opened connection to a file without the opt-in.
                """
            )
        }
    }

    /// Every test file, not only the two that opt in: an extension in any test file is visible to
    /// every other file in its target, and an `extension SMCCore.SMCConnection` binding the write
    /// to a member was one of #436's review findings.
    @Test("No test file extends SMCConnection or SMCKeyType")
    func theWriteTestFilesDoNotReExportTheSeam() throws {
        for file in try SeamScanner.swiftFilesUnderTests() {
            let extended = try Self.seamTypeExtensions(
                in: String(contentsOf: file, encoding: .utf8))
            #expect(
                extended.isEmpty,
                """
                \(Self.relativePath(file)) extends \(extended). A member added there is \
                callable from every file in the target, including files that open a \
                connection, so the opt-in would no longer bound who can write.
                """
            )
        }
    }

    // MARK: - The scanner

    /// The access level an import may carry, after its attributes and before `import`:
    /// `@_spi(FanWrite) public import SMCCore` compiles and grants the group as surely as the
    /// plain form, at every level (#441). An access level before an attribute does not parse,
    /// and one between two attributes does not either, so this is the only place it can stand.
    /// Shared with `WriteSeamAccessTests`' pattern for `Sources/`, so the two cannot disagree.
    static let importAccess = #"(?:(?:public|package|internal|fileprivate|private)\s+)?"#

    /// Every SPI group named by an import in `source`: the `@_spi(Group)` attribute, then any
    /// further attributes in any order, then an optional access level, then `import`. Comments and
    /// string literals are removed first, because an import can be neither, and a fixture
    /// describing one — this file has several — is not one.
    static func spiImportGroups(in source: String) throws -> [String] {
        // Backticks go too: `` @`_spi`(FanWrite) `` is the same opt-in (#436's final review, B1).
        let code = strippingStringLiterals(SeamScanner.strippingAllComments(source))
            .replacingOccurrences(of: "`", with: "")
        let pattern = try NSRegularExpression(
            pattern: #"@_spi\s*\(\s*(\w+)\s*\)"#
                + #"(?:\s*@[A-Za-z_]\w*(?:\s*\([^)]*\))?)*"#
                + #"\s*"# + importAccess + #"import(?![A-Za-z0-9_])"#)
        let range = NSRange(code.startIndex..., in: code)
        return pattern.matches(in: code, range: range).compactMap { match in
            Range(match.range(at: 1), in: code).map { String(code[$0]) }
        }
    }

    /// The `forbiddenNames` that `source` names, in code or in a string — a string can hold an
    /// interpolation, and a name in prose that only looks like a use fails loudly and gets
    /// reworded, where a hidden use would not. Comments are not counted.
    static func forbiddenNamesMentioned(in source: String) throws -> [String] {
        try forbiddenNames.filter { try SeamScanner.mentions(of: $0, inSource: source) > 0 }
    }

    /// The seam's types that `source` extends, by name, with or without the module prefix. Comments
    /// and string literals are removed first: the scanner tests hold fixtures in strings, and an
    /// extension is never one. An extension a lexer gap hid could name the write only with the
    /// opt-in, which rule 4 counts in the raw text.
    static func seamTypeExtensions(in source: String) throws -> [String] {
        let code = strippingStringLiterals(SeamScanner.strippingAllComments(source))
        let pattern = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])extension\s+(?:SMCCore\s*\.\s*)?"#
                + #"(SMCConnection|SMCKeyType)(?![A-Za-z0-9_])"#)
        let range = NSRange(code.startIndex..., in: code)
        return pattern.matches(in: code, range: range).compactMap { match in
            Range(match.range(at: 1), in: code).map { String(code[$0]) }
        }
    }

    /// `code` with the text of every string literal removed — `"…"`, `"""…"""` and their raw
    /// forms, by the walker `SeamScanner` shares, rather than a second one — and the code of every
    /// interpolation kept, itself stripped the same way. Regex literals go too, by
    /// `SeamScanner.regexLiteralEnd`. An import is never inside a string, and a call inside `\(…)`
    /// is still a call.
    static func strippingStringLiterals(_ code: String) -> String {
        var output = ""
        var discarded = ""
        var index = code.startIndex
        while index < code.endIndex {
            if let end = SeamScanner.regexLiteralEnd(at: index, in: code) {
                // A regex is a literal too, and its `#`s were copied as code before its `/`.
                output.removeLast(min(SeamScanner.rawHashes(before: index, in: code), output.count))
                output += " "
                index = end
                continue
            }
            guard code[index] == "\"" else {
                output.append(code[index])
                index = code.index(after: index)
                continue
            }
            // A raw literal's `#`s were copied as code before its quote; they are its delimiter.
            output.removeLast(min(SeamScanner.rawHashes(before: index, in: code), output.count))
            let delimiter = code[index...].hasPrefix("\"\"\"") ? "\"\"\"" : "\""
            var interpolations: [Range<String.Index>] = []
            index = SeamScanner.copyDelimited(
                code, from: index, delimiter: delimiter, into: &discarded,
                interpolations: &interpolations)
            let kept = interpolations.map { strippingStringLiterals(String(code[$0])) }
            output += " " + kept.joined(separator: " ") + " "
        }
        return output
    }

    private static func allowedImporterFiles() throws -> [URL] {
        let files = try SeamScanner.swiftFilesUnderTests().filter {
            allowedImporters.contains(relativePath($0))
        }
        #expect(
            files.count == allowedImporters.count,
            "found \(files.map(relativePath)), expected every one of \(allowedImporters.sorted())")
        return files
    }

    /// The path below `Tests/`, so an allowance names a file a reader can open.
    static func relativePath(_ file: URL) -> String {
        let components = file.pathComponents
        guard let tests = components.lastIndex(of: "Tests") else { return file.lastPathComponent }
        return components[components.index(after: tests)...].joined(separator: "/")
    }
}

// MARK: - Rule 4: the raw census

extension WriteSeamTestIsolationTests {

    /// The files under `Tests/` and `Tools/` whose raw text mentions `@_spi`, from the repository
    /// root: rule 1's two importers, the scanners and scanner tests that spell the attribute, and
    /// the sampler tool, whose source says in prose why it does not opt in.
    static let spiMentioners: Set<String> = [
        "Tests/AeolusHelperTests/MemberAccessScan.swift",
        "Tests/AeolusHelperTests/MemberAccessScanParsingTests.swift",
        "Tests/AeolusHelperTests/WriteChannelSeamTests.swift",
        "Tests/AeolusHelperTests/WritePathAbsenceTests.swift",
        "Tests/AeolusHelperTests/WriteSeamAccessTests.swift",
        "Tests/AeolusHelperTests/WriteSeamTestIsolationTests.swift",
        "Tests/SMCCoreTests/SMCConnectionTests.swift",
        "Tests/SMCCoreTests/SMCConnectionWriteTests.swift",
        "Tests/SMCCoreTests/StampSiteScannerTests.swift",
        "Tests/SMCSamplerTests/ToolsSeamScanner.swift",
        "Tests/SMCSamplerTests/ToolsSeamTests.swift",
        "Tools/SMCSampler/SMCSamplerCore.swift",
    ]

    /// Rule 4, and it fails closed. The **raw** text is matched for the `_spi` token, with no
    /// comment or string stripped, so no lexer stands between an ordinary opt-in and this list: a
    /// mention anywhere new — an import, backticked or not, or the word in prose — is a file to
    /// justify here. Rule 1 still reads code, and still says which two files import. Until #436's
    /// final review this matched `@\s*_spi`, which `` @`_spi`(FanWrite) `` passed.
    ///
    /// **Mutation:** a new test file holding `#"a "b"#`, then `@_spi(FanWrite) import SMCCore`.
    /// Run: red here. Rule 1's normalised scan goes red too, now that the lexer reads that raw
    /// string; this census is the layer that needs no lexer.
    @Test("The raw text under Tests and Tools mentions @_spi only in the known files")
    func everySPIMentionIsKnown() throws {
        let mentioning = try Self.rawMentioners(of: Self.spiToken, under: ["Tests", "Tools"])
        #expect(
            mentioning == Self.spiMentioners,
            """
            New: \(mentioning.subtracting(Self.spiMentioners).sorted()). Gone: \
            \(Self.spiMentioners.subtracting(mentioning).sorted()). A file that opts in can \
            write through a real connection; justify a new mention here, or remove it.
            """)
    }

    /// The three other ways a test could reach a symbol its imports do not grant, each counted in
    /// the raw text the same way (#436's delta review): `@_silgen_name` binds a declaration to any
    /// mangled symbol, the write's included; `dlsym` finds one at run time; and an `@_private(…)`
    /// import, with `-enable-private-imports`, sees every `private` declaration — the daemon's
    /// forwarder and entry point among them.
    /// The token, not the attribute: `_spi` with no word character either side, so `@_spi`,
    /// `` @`_spi` `` and `@ _spi` are all one mention (#436's final review, B1).
    static let spiToken = #"(?<![A-Za-z0-9_])_spi(?![A-Za-z0-9_])"#

    static let escapeHatches: [(pattern: String, mentioners: Set<String>)] = [
        (#"@\s*_silgen_name"#, ["Tests/AeolusHelperTests/WriteSeamTestIsolationTests.swift"]),
        (
            #"(?<![A-Za-z0-9_])dlsym(?![A-Za-z0-9_])"#,
            [
                "Tests/AeolusHelperTests/WriteSeamTestIsolationTests.swift",
                "Tests/SMCCoreTests/RoundTripStampTripwireTests.swift",
            ]
        ),
        (#"@\s*_private\s*\("#, ["Tests/AeolusHelperTests/WriteSeamTestIsolationTests.swift"]),
    ]

    /// **Mutation:** a new test file declaring `@_silgen_name("x") func probe()`. Run: red here.
    @Test("The raw text under Tests and Tools names no symbol-binding escape hatch")
    func noEscapeHatchIsWritten() throws {
        for (pattern, known) in Self.escapeHatches {
            let mentioning = try Self.rawMentioners(of: pattern, under: ["Tests", "Tools"])
            #expect(
                mentioning == known,
                """
                `\(pattern)` is mentioned by \(mentioning.sorted()), not \(known.sorted()): each \
                binds a symbol no import grants, the SMC write's included.
                """)
        }
    }

    /// The repository-relative paths of every `.swift` file under `directories` whose raw text
    /// matches `pattern`. Symbolic links are refused, so nothing the scan cannot see is compiled.
    static func rawMentioners(
        of pattern: String, under directories: [String]
    ) throws -> Set<String> {
        var mentioning: Set<String> = []
        var read = 0
        for directory in directories {
            let root = RuleZeroScan.repositoryRoot.appendingPathComponent(directory)
            let enumerator = try #require(
                FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]))
            let entries = enumerator.compactMap { $0 as? URL }
            SeamScanner.refuseSymbolicLinks(in: entries, under: root)
            for url in entries where url.pathExtension.lowercased() == "swift" {
                read += 1
                let raw = try String(contentsOf: url, encoding: .utf8)
                if raw.range(of: pattern, options: .regularExpression) != nil {
                    mentioning.insert(RuleZeroScan.relativePath(of: url))
                }
            }
        }
        #expect(
            read > 100, "the census read \(read) files under \(directories), which is not the tree")
        return mentioning
    }
}

/// The scanner above, held to the spellings an evasion would use, on synthetic sources. A
/// scanner that silently stops matching reports a clean tree, so it is tested as a guard.
@Suite("The write-seam test isolation scanner")
struct WriteSeamTestIsolationScannerTests {

    @Test("An SPI import is found however its attributes are spelled and ordered")
    func spiImportsAreFoundInEverySpelling() throws {
        let spellings = [
            "@_spi(FanWrite) import SMCCore",
            "@_spi(FanWrite) @testable import SMCCore",
            "@testable @_spi(FanWrite) import SMCCore",
            "@_spi( FanWrite )\n@testable\nimport SMCCore",
            "@preconcurrency @_spi(FanWrite) @testable import SMCCore",
            "@_spi(FanWrite) import struct SMCCore.SMCConnection",
            "@_spi(FanUnlock) import SMCCore",
            "@`_spi`(FanWrite) import SMCCore",
            "@`_spi`(FanWrite) @testable import class SMCCore.SMCConnection",
        ]
        for spelling in spellings {
            let groups = try WriteSeamTestIsolationTests.spiImportGroups(in: spelling)
            #expect(!groups.isEmpty, "\(spelling)")
        }
    }

    /// An access-level import compiles and grants the group (probed on Swift 6.4: every level
    /// reaches `write`, and `package` only wants a package name). The pattern that read `import`
    /// straight after the attributes passed all five (#441, T05p).
    ///
    /// **Mutation:** in `spiImportGroups`, drop `importAccess` from the pattern. Run: red here,
    /// at the first level.
    @Test("An SPI import is found at every access level, and a plain access import is not one")
    func accessLevelImportsAreFound() throws {
        let runs = ["@_spi(FanWrite)", "@_spi(FanWrite) @testable", "@`_spi`(FanWrite)"]
        for level in ["public", "package", "internal", "fileprivate", "private"] {
            for attributes in runs {
                let spelling = "\(attributes) \(level) import SMCCore"
                #expect(
                    try WriteSeamTestIsolationTests.spiImportGroups(in: spelling) == ["FanWrite"],
                    "\(spelling)")
            }
        }
        let wrapped = "@_spi(FanWrite)\n@testable\npublic\nimport SMCCore"
        #expect(try WriteSeamTestIsolationTests.spiImportGroups(in: wrapped) == ["FanWrite"])
        // S3: a block comment is a separator, so it joins nothing.
        for spelling in ["public/* */import SMCCore", "@testable internal/**/import SMCCore"] {
            let source = "@_spi(FanWrite) " + spelling
            #expect(
                try WriteSeamTestIsolationTests.spiImportGroups(in: source) == ["FanWrite"],
                "\(source)")
        }
        let scoped = "@_spi(FanUnlock) public import struct SMCCore.SMCConnection"
        #expect(try WriteSeamTestIsolationTests.spiImportGroups(in: scoped) == ["FanUnlock"])

        for source in [
            "public import SMCCore", "@testable internal import SMCCore",
            "@_spi(FanWrite) publicly import SMCCore", "@_spi(FanWrite) publicimport SMCCore",
            "// @_spi(FanWrite) public import SMCCore",
            "let text = \"@_spi(FanWrite) public import SMCCore\"",
        ] {
            #expect(
                try WriteSeamTestIsolationTests.spiImportGroups(in: source).isEmpty, "\(source)")
        }
    }

    @Test("An import in a comment or a string literal is not an import")
    func proseIsNotAnImport() throws {
        let sources = [
            "// @_spi(FanWrite) import SMCCore",
            "/* @_spi(FanWrite) import SMCCore */",
            "let text = \"@_spi(FanWrite) import SMCCore\"",
            "let text = \"\"\"\n@_spi(FanWrite) @testable import SMCCore\n\"\"\"",
            "@testable import SMCCore",
            "let text = #\"@_spi(FanWrite) import SMCCore\"#",
        ]
        for source in sources {
            #expect(
                try WriteSeamTestIsolationTests.spiImportGroups(in: source).isEmpty, "\(source)")
        }
    }

    @Test("open is found as a call, a spaced or split call, and a reference")
    func openIsFoundInEverySpelling() throws {
        let spellings = [
            "try await connection.open()",
            "try await connection.open ()",
            "try await connection\n    .open(\n)",
            "let opener = connection.open",
            "try await (connection).open()",
            "Issue.record(\"\\(try await connection.open())\")",
            "let provider = SMCSensorProvider(connection: connection)",
        ]
        for spelling in spellings {
            #expect(
                !(try WriteSeamTestIsolationTests.forbiddenNamesMentioned(in: spelling).isEmpty),
                "\(spelling)")
        }
    }

    @Test("A word that merely contains open is not open, and a comment is not code")
    func lookalikesAreNotOpen() throws {
        let sources = [
            "let connection = SMCConnection()  // never opened",
            "/* try await connection.open() */",
            "@Test(\"an unopened connection\") func f() {}",
            "kIOReturnNotOpen",
            "let reopened = true; let openness = 1",
        ]
        for source in sources {
            #expect(
                try WriteSeamTestIsolationTests.forbiddenNamesMentioned(in: source).isEmpty,
                "\(source)")
        }
    }

    @Test("An extension of either seam type is found, with or without the module prefix")
    func seamTypeExtensionsAreFound() throws {
        let scan = WriteSeamTestIsolationTests.seamTypeExtensions(in:)
        #expect(try scan("extension SMCConnection {}") == ["SMCConnection"])
        #expect(try scan("extension\n  SMCCore.SMCKeyType {") == ["SMCKeyType"])
        #expect(try scan("extension SMCConnectionRecycling {}").isEmpty)
        #expect(try scan("extension SMCCore . SMCConnection: P {}") == ["SMCConnection"])
        #expect(try scan("// extension SMCConnection {}").isEmpty)
    }
}
