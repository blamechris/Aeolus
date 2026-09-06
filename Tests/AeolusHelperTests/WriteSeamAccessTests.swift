import Foundation
import Testing

/// The controls that replace what `package` visibility used to supply on the SMC write
/// seam.
///
/// `SMCConnection.write(_:to:)` and `SMCKeyType.encode(scalar:byteOrder:)` are
/// `@_spi(FanWrite) public` as of the 2026-09-06 amendment in
/// [ADR 0008](../../docs/ADR/0008-write-authorisation.md). `package` could not survive:
/// the Xcode `AeolusHelper` target consumes `SMCCore` as a *package product*, so it sits
/// outside the package `package` visibility is computed against, and the access level
/// would have failed only in the build that produces a signed helper.
///
/// `@_spi` is a compile-time gate of the same strength `package` had — the symbols are
/// public in the binary, and any module may opt in with one line. What that buys is that
/// the line must be *written*, and these tests make it greppable rather than reviewable:
/// the opt-in exists nowhere but the helper, and `SMCCore` offers exactly two members
/// through exactly one group. No test here claims to stop a determined caller. All of them
/// catch the accident, which is the realistic regression.
///
/// **The group name is discovered, never assumed.** #226's review pointed out that pinning
/// the literal `FanWrite` in both scans left a second SPI group — `@_spi(FanUnlock)`, say,
/// the shape E4 would reach for — invisible to every control: the declaration scan found
/// exactly the two `FanWrite` members and passed, and the import scan never matched the
/// new import at all. Both scans now capture whatever group name is written and assert the
/// *set* is exactly `["FanWrite"]`, so opening a second group is a failure rather than a
/// blind spot.
///
/// Each test asserts its own coverage — that the scan found the thing it exists to judge —
/// so an enumerator that resolved to nothing fails loudly instead of passing vacuously.
/// That is the failure this suite's neighbours were built to prevent, applied to itself.
@Suite("The write seam's SPI gate holds")
struct WriteSeamAccessTests {

    /// The one group the write seam may be offered through, and the one group any module
    /// may opt into.
    static let writeSPIGroup = "FanWrite"

