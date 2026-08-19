import Foundation
import Testing

/// Scans `Sources` for function declarations, so a signature can be asserted as a property of
/// the source tree rather than of a call site.
///
/// `WritePathAbsenceTests` had the enumerator and the comment-stripping filter first and now
/// routes through this, rather than the two keeping separate copies that must agree. An
/// earlier version of this comment said "extracted rather than copied" while that extraction
/// had not happened — which was the same failure this whole suite exists to correct, in a
/// doc comment about the suite.
enum SeamScanner {

    struct Declaration {
        let file: String
        let text: String

        /// Just what sits between the parentheses, so an assertion can look at a parameter's
        /// *type position* rather than searching the whole declaration.
        ///
        /// Searching the whole text reads argument labels and sibling type names too, which
        /// is how `engageManualControlForUnlock(ofCommandableFan index: Int)` satisfied a
        /// "names a permit" check while naming no permit at all.
        var parameters: String {
            guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"),
                open < close
            else { return text }
            return String(text[text.index(after: open)..<close])
        }
    }

    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AeolusHelperTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources")
    }

    static func swiftFiles() throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the project's sources were not found")
        return files
    }

    /// Every `async` write verb whose name matches `namePattern`.
    ///
    /// `throws` is optional and the effects clause is required: it is what distinguishes a
    /// verb that reaches the firmware from a pure producer of the value it carries. See
    /// `everyTargetWriteVerbTakesAnAuthorisation` for what that buys and what it costs.
    static func writeVerbs(named namePattern: String) throws -> [Declaration] {
        try declarations(matching: #"func\s+"# + namePattern + #"\s*\([^)]*\)\s*async(\s+throws)?"#)
    }

    /// The body of a `struct` declaration, for asserting access levels the compiler will not
    /// report and no runtime test can observe.
    static func structBody(of type: String, in file: String) throws -> String {
        let url = try #require(
            swiftFiles().first { $0.lastPathComponent == file },
            "\(file) is not in the source tree")
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = try #require(
            source.range(of: #"struct \#(type)[^{]*\{[\s\S]*?\n\}"#, options: .regularExpression),
            "\(type) was not found in \(file)")
        return String(source[body])
    }

    /// Every declaration under `Sources` matching `pattern`.
    ///
    /// Comment lines are dropped first, for the reason `WritePathAbsenceTests` records: the
    /// prose describing a forbidden signature is not that signature, and a tripwire that
    /// fires on the sentence explaining the rule is a tripwire nobody keeps. The trade is
    /// that a declaration inside a block comment is invisible — contrived, where an added
    /// verb is not.
    static func declarations(matching pattern: String) throws -> [Declaration] {
        let expression = try NSRegularExpression(pattern: pattern)
        var found: [Declaration] = []

        for file in try swiftFiles() {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            for match in expression.matches(in: code, range: range) {
                guard let matched = Range(match.range, in: code) else { continue }
                found.append(
                    Declaration(
                        file: file.lastPathComponent,
                        text: String(code[matched]).replacingOccurrences(of: "\n", with: " ")))
            }
        }
        return found
    }
}
