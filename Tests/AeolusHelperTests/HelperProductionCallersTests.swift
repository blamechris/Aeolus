import Foundation
import Testing

/// Who inside `Sources/AeolusHelper` may write the word `production` (#453).
///
/// **Rule zero: no test may write to this Mac's SMC.** `NotBuiltRequireTripwireTests` judges every
/// `.production` a test file writes except `fanctl`'s two, `SettleClock.production` and
/// `HelperConnection.production`, which it excepts by receiver name, and it reads `Tests/`. A
/// function in the helper module that wraps `HelperComposition.production`,
///
/// ```swift
/// func zzGraph() -> HelperComposition<SMCFanControlPlane> { .production(log: HelperLog()) }
/// ```
///
/// lets a test build the real graph by calling `zzGraph()`, with no `.production` token for that
/// tripwire to judge. Nothing refused such a wrapper (#453: the probe that showed it compiled one
/// into the helper module, and every test stayed green). This suite pins the files that name it.
///
/// **What it reads.** Every `.swift` file under `Sources/AeolusHelper/`, any extension case, as
/// code: comments, then string literals (the code inside an interpolation kept), then backticks
/// are removed by the scanners every rule-zero tripwire shares (`RuleZeroScan.code(of:)`). The
/// identifier `production` is then counted, per file, and the map is compared with `==` to
/// `pinned`. So a new file that names it is red, and so is a second mention in either listed file,
/// or one fewer.
///
/// **Why the bare identifier, and neither `RuleZeroScan.productionMember` nor a pin on
/// `production(`.** `productionMember` needs a `.` before the word, and excepts
/// `SettleClock.production` and `HelperConnection.production` by name, which are `fanctl`'s. Both
/// are wrong here: inside an extension of the composition, `production(` is called bare (#436's
/// delta review, B4), and an exception by name would also except a
/// `typealias SettleClock = HelperComposition<…>`. A pin on `production(`, which #453 suggested,
/// is wrong too: an unapplied `let f = HelperComposition.production` has no `(`, and is the
/// factory taken as a value. The identifier counts every mention `productionMember` counts, and
/// it also counts the declaration, which is the second pinned file.
///
/// **A file it cannot read is a finding.** An unreadable file or directory, a file that is not
/// UTF-8, and a symbolic link (SwiftPM compiles what is behind one, and this does not follow it)
/// are each recorded and fail the suite, never skipped.
///
/// **What it does not read.** It counts mentions; it does not say which function holds them, so a
/// wrapper written in `AeolusHelperMain.swift` or `HelperComposition.swift` that replaces a
/// mention with another leaves the count where it was, and review of those two files is what
/// holds that. A graph assembled by hand without the factory has no such mention. Files outside
/// `Sources/AeolusHelper/` are `HelperDependentsTests`' (an import of the helper) and
/// `NotBuiltRequireTripwireTests`' (the tests). These scans catch accidents, and every spelling
/// met so far; a deliberate author can evade a lexical reading. ADR 0014's compiler seam is the
/// control.
@Suite("Code under Sources/AeolusHelper names production only in the two files that may")
struct HelperProductionCallersTests {

    /// Each file under the helper whose code names `production`, and how many times. Two, once
    /// each: the daemon's one call, in `AeolusHelperMain`, and the composition's declaration of
    /// the factory. A third file, or a second mention in either, is a function that can build the
    /// real graph; put what it needs under `Tests/`, judged by `NotBuiltRequireTripwireTests`, or
    /// justify it in review and here.
    static let pinned: [String: Int] = [
        "Sources/AeolusHelper/AeolusHelperMain.swift": 1,
        "Sources/AeolusHelper/HelperComposition.swift": 1,
    ]