    /// An `import SMCCore` carrying a run of leading attributes, captured whole so every
    /// `@_spi(…)` in that run can be read out of it.
    ///
    /// The run is `(?:@name(args)?\s*)+` rather than the single `(?:@testable\s+)?` this
    /// started as. #226's review evaded the old form with
    /// `@_spi(FanWrite) @preconcurrency import SMCCore` — a realistic spelling in a
    /// strict-concurrency codebase — which built clean and matched nothing. Any attribute,
    /// in any order, is now inside the match.
    ///
    /// The `@testable` alternation went with it, and so did the sentence justifying it:
    /// `SeamScanner.swiftFiles()` enumerates `Sources/` only, so `Tests/SMCCoreTests`'s
    /// `@_spi(FanWrite) @testable import SMCCore` was never read by this scan and that
    /// branch was unreachable. It matches now only because *every* attribute does.
    private static let spiImport = try? NSRegularExpression(
        pattern: #"((?:@[A-Za-z_]\w*(?:\s*\([^)]*\))?\s*)+)import\s+SMCCore"#)

    /// Every `@_spi(…)` attribute, wherever one appears. Used both to read the group names
    /// out of an import's attribute run and to find declarations.
    private static let spiAttribute = try? NSRegularExpression(
        pattern: #"@_spi\s*\(\s*(\w+)\s*\)"#)

    /// Every `@_spi(…)` declaration, as the group name and the text from the attribute to
    /// the opening brace, so a third member cannot be added without this test naming it.
    ///
    /// `[^{]+` spans newlines deliberately: the capture is whitespace-normalised before it
    /// is compared, so a formatter that reflows one of these signatures across two lines
    /// still matches the single-line text `expected` is written in. The earlier `[^\n{]+`
    /// stopped at the first newline and would have failed such a reflow with a confusing
    /// half-signature diff.
    private static let spiDeclaration = try? NSRegularExpression(
        pattern: #"@_spi\s*\(\s*(\w+)\s*\)\s+([^{]+)"#)

    private static func code(of file: URL) throws -> String {
        SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8))
    }

    /// Path relative to `Sources/`, so a failure names something a reader can open.
    private static func relativePath(_ file: URL) -> String {
        let components = file.pathComponents
        guard let sources = components.lastIndex(of: "Sources") else {
            return file.lastPathComponent
        }
        return components[components.index(after: sources)...].joined(separator: "/")
    }

    /// Runs of whitespace — newlines included — collapsed to single spaces, and the space a
    /// wrapped parameter list leaves inside its parentheses removed, so a captured
    /// declaration compares equal however it happens to be wrapped.
    ///
    /// Without the second half, a reflowed `encode(` … `)` normalises to
    /// `encode( scalar: … SMCByteOrder? )` and still fails against the single-line text
    /// `expected` is written in — which is the confusing half-signature diff #226's review
    /// called out, moved one step later rather than fixed.
    private static func normalised(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
            .replacingOccurrences(of: " ,", with: ",")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The SPI group names named in `text`.
    private static func spiGroups(in text: String) throws -> [String] {
        let pattern = try #require(Self.spiAttribute)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Opting into an SPI group is what makes the write seam nameable, so the opt-in itself
    /// is the boundary. `fanctl` and the app write a plain `import SMCCore` and must keep
    /// getting a module in which neither declaration exists.
    ///
    /// Two things are asserted, not one: *which* groups are imported anywhere under
    /// `Sources/` — exactly `FanWrite`, so a second group is not a silent hole — and *from
    /// where*, which is `Sources/AeolusHelper` and nowhere else.
    ///
    /// Comments are stripped first for the same reason `WritePathAbsenceTests` strips them:
    /// this file, `WriteSeamReachability.swift`'s own documentation, and the ADR all discuss
    /// the import in prose, and a tripwire that fires on the sentence describing it is a
    /// tripwire nobody keeps.
    @Test("The only SPI group imported under Sources is FanWrite, and only by the helper")
    func spiImportAppearsOnlyInTheHelper() throws {
        let pattern = try #require(Self.spiImport)
        var importers: [String] = []
        var groups: Set<String> = []

        for file in try SeamScanner.swiftFiles() {
            let text = try Self.code(of: file)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let attributes = Range(match.range(at: 1), in: text) else { continue }
                let named = try Self.spiGroups(in: String(text[attributes]))
                guard !named.isEmpty else { continue }

                groups.formUnion(named)
                importers.append(Self.relativePath(file))
                #expect(
                    file.pathComponents.contains("AeolusHelper"),
                    """
                    \(Self.relativePath(file)) opts into the \(named.joined(separator: ", ")) \
                    SPI group. Only Sources/AeolusHelper may: that opt-in is the whole of \
                    the write seam's access control — see \
                    docs/ADR/0008-write-authorisation.md.
                    """
                )
            }
        }

        #expect(
            groups == [Self.writeSPIGroup],
            """
            Sources/ opts into the SPI groups \(groups.sorted()), not \
            [\(Self.writeSPIGroup)]. A second group is a second door onto SMCCore's \
            privileged API, and the two-member declaration check below only sees the one it \
            is told about — see docs/ADR/0008-write-authorisation.md.
            """
        )

        // Coverage, not decoration. Without it an enumerator that found no files, or a
        // pattern that stopped matching the form actually written, would leave the loop
        // making zero assertions and this test green over an unguarded tree.
        #expect(
            importers.contains("AeolusHelper/WriteSeamReachability.swift"),
            """
            The FanWrite SPI import was not found in AeolusHelper/WriteSeamReachability.swift. \
            Either the reachability probe is gone — in which case nothing proves the Xcode \
            helper target can still reach the write seam — or this scan is not reading the \
            source tree.
            """
        )
    }

    /// Two members are offered through one group and no more. E4 needs both — bytes are
    /// encoded before they are written — and a third would widen the seam by exactly the
    /// amount nobody reviewed.
    ///
    /// The declarations are pinned by their full text rather than counted, so replacing one
    /// member with a different one is a failure and not a wash. The group name is captured
    /// rather than pinned, so a member offered through a *different* group is found here
    /// too, instead of being counted as zero `FanWrite` members and passing.
    @Test("Sources/SMCCore declares exactly two SPI members, both in FanWrite")
    func smcCoreDeclaresExactlyTwoSPIMembers() throws {
        let pattern = try #require(Self.spiDeclaration)
        let expected = [
            "public func encode(scalar: Double, byteOrder: SMCByteOrder?) throws -> [UInt8]",
            "public func write(_ bytes: [UInt8], to key: SMCKey) throws",
        ]

        var found: [String] = []
        var groups: Set<String> = []
        for file in try SeamScanner.swiftFiles(under: "SMCCore") {
            let text = try Self.code(of: file)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let group = Range(match.range(at: 1), in: text),
                    let captured = Range(match.range(at: 2), in: text)
                else { continue }
                groups.insert(String(text[group]))
                found.append(Self.normalised(String(text[captured])))
            }
        }

        #expect(
            groups == [Self.writeSPIGroup],
            """
            Sources/SMCCore offers the SPI groups \(groups.sorted()), not \
            [\(Self.writeSPIGroup)]. Every group is a door the helper can open with one \
            import line, and only one is reviewed — see \
            docs/ADR/0008-write-authorisation.md.
            """
        )

        #expect(
            found.sorted() == expected,
            """
            Sources/SMCCore's SPI members are \(found.sorted()), not \(expected). \
            Every member of that group is reachable from the helper by one import line. \
            Adding one is a safety review — see docs/ADR/0008-write-authorisation.md — and \
            removing one means the reachability probe no longer proves what it claims.
            """
        )
    }

    /// No declaration anywhere under `Sources/` carries the `package` access level.
    ///
    /// This is the structural half of #226's D31, and it is the control that would have
    /// caught the failure that finding describes: a contributor who has read one of the
    /// stale doc comments adds `package func write(…)` to `SMCCore` believing that is the
    /// gate. It is not. The Xcode `AeolusHelper` target consumes `SMCCore` as a *package
    /// product*, so it is outside the package `package` visibility is computed against, and
    /// such a member is unreachable from the build that produces the signed helper —
    /// invisible to `swift build`, which compiles the helper inside the package where
    /// `package` does work.
    ///
    /// The rule is repo-wide rather than `SMCCore`-only because the reason is: no target
    /// this repository ships is inside that boundary in the build that matters.
    /// `AeolusXPC/ClientAuthorisation.swift` records the same discovery, made the same way,
    /// for a different type.
    @Test("No declaration under Sources carries the package access level")
    func noSourceFileDeclaresPackageAccess() throws {
        // An attribute run is permitted *before* `package` as well as after it, and a
        // `(set)` modifier between `package` and the keyword. #226's delta review found the
        // earlier form anchored `package` to the line start with attributes allowed only
        // after it, so `@MainActor package func encode(…)` and `package private(set) var …`
        // both escaped — and for the encode half of the seam they escape the prose tripwire
        // below too, since that one only knows `package func write`.
        let attributeRun = #"(?:@[A-Za-z_]\w*(?:\s*\([^)]*\))?\s+)*"#
        let pattern = try NSRegularExpression(
            pattern: #"(?m)^\s*"# + attributeRun + #"package\s+"# + attributeRun
                + #"(?:(?:final|static|nonisolated|class|lazy|weak|unowned|mutating|override"#
                + #"|required|convenience|dynamic|indirect)\s+"#
                + #"|(?:private|fileprivate|internal|package|public)\s*\(\s*set\s*\)\s+)*"#
                + #"(?:func|var|let|init|struct|enum|class|actor|protocol|typealias|"#
                + #"extension|subscript|associatedtype)\b"#)

        let files = try SeamScanner.swiftFiles()
        #expect(!files.isEmpty, "the project's sources were not found")

        for file in files {
            let text = try Self.code(of: file)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            #expect(
                pattern.firstMatch(in: text, range: range) == nil,
                """
                \(Self.relativePath(file)) declares a `package` member. No target ships \
                inside the package Swift computes `package` visibility against — the Xcode \
                targets consume these libraries as package *products* — so a `package` \
                declaration is reachable in `swift build` and unreachable in the build that \
                produces the signed helper. Use `@_spi(\(Self.writeSPIGroup))` for the write \
                seam, or `public`; see docs/ADR/0008-write-authorisation.md.
                """
            )
        }
    }

    /// No file under `Sources/` says the write seam is `package`-scoped.
    ///
    /// The prose half of D31, and the reason it is a test rather than a one-time edit. Five
    /// doc comments still stated the retired rule when #226 was reviewed, in two phrasings
    /// the PR's own verification grep did not match — including
    /// `Sources/SMCCore/FanEnumeration.swift`, which stated it as *the project rule* inside
    /// the module the rule governs. A contributor who believes that sentence writes the
    /// `package func` the test above forbids; this one stops the sentence.
    ///
    /// Comments are emphatically **not** stripped here — they are the subject. Explaining
    /// why `package` was replaced is fine and several files do it; asserting that the seam
    /// *is* `package` is what these phrasings all do.
    @Test("No file under Sources describes the write seam as package-scoped")
    func noSourceFileCallsTheWriteSeamPackageScoped() throws {
        let retired = try NSRegularExpression(
            pattern: #"(?i)(`?package`?[- ]scoped|`package` and throws|write[- ]`package`"#
                + #"|`?package`?\s+func\s+write|write API (is )?`?package`?)"#)

        let files = try SeamScanner.swiftFiles()
        #expect(!files.isEmpty, "the project's sources were not found")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            #expect(
                retired.firstMatch(in: text, range: range) == nil,
                """
                \(Self.relativePath(file)) describes the SMC write seam as `package`-scoped. \
                It is `@_spi(\(Self.writeSPIGroup)) public` as of the 2026-09-06 amendment in \
                docs/ADR/0008-write-authorisation.md; `package` never reached the Xcode \
                helper target. Say "SPI-gated", or name the group.
                """
            )
        }
    }
}
