import Foundation
import Testing

@testable import AeolusHelper

/// E2's strongest safety property is structural: **it cannot fail open into a write,
/// because there is no write to fail into.**
///
/// That is a property of the source tree, not of a code path, so it is asserted against
/// the source tree. Reading the files via `#filePath` rather than a test-bundle resource
/// for the same reason `LaunchDaemonPlistTests` does: the point is to check the artefact
/// that actually ships.
///
/// This is a tripwire, not a proof. It cannot see a write reached by arithmetic on a
/// selector, and it is not trying to — what it catches is the realistic regression, which
/// is somebody adding `kSMCWriteBytes = 6` "ready for E5" and nobody noticing until the
/// helper is signed and installed. The real guard is that `SMCConnection.write(_:to:)`
/// stays `package`-scoped and still throws, and that E5 does not exist.
@Suite("No write path exists in this tree")
struct WritePathAbsenceTests {

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AeolusHelperTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources")
    }

    private static func swiftFiles() throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sourcesRoot,
                includingPropertiesForKeys: nil
            )
        )
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The SMC's read selectors are 5 (`READ_BYTES`), 8 (`READ_INDEX`) and 9
    /// (`READ_KEYINFO`). Anything defining another selector constant is defining a write.
    @Test("No source file declares an SMC selector other than the three read selectors")
    func noWriteSelectorConstantExists() throws {
        let allowed: Set<String> = ["5", "8", "9"]
        let pattern = try NSRegularExpression(
            pattern: #"selector[A-Za-z]*\s*:\s*UInt8\s*=\s*(\d+)"#)

        for file in try Self.swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[valueRange])
                #expect(
                    allowed.contains(value),
                    """
                    \(file.lastPathComponent) declares SMC selector \(value). The read \
                    selectors are 5, 8 and 9; anything else is a write, and no write may \
                    exist before E5.
                    """
                )
            }
        }
    }

    /// The helper is the only thing that could reach `SMCConnection.write(_:to:)`, and it
    /// does not.
    ///
    /// Comment lines are dropped before the scan, which is not a detail: this file's first
    /// green run failed on `AeolusHelperMain`'s own documentation explaining that
    /// `SMCConnection.write(_:to:)` is `package`-scoped and still throws. A tripwire that
    /// fires on the sentence saying the thing does not exist is a tripwire nobody keeps.
    /// The trade is that a call hidden after code on a commented line is not seen — which
    /// is a contrived case, where an added write is not.
    @Test("The helper target never calls the SMC write API")
    func helperNeverCallsWrite() throws {
        let helperSources = try Self.swiftFiles().filter {
            $0.pathComponents.contains("AeolusHelper")
        }
        #expect(!helperSources.isEmpty, "the helper's sources were not found")

        for file in helperSources {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(
                !code.contains(".write("),
                "\(file.lastPathComponent) calls a write. E5 does not exist."
            )
        }
    }
}