    /// **Mutations**, each in a new file under `Sources/AeolusHelper/` and removed, with a disabled
    /// test that names the wrapper and never runs it: (W1) `func zzGraph() ->
    /// HelperComposition<SMCFanControlPlane> { .production(log: HelperLog()) }`; (W2) the same
    /// wrapper taking `HelperComposition<SMCFanControlPlane>.production` as a value and applying
    /// it; (W2b) `let zzFactory = HelperComposition<SMCFanControlPlane>.production` and no call.
    /// Run: red here, each.
    @Test("Only AeolusHelperMain.swift and HelperComposition.swift name production, once each")
    func onlyTwoFilesNameProduction() throws {
        let directory = RuleZeroScan.repositoryRoot.appendingPathComponent(
            ManifestScan.helperDirectory)
        let census = try HelperProductionMentions.census(
            of: directory, as: ManifestScan.helperDirectory)
        #expect(census.refused.isEmpty, "the census could not read: \(census.refused)")
        let found = HelperProductionMentions.listing(census.counts)
        #expect(
            census.counts == Self.pinned,
            """
            The files that name production in code are \(found), not \
            \(HelperProductionMentions.listing(Self.pinned)). A function in the helper that \
            calls or takes HelperComposition.production lets a test build the real graph with no \
            .production token for rule zero to judge (#453).
            """)
        #expect(census.read > 50, "the census read \(census.read) files, which is not the tree")
    }

    /// Every spelling of a mention, and what is not one. Each source holds the count it names, so
    /// a spelling that stopped matching is red at its own line.
    ///
    /// **Mutations**, each restored: in `identifier`, require a `.` before the word (red at the
    /// bare spellings), require a `(` after it (red at the unapplied ones), drop the trailing
    /// `(?![A-Za-z0-9_])` (red at the lookalikes), drop the leading one (red at `reproduction`);
    /// in `mentions(in:)`, read the source raw (red at the comment and string fixtures); in
    /// `SeamScanner.strippingComments`, drop each line whose trimmed text begins `//` again (red
    /// at the three fixtures of #457, whose `//` opens a line of a literal).
    @Test("A mention is counted however it is spelled; prose and lookalike names are not")
    func mentionsAreCountedInEverySpelling() throws {
        let counted: [(source: String, count: Int)] = [
            ("let g = HelperComposition.production(log: HelperLog())", 1),
            ("func zzGraph() -> HelperComposition { .production(log: HelperLog()) }", 1),
            ("let g: HelperComposition<SMCFanControlPlane> = .production(log: log)", 1),
            ("let f = HelperComposition.production", 1),
            ("let f = HelperComposition<SMCFanControlPlane>.production", 1),
            ("let f = (HelperComposition.production)", 1),
            ("let k = \\HelperComposition<SMCFanControlPlane>.production", 1),
            ("HelperComposition.self.production(log: log)", 1),
            ("AeolusHelper.HelperComposition.production(log: log)", 1),
            ("HelperComposition\n    .production(\n        log: log)", 1),
            ("HelperComposition . production ( log: log )", 1),
            ("HelperComposition.`production`(log: log)", 1),
            ("HelperComposition.production/* the daemon */(log: log)", 1),
            ("typealias Graph = HelperComposition<SMCFanControlPlane>\nGraph.production()", 1),
            ("extension HelperComposition {\n    static func zz() { production(log: log) }\n}", 1),
            ("let f = production", 1),
            ("let g = HelperComposition.production(log: log) // the daemon's graph", 1),
            ("/* a */ HelperComposition.production(log: log) /* b */", 1),
            ("let s = \"\\(HelperComposition.production(log: log))\"", 1),
            ("let s = #\"\\#(HelperComposition.production(log: log))\"#", 1),
            // #457: a `//` at the start of a line of a multi-line literal is the literal's text.
            ("let s = \"\"\"\n//\\(HelperComposition.production(log: log))\n\"\"\"", 1),
            (
                "func zz() -> String {\n    \"\"\"\n    //\\(.production(log: log))\n    \"\"\"\n}",
                1
            ),
            ("let s = #\"\"\"\n    ///\\#(HelperComposition.production(log: log))\n    \"\"\"#", 1),
            ("let s = \"\\(\"x\") \\(HelperComposition.production(log: log))\"", 1),
            ("let a = production(log: a); let b = production(log: b)", 2),
            ("production(log: a)\nproduction(log: b)\nlet f = .production", 3),
        ]
        for (source, count) in counted {
            #expect(try HelperProductionMentions.mentions(in: source) == count, "\(source)")
        }

        let uncounted = [
            "// HelperComposition.production(log:)", "/// production(log:) names hardware",
            "/* HelperComposition.production(log:) */ let a = 1",
            "/* a /* nested production( */ production( */",
            "let s = \"HelperComposition.production(log:)\"", "let s = #\"production(\"#",
            "let s = \"\"\"\n    HelperComposition.production(log:)\n    \"\"\"",
            "let s = \"\"\"\n    // HelperComposition.production(log:)\n    \"\"\"",
            "let reproduction = 1", "let productionGraph = 1", "let isproduction = 1",
            "HelperComposition.productionGraph(log: log)", "HelperComposition.Production",
            "let production_ = 1", "let production2 = 1", "let a = 1 // production",
            "let s = \"production\" + \"(\"",
        ]
        for source in uncounted {
            #expect(try HelperProductionMentions.mentions(in: source) == 0, "\(source)")
        }
    }

    /// The census on a directory shaped like the helper's, with what it must count and what it
    /// must refuse. A file it cannot read is a finding and never a skip; a census that skipped one
    /// would report a clean tree.
    ///
    /// **Mutations**, each restored: in `read`, skip a file that cannot be read instead of
    /// recording it (red at the bad-encoding fixture); compare the extension without
    /// lowercasing (red at `Upper.SWIFT`); drop the symbolic-link check (red at the link
    /// fixtures); swallow a directory that cannot be listed (red at the missing-directory
    /// fixture).
    @Test("The census counts per file, reads nested files and any extension case, and refuses")
    func theCensusFailsClosed() throws {
        let read = try Self.withTree([
            "A.swift": Data("let g = HelperComposition.production(log: log)".utf8),
            "Sub/B.swift": Data("production(log: a); production(log: b)".utf8),
            "Sub/Upper.SWIFT": Data("let f = production".utf8),
            "Sub/Plain.swift": Data("// production(\nlet a = 1".utf8),
            "Notes.md": Data("production(".utf8),
        ]) { root in
            try HelperProductionMentions.census(of: root, as: "P")
        }
        #expect(read.refused.isEmpty, "\(read.refused)")
        #expect(read.read == 4, "\(read.read)")
        #expect(read.counts == ["P/A.swift": 1, "P/Sub/B.swift": 2, "P/Sub/Upper.SWIFT": 1])

        let bytes = try Self.withTree(["Bad.swift": Data([0x70, 0xFF, 0xFE, 0x28])]) { root in
            try HelperProductionMentions.census(of: root, as: "P")
        }
        #expect(bytes.refused.count == 1, "\(bytes.refused)")
        #expect(bytes.refused.first?.hasPrefix("P/Bad.swift") == true, "\(bytes.refused)")
        #expect(bytes.counts.isEmpty && bytes.read == 1, "\(bytes)")

        let files = ["A.swift": Data("let a = 1".utf8), "Dir/B.txt": Data()]
        let linked = try Self.withTree(files) { root in
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("Link.swift"),
                withDestinationURL: root.appendingPathComponent("A.swift"))
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("LinkedDir"),
                withDestinationURL: root.appendingPathComponent("Dir"))
            return try HelperProductionMentions.census(of: root, as: "P")
        }
        let links = linked.refused.map { String($0.prefix(while: { $0 != ":" })) }
        #expect(links == ["P/Link.swift", "P/LinkedDir"], "\(linked.refused)")
        #expect(linked.read == 1, "\(linked.read)")

        let missing = try HelperProductionMentions.census(
            of: FileManager.default.temporaryDirectory.appendingPathComponent(
                "aeolus-production-\(UUID().uuidString)"),
            as: "P")
        #expect(missing.refused.count == 1, "\(missing.refused)")
        #expect(missing.read == 0 && missing.counts.isEmpty, "\(missing)")
    }

    /// A temporary directory holding `files`, built per test and removed after.
    private static func withTree<T>(
        _ files: [String: Data], _ body: (URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aeolus-production-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return try body(root)
    }
}

