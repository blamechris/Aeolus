import Foundation
import Testing

/// One target's lines out of `project.yml`, read from the source tree.
///
/// `project.yml` is the build definition, and several values in it are copies of values the
/// code pins — the identifiers a client requirement names, above all. Nothing links the two
/// at compile time, so the tests that hold them equal read the file. They share this slicer
/// so that "what counts as inside a target" is one rule rather than one per suite.
///
/// The file is read through `#filePath` rather than a test-bundle resource, for the reason
/// `LaunchDaemonPlistTests` gives: the test must see the file a maintainer is editing, not a
/// copy taken when the bundle was built.
///
/// **Scoped, not searched whole.** Several targets declare a `PRODUCT_BUNDLE_IDENTIFIER`, and
/// matching the first one in the file would assert something about whichever target happens
/// to come first.
struct ProjectTarget {

    let name: String
    let lines: [Substring]

    /// The target named `name`, from its own key to the next line indented less than the
    /// target's own contents. A comment at the targets' indentation therefore ends the
    /// region, which is what keeps a block of prose above the *next* target out of this one.
    ///
    /// Fails — rather than returning an empty target — when `project.yml` declares none by
    /// that name: a tripwire that scans nothing passes.
    static func load(_ name: String, sourceFile: String = #filePath) throws -> ProjectTarget {
        let yaml = try String(contentsOf: projectFile(from: sourceFile), encoding: .utf8)
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
        let start = try #require(
            lines.firstIndex(where: { $0 == "  \(name):" }),
            "project.yml declares no \(name) target"
        )
        let rest = lines[lines.index(after: start)...]
        let end =
            rest.firstIndex { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                return line.prefix(3).filter { $0 == " " }.count < 3
            } ?? lines.endIndex
        return ProjectTarget(name: name, lines: Array(lines[start..<end]))
    }

    /// The value of the first `key:` line in the region, outer quotes and spaces removed.
    /// Comment lines never match: a line has to *start* with the key.
    func value(of key: String) throws -> String {
        let line = try #require(
            lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") },
            "project.yml's \(name) target declares no \(key)"
        )
        let value = line.drop { $0 != ":" }.dropFirst()
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    private static func projectFile(from sourceFile: String) -> URL {
        URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent()  // Tests/IntegrationTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("project.yml")
    }
}
