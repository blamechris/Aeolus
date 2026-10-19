import Foundation
import Testing

// MARK: - Rule 5: nothing a file that can name the write declares is nameable from another

extension WriteSeamTestIsolationTests {

    /// Rule 5. Every top-level declaration in `allowedImporters` is `private`, the suites
    /// included, so everything inside them is file-private too: a member's access cannot exceed
    /// its type's.
    ///
    /// What this closes is #433's item 4. An internal helper in one of these files that wraps
    /// `write(_:to:)`, called from a file that opens a connection, writes to this Mac, and rules
    /// 1–4 all stay green on it: the file that writes is not the file that opts in.
    ///
    /// **The compiler is the control.** A private suite cannot be named from another file, so
    /// neither can a helper inside one, and this test does not have to read members. What it holds
    /// is the structure: a top-level declaration that is not `private` is red, whether it is a new
    /// suite, a free helper, an extension, or a suite whose `private` was dropped. Imports declare
    /// nothing and are rule 1's. Swift Testing discovers a private suite: these two files ran 52
    /// tests in 9 suites before their suites were made private and after (Swift 6.4).
    ///
    /// It fails closed. A declaration is found by every keyword Swift declares with, not by one
    /// spelling of it; what the census cannot read is red; and a modifier it does not know hides a
    /// `private` written before it, which reads as not private. `DeclarationCensus` says what it
    /// does not see.
    ///
    /// **Mutation:** a top-level `func` in `SMCConnectionWriteTests.swift` that calls
    /// `write(_:to:)` on a connection it is handed, called from an uncalled function in
    /// `SMCKeyTests.swift`. Run: red here. The same helper as a `static func` inside its private
    /// suite does not compile in the other file.
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

            let exposed = census.declarations.filter { !$0.isPrivate }.map {
                ($0.modifiers + [$0.introducer, $0.name]).joined(separator: " ")
            }
            #expect(
                exposed.isEmpty,
                """
                \(path) declares \(exposed) at its top level without `private`. It opts into the \
                FanWrite SPI, so a helper declared here can wrap SMCConnection.write(_:to:), and a \
                file that opens a connection could call it: the next swift test would write to \
                this Mac. Make it private, or move it to a file without the opt-in.
                """)

            // Coverage: each file declares its suites at the top level, so a census that found
            // none did not read the file.
            #expect(
                census.declarations.contains { $0.attributes.contains("Suite") },
                "\(path): the census found no suite at the top level")
        }
    }
}
