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
///   '@_spi' protection level`.
/// - So the test files that can write are exactly the test files that opt in, and those files
///   can be held to never opening a connection.
///
/// The rules, each its own test:
/// 1. The only test files that opt into an SPI group are `allowedImporters`.
/// 2. Neither names `open` — called, referenced, or in a string — nor `SMCSensorProvider`,
///    the one SMCCore type that opens a connection it is handed.
/// 3. Neither declares an extension of `SMCConnection` or `SMCKeyType`, the shape that would
///    hand the seam to a file that may open one.
///
/// Every rule normalises before it matches: comments are removed, trailing ones included, and
/// every pattern allows whitespace and newlines wherever Swift does, so `open ()`,
/// `open\n(`, `.open` and `@_spi( FanWrite )\n@testable import` are the spellings they are.
///
/// This is a tripwire, not a proof. A test written to evade it is not caught: a free function
/// in an allowed file that writes to a connection another file opened and handed in, for
/// one. What it catches is the accident — a hardware suite gaining the opt-in, or a write
/// test gaining an `open()` — which is the realistic way a test would come to write.
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

    @Test("A test file that can name the write extends neither SMCConnection nor SMCKeyType")
    func theWriteTestFilesDoNotReExportTheSeam() throws {
        for file in try Self.allowedImporterFiles() {
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

    /// Every SPI group named by an import in `source`: the `@_spi(Group)` attribute, then any
    /// further attributes in any order, then `import`. Comments and string literals are
    /// removed first, because an import can be neither, and a fixture describing one — this
    /// file has several — is not one.
    static func spiImportGroups(in source: String) throws -> [String] {
        let code = strippingStringLiterals(SeamScanner.strippingAllComments(source))
        let pattern = try NSRegularExpression(
            pattern: #"@_spi\s*\(\s*(\w+)\s*\)"#
                + #"(?:\s*@[A-Za-z_]\w*(?:\s*\([^)]*\))?)*"#
                + #"\s*import(?![A-Za-z0-9_])"#)
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

    /// The seam's types that `source` extends, by name, with or without the module prefix.
    static func seamTypeExtensions(in source: String) throws -> [String] {
        let code = SeamScanner.strippingAllComments(source)
        let pattern = try NSRegularExpression(
            pattern: #"extension\s+(?:SMCCore\s*\.\s*)?"#
                + #"(SMCConnection|SMCKeyType)(?![A-Za-z0-9_])"#)
        let range = NSRange(code.startIndex..., in: code)
        return pattern.matches(in: code, range: range).compactMap { match in
            Range(match.range(at: 1), in: code).map { String(code[$0]) }
        }
    }

    /// `code` with every string literal removed — `"…"` and `"""…"""`, escapes honoured — by
    /// the same walker `SeamScanner` copies literals with, rather than a second one. Only the
    /// import scan uses this: an import is never inside a string.
    static func strippingStringLiterals(_ code: String) -> String {
        var output = ""
        var discarded = ""
        var index = code.startIndex
        while index < code.endIndex {
            if code[index...].hasPrefix("\"\"\"") {
                index = SeamScanner.copyDelimited(
                    code, from: index, delimiter: "\"\"\"", into: &discarded)
            } else if code[index] == "\"" {
                index = SeamScanner.copyDelimited(
                    code, from: index, delimiter: "\"", into: &discarded)
            } else {
                output.append(code[index])
                index = code.index(after: index)
            }
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
        ]
        for spelling in spellings {
            let groups = try WriteSeamTestIsolationTests.spiImportGroups(in: spelling)
            #expect(!groups.isEmpty, "\(spelling)")
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
        #expect(try scan("// extension SMCConnection {}").isEmpty)
    }
}
