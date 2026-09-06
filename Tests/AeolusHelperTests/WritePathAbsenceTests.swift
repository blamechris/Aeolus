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
/// stays behind the `FanWrite` SPI group and still throws, and that E5 does not exist.
/// `WriteSeamAccessTests` guards the access level itself; this suite guards the calls.
@Suite("No write path exists in this tree")
struct WritePathAbsenceTests {

    /// The enumerator lives in `SeamScanner` now, so this suite and
    /// `WriteAuthorisationTests` cannot disagree about which files count as the source tree.
    /// It also carries the non-empty guard that used to be on only one of the two tests here.
    private static func swiftFiles() throws -> [URL] {
        try SeamScanner.swiftFiles()
    }

    /// The SMC's read selectors are 5 (`READ_BYTES`), 8 (`READ_INDEX`) and 9
    /// (`READ_KEYINFO`). Anything defining another selector constant is defining a write.
    @Test("No source file declares an SMC selector other than the three read selectors")
    func noWriteSelectorConstantExists() throws {
        let allowed: Set<String> = ["5", "8", "9"]
        let pattern = try NSRegularExpression(
            pattern: #"selector[A-Za-z]*\s*:\s*UInt8\s*=\s*(\d+)"#)

        // Without this, a `sourcesRoot` that resolved wrongly would enumerate nothing, the
        // loop below would make zero assertions, and the strongest safety property in the
        // project would be asserted by a green test that checked no files at all. Its
        // sibling `helperNeverCallsWrite` has always had the equivalent line.
        let files = try Self.swiftFiles()
        #expect(!files.isEmpty, "the project's sources were not found")

        for file in files {
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

    /// The one file permitted to *name* the write seam. Everything else in the helper may
    /// not contain the text `.write(` at all.
    ///
    /// #160 gave the helper a reachability probe, because `@_spi(FanWrite) public`
    /// replaced `package` on `SMCConnection.write(_:to:)` and an access level is only
    /// proven by a reference the compiler must resolve. That reference is written as a
    /// compound name — `self.write(_:to:)` — so the file contains the text this test used
    /// to forbid outright. Naming the exception rather than deleting the rule is the
    /// point: one file, by name, with zero calls in it.
    static let writeSeamProbe = "WriteSeamReachability.swift"

    /// The helper is the only thing that could reach `SMCConnection.write(_:to:)`, and it
    /// never calls it.
    ///
    /// Comment lines are dropped before the scan, which is not a detail: this file's first
    /// green run failed on `AeolusHelperMain`'s own documentation explaining that
    /// `SMCConnection.write(_:to:)` was `package`-scoped and still throws. A tripwire that
    /// fires on the sentence saying the thing does not exist is a tripwire nobody keeps.
    /// The trade is that a call hidden after code on a commented line is not seen — which
    /// is a contrived case, where an added write is not.
    ///
    /// A *mention* and a *call* are now distinguished, because the probe has to make one
    /// without making the other. What is counted is a call site: `.write(` whose argument
    /// list is anything other than a compound name's label placeholders. `.write(_:to:)`
    /// is a reference; `.write(bytes, to: key)` is a write, and so is `.write()`.
    @Test("The helper target never calls the SMC write API")
    func helperNeverCallsWrite() throws {
        let helperSources = try Self.swiftFiles().filter {
            $0.pathComponents.contains("AeolusHelper")
        }
        #expect(!helperSources.isEmpty, "the helper's sources were not found")

        var mentioning: [String] = []
        for file in helperSources {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")

            let arguments = Self.writeArgumentLists(in: code)
            guard !arguments.isEmpty else { continue }
            mentioning.append(file.lastPathComponent)

            #expect(
                file.lastPathComponent == Self.writeSeamProbe,
                """
                \(file.lastPathComponent) names the SMC write API. Only \
                \(Self.writeSeamProbe) may, and only as a reference — see \
                docs/ADR/0008-write-authorisation.md.
                """
            )
            for argumentList in arguments {
                #expect(
                    Self.isCompoundName(argumentList),
                    """
                    \(file.lastPathComponent) calls a write: .write(\(argumentList)). E3/E4 \
                    do not exist, and the reachability probe references the seam without \
                    invoking it.
                    """
                )
            }
        }

        // Coverage. Without it, an enumerator that found nothing — or a scan that stopped
        // recognising `.write(` — would make zero assertions above and report the tree
        // clean. The probe is the one file guaranteed to be seen.
        #expect(
            mentioning == [Self.writeSeamProbe],
            """
            Expected exactly \(Self.writeSeamProbe) to name the SMC write API; found \
            \(mentioning). If the probe is gone, nothing proves the Xcode helper target can \
            still reach the write seam.
            """
        )
    }

    /// The text inside the parentheses of every `.write(…)` occurrence, parenthesis-balanced
    /// rather than stopped at the first `)`, so a nested call in an argument is not read as
    /// the end of the list.
    private static func writeArgumentLists(in code: String) -> [String] {
        var lists: [String] = []
        var searchStart = code.startIndex

        while let open = code.range(of: ".write(", range: searchStart..<code.endIndex) {
            var depth = 1
            var index = open.upperBound
            while index < code.endIndex, depth > 0 {
                if code[index] == "(" { depth += 1 }
                if code[index] == ")" { depth -= 1 }
                index = code.index(after: index)
            }
            let close = depth == 0 ? code.index(before: index) : code.endIndex
            lists.append(String(code[open.upperBound..<close]))
            searchStart = index
        }
        return lists
    }

    /// Whether an argument list is a compound *name* — `_:to:` — rather than arguments.
    ///
    /// A compound name is a run of `label:` and `_:` and nothing else: no values, no
    /// whitespace, and never empty. `.write()` therefore reads as a call, which is what it
    /// is.
    private static func isCompoundName(_ argumentList: String) -> Bool {
        guard !argumentList.isEmpty, argumentList.hasSuffix(":") else { return false }
        return argumentList.split(separator: ":", omittingEmptySubsequences: false)
            .dropLast()
            .allSatisfy { label in
                label == "_"
                    || (!label.isEmpty
                        && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
            }
    }
}
