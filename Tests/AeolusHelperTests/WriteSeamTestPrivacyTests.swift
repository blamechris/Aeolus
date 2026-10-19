import Foundation
import Testing

// MARK: - Rule 5: nothing a file that can name the write declares is nameable from another

extension WriteSeamTestIsolationTests {

    /// Rule 5. Every top-level declaration in `allowedImporters` is `private`, the suites
    /// included, and none is an extension.
    ///
    /// What this closes is #433's item 4. An internal helper in one of these files that wraps
    /// `write(_:to:)`, called from a file that opens a connection, writes to this Mac, and rules
    /// 1–4 all stay green on it: the file that writes is not the file that opts in.
    ///
    /// **The compiler is the control, for a type.** A member of a type cannot be more visible than
    /// the type, so nothing inside a private suite can be named from another file: not a helper,
    /// and not a member of a type nested in one, `internal` or not (mutation R4 below). This test
    /// does not have to read members.
    ///
    /// **Not for an extension.** A `private extension` sets its members' default access, not their
    /// limit: their limit is the extended type's. An `internal func` inside
    /// `private extension SMCKey` is callable from every file in the target, because `SMCKey` is
    /// public, and it builds with only a warning (#447's review, B1). So every top-level
    /// `extension` here is refused, whatever its modifier. Neither file needs one.
    ///
    /// What this holds is the structure: a top-level declaration that is not `private` is red,
    /// whether it is a new suite, a free helper, or a suite whose `private` was dropped, and so is
    /// any extension. Imports declare nothing and are rule 1's. Swift Testing discovers a private
    /// suite: these two files ran 52 tests in 9 suites before their suites were made private and
    /// after (Swift 6.4).
    ///
    /// It fails closed. A declaration is found by every keyword Swift declares with, not by one
    /// spelling of it; what the census cannot read is red; and a modifier it does not know hides a
    /// `private` written before it, which reads as not private. `DeclarationCensus` says what it
    /// does not see.
    ///
    /// **Mutations**, each run against the whole suite:
    /// - a top-level `func` in `SMCConnectionWriteTests.swift` that calls `write(_:to:)` on a
    ///   connection it is handed, called from an uncalled function in `SMCKeyTests.swift`: red
    ///   here, at the `private` check;
    /// - R1, the same helper as an `internal func` in a `private extension SMCKey`: red here, at
    ///   the extension check;
    /// - the same helper as a `static func` inside its private suite (M4b), or inside an `internal
    ///   struct` nested in it with the `static func` declared `internal` (R4): neither compiles in
    ///   the other file.
    @Test("Everything a file that can name the write declares is private to that file")
    func theWriteTestFilesHandNothingOut() throws {
        let files = try SeamScanner.swiftFilesUnderTests().filter {
            Self.allowedImporters.contains(Self.relativePath($0))
        }
        #expect(
            files.count == Self.allowedImporters.count,
            "found \(files.map(Self.relativePath)), expected \(Self.allowedImporters.sorted())")

        for file in files {
            let path = Self.relativePath(file)
            let census = DeclarationCensus.outermost(
                inSource: try String(contentsOf: file, encoding: .utf8))
            #expect(
                census.unreadable.isEmpty,
                """
                \(path): the census could not read \(census.unreadable), so it cannot say what the \
                file hands out.
                """)

            let spelled = { (declaration: DeclarationCensus.Declaration) in
                (declaration.modifiers + [declaration.introducer, declaration.name])
                    .joined(separator: " ")
            }
            let exposed = census.declarations.filter { !$0.isPrivate }.map(spelled)
            #expect(
                exposed.isEmpty,
                """
                \(path) declares \(exposed) at its top level without `private`. It opts into the \
                FanWrite SPI, so a helper declared here can wrap SMCConnection.write(_:to:), and a \
                file that opens a connection could call it: the next swift test would write to \
                this Mac. Make it private, or move it to a file without the opt-in.
                """)

            let extensions = census.declarations.filter { $0.introducer == "extension" }
            #expect(
                extensions.isEmpty,
                """
                \(path) declares \(extensions.map(spelled)). An extension's members are bounded by \
                the extended type, not by the extension's own modifier, so an internal member of \
                even a private extension of a public type can wrap SMCConnection.write(_:to:) for \
                another file. Put the helper in a private type, or in a file without the opt-in.
                """)

            // Coverage: each file declares its suites at the top level, so a census that found
            // none did not read the file.
            #expect(
                census.declarations.contains { $0.attributes.contains("Suite") },
                "\(path): the census found no suite at the top level")
        }
    }
}