/// The reading behind `HelperProductionCallersTests`: the identifier, and the census over a
/// directory. A sibling type and not a nested one, so the suite stays its tests.
enum HelperProductionMentions {

    /// The word `production` as an identifier: whole, so `reproduction`, `productionGraph` and
    /// `production_` are other names. Matched in code, where a backtick, a comment or a string has
    /// been removed (`RuleZeroScan.code(of:)`).
    static let identifier = #"(?<![A-Za-z0-9_])production(?![A-Za-z0-9_])"#

    /// What a census read.
    struct Census: Equatable {
        /// Each file whose code names the identifier, by path from the prefix, and how many times.
        var counts: [String: Int] = [:]
        /// How many `.swift` files were read.
        var read = 0
        /// Each thing it could not read, or would not follow, and why. Never empty on a tree with
        /// a hole in it.
        var refused: [String] = []
    }

    /// `counts` as `path: count`, in path order, for a failure message.
    static func listing(_ counts: [String: Int]) -> [String] {
        counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    }

    /// How many times `source`'s code names the identifier.
    static func mentions(in source: String) throws -> Int {
        try RuleZeroScan.count(identifier, in: RuleZeroScan.code(of: source))
    }

    /// The census of `directory` and everything below it, with paths written as `prefix` plus the
    /// path below `directory`. A file with the extension `swift` in any case is read: SwiftPM may
    /// compile it, and a census that skipped it would be blind to it.
    static func census(of directory: URL, as prefix: String) throws -> Census {
        var census = Census()
        try read(directory, as: prefix, into: &census)
        return census
    }

    private static func read(_ directory: URL, as path: String, into census: inout Census) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys)
        } catch {
            census.refused.append("\(path): the directory cannot be listed (\(error))")
            return
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let here = path + "/" + entry.lastPathComponent
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                let isLink = values.isSymbolicLink, let isDirectory = values.isDirectory
            else {
                census.refused.append("\(here): its attributes cannot be read")
                continue
            }
            if isLink {
                census.refused.append("\(here): a symbolic link, which this does not follow")
            } else if isDirectory {
                try read(entry, as: here, into: &census)
            } else if entry.pathExtension.lowercased() == "swift" {
                census.read += 1
                guard let source = try? String(contentsOf: entry, encoding: .utf8) else {
                    census.refused.append("\(here): the file cannot be read as UTF-8")
                    continue
                }
                let count = try mentions(in: source)
                if count > 0 { census.counts[here] = count }
            }
        }
    }
}
