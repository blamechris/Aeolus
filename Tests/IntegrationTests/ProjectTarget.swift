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
///
/// **A value is read only if it is declared once.** XcodeGen lets any build setting be
/// restated per configuration (`settings: configs: Full Release: KEY: value`), and the
/// restatement wins in that configuration. A reader that returned the first declaration would
/// stay green while one configuration — the one that ships — built with a different value.
/// So `value(of:)` refuses a key that appears more than once in the region, wherever it
/// appears. It reads text, not the resolved build settings, so it cannot see a value set
/// somewhere else (a flag in `OTHER_CODE_SIGN_FLAGS`, the gitignored `Signing.xcconfig`); CI's
/// "Assert every configuration signs fanctl with the identifier the helper pins" step asks
/// Xcode for the resolved answer and covers what text cannot.
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
        return try #require(
            slice(name, from: yaml),
            "project.yml declares no \(name) target"
        )
    }

    /// The pure half of `load`: the region of `yaml` that belongs to the target named `name`,
    /// or `nil` if there is none.
    static func slice(_ name: String, from yaml: String) -> ProjectTarget? {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0 == "  \(name):" }) else { return nil }
        let rest = lines[lines.index(after: start)...]
        let end =
            rest.firstIndex { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                return line.prefix(3).filter { $0 == " " }.count < 3
            } ?? lines.endIndex
        return ProjectTarget(name: name, lines: Array(lines[start..<end]))
    }

    /// Every line in the region that declares `key`, in file order.
    ///
    /// A declaration is a line that *starts* with the key, so a comment never counts. Three
    /// spellings are the same declaration: `KEY:`, a quoted `"KEY":`, and the conditional
    /// `"KEY[config=Full Release]":` that XcodeGen passes through to Xcode. The conditional
    /// form is a way to give one configuration or SDK a different value without writing
    /// `configs:`, so it has to count.
    func declarations(of key: String) -> [Substring] {
        lines.filter { line in
            let text = line.trimmingCharacters(in: .whitespaces)
                .drop { $0 == "\"" || $0 == "'" }
            guard text.hasPrefix(key) else { return false }
            let next = text.dropFirst(key.count).first
            return next == ":" || next == "[" || next == "\"" || next == "'"
        }
    }

    /// The value of `key`, outer quotes and spaces removed. Fails if the key is not declared
    /// in this target, and fails if it is declared more than once.
    func value(of key: String) throws -> String {
        let found = declarations(of: key)
        let line = try #require(
            found.first,
            "project.yml's \(name) target declares no \(key)"
        )
        try #require(
            found.count == 1,
            """
            project.yml's \(name) target declares \(key) \(found.count) times. A second \
            declaration (under `configs:`, or as `\(key)[…]`) gives one configuration a value \
            this test did not read.
            """
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
