import Foundation
import Testing

/// The two controls that replace what `package` visibility used to supply on the SMC write
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
/// through the group. Neither test claims to stop a determined caller. Both catch the
/// accident, which is the realistic regression.
///
/// Each test asserts its own coverage — that the scan found the thing it exists to judge —
/// so an enumerator that resolved to nothing fails loudly instead of passing vacuously.
/// That is the failure this suite's neighbours were built to prevent, applied to itself.
@Suite("The write seam's SPI gate holds")
struct WriteSeamAccessTests {

    /// The one form the opt-in may take. `@testable` is permitted between the attribute and
    /// the import because the `SMCCore` unit tests need both, but nothing under `Sources/`
    /// is `@testable`, so a match there is the plain form.
    private static let spiImport = try? NSRegularExpression(
        pattern: #"@_spi\s*\(\s*FanWrite\s*\)\s*(?:@testable\s+)?import\s+SMCCore"#)

    /// Every `@_spi(FanWrite)` declaration, as the text from the attribute to the opening
    /// brace, so a third member cannot be added without this test naming it.
    private static let spiDeclaration = try? NSRegularExpression(
        pattern: #"@_spi\s*\(\s*FanWrite\s*\)\s+([^\n{]+)"#)

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

    /// Opting into `FanWrite` is what makes the write seam nameable, so the opt-in itself is
    /// the boundary. `fanctl` and the app write a plain `import SMCCore` and must keep
    /// getting a module in which neither declaration exists.
    ///
    /// Comments are stripped first for the same reason `WritePathAbsenceTests` strips them:
    /// this file, `WriteSeamReachability.swift`'s own documentation, and the ADR all discuss
    /// the import in prose, and a tripwire that fires on the sentence describing it is a
    /// tripwire nobody keeps.
    @Test("The FanWrite SPI import appears only under Sources/AeolusHelper")
    func spiImportAppearsOnlyInTheHelper() throws {
        let pattern = try #require(Self.spiImport)
        var importers: [String] = []

        for file in try SeamScanner.swiftFiles() {
            let text = try Self.code(of: file)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard pattern.firstMatch(in: text, range: range) != nil else { continue }
            importers.append(Self.relativePath(file))
            #expect(
                file.pathComponents.contains("AeolusHelper"),
                """
                \(Self.relativePath(file)) opts into the FanWrite SPI group. Only \
                Sources/AeolusHelper may: that opt-in is the whole of the write seam's \
                access control — see docs/ADR/0008-write-authorisation.md.
                """
            )
        }

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

    /// Two members are offered through the group and no more. E4 needs both — bytes are
    /// encoded before they are written — and a third would widen the seam by exactly the
    /// amount nobody reviewed.
    ///
    /// The declarations are pinned by their full text rather than counted, so replacing one
    /// member with a different one is a failure and not a wash.
    @Test("Sources/SMCCore declares exactly two @_spi(FanWrite) members")
    func smcCoreDeclaresExactlyTwoSPIMembers() throws {
        let pattern = try #require(Self.spiDeclaration)
        let expected = [
            "public func encode(scalar: Double, byteOrder: SMCByteOrder?) throws -> [UInt8]",
            "public func write(_ bytes: [UInt8], to key: SMCKey) throws",
        ]

        var found: [String] = []
        for file in try SeamScanner.swiftFiles(under: "SMCCore") {
            let text = try Self.code(of: file)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let captured = Range(match.range(at: 1), in: text) else { continue }
                found.append(
                    text[captured].trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "{", with: "")
                        .trimmingCharacters(in: .whitespaces))
            }
        }

        #expect(
            found.sorted() == expected,
            """
            Sources/SMCCore's @_spi(FanWrite) members are \(found.sorted()), not \(expected). \
            Every member of that group is reachable from the helper by one import line. \
            Adding one is a safety review — see docs/ADR/0008-write-authorisation.md — and \
            removing one means the reachability probe no longer proves what it claims.
            """
        )
    }
}
