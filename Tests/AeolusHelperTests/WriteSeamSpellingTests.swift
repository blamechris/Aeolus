import Foundation
import Testing

/// Three spellings #436's delta review found past the rebuilt guards, each closed here.
///
/// - A typealias of a seam type carries an extension past every check that reads the type's name.
/// - A bare `write`, taken as a value through an implicit `self`, is a use no call or member
///   pattern reads.
/// - A `Task` spawned inside a write-turn job runs after the turn ends.
@Suite("The write seam's other spellings")
struct WriteSeamSpellingTests {

    // MARK: - Aliases of the seam types

    /// `typealias C = SMCConnection` and then `extension C {}` is an extension of the connection
    /// that rule 3 and `noHelperFileOpensSMCConnectionsIsolation` both read past. So no alias of
    /// either seam type is written anywhere but SMCCore, and the extension rules cover the rest.
    static let seamAlias =
        #"(?<![A-Za-z0-9_])typealias\s+\w+\s*(?:<[^=]*>)?\s*=\s*(?:SMCCore\s*\.\s*)?"#
        + #"(?:SMCConnection|SMCKeyType)(?![A-Za-z0-9_])"#

    /// **Mutation:** `typealias Connection = SMCConnection` in a helper file. Run: red here.
    @Test("Nothing outside SMCCore aliases SMCConnection or SMCKeyType")
    func noSeamTypeIsAliased() throws {
        var aliasing: [String] = []
        var read = 0
        for directory in ["Sources", "Tests", "Tools"] {
            for file in try RuleZeroScan.files(under: directory)
            where !file.path.hasPrefix("Sources/SMCCore/") {
                read += 1
                if try RuleZeroScan.count(Self.seamAlias, in: file.code) > 0 {
                    aliasing.append(file.path)
                }
            }
        }
        #expect(
            aliasing.isEmpty,
            "\(aliasing) alias a seam type, which an extension of the alias would open")
        #expect(read > 200, "the scan read \(read) files, which is not the tree")
    }

    /// **Mutation:** drop `(?:SMCCore\s*\.\s*)?` from `seamAlias`. Run: red here.
    @Test("An alias of either seam type is found, qualified or not")
    func seamAliasesAreFound() throws {
        for source in [
            "typealias C = SMCConnection", "typealias K = SMCCore.SMCKeyType",
            "public typealias Conn = SMCCore . SMCConnection",
        ] {
            #expect(try RuleZeroScan.count(Self.seamAlias, in: RuleZeroScan.code(of: source)) == 1)
        }
        for source in [
            "typealias R = SMCConnectionRecycler", #"let s = "typealias C = SMCConnection""#,
        ] {
            #expect(try RuleZeroScan.count(Self.seamAlias, in: RuleZeroScan.code(of: source)) == 0)
        }
    }

    // MARK: - A bare write

    /// **Mutation:** in `bareWriteUses`, take every `write:` as a label, whatever precedes it. Run:
    /// red here, at the ternary.
    @Test("A bare write taken as a value is a use, and a label, a call or a member is not")
    func bareWritesAreFound() throws {
        let uses = [
            "extension SMCWriteChannel { func f(_ k: SMCKey) throws { let submit = write } }",
            "try keys.forEach { try apply(write, $0) }",
            "let chosen = flag ? write : read",
            "return write",
        ]
        for source in uses {
            #expect(try WritePathAbsenceTests.bareWriteUses(in: source).count == 1, "\(source)")
        }
        let notUses = [
            "func write(_ bytes: [UInt8], to key: SMCKey) throws",
            "try $0.write(bytes, to: key)",
            "let w = connection.write(_:to:)",
            "foo(write: bytes)",
            "func restore(for write: Plan) {}",
            "overwrite(bytes); didWrite = true",
            "write<T>(value)",
        ]
        for source in notUses {
            #expect(try WritePathAbsenceTests.bareWriteUses(in: source).isEmpty, "\(source)")
        }
    }

    // MARK: - A task spawned inside a write turn

    /// What a `withWriteTurn(on:…)` call is handed as its job: a closure's body, or `nil` when the
    /// job is not a closure written at the call — a function passed by name, which this scan
    /// cannot read and so refuses (#436's final review, N2).
    static func writeTurnJobs(in code: String) throws -> [Substring?] {
        let call = try NSRegularExpression(pattern: #"(?<!func\s)withWriteTurn\s*\("#)
        var jobs: [Substring?] = []
        for match in call.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let found = Range(match.range, in: code),
                let close = SeamScanner.closingParenthesis(
                    in: code, openingAt: code.index(before: found.upperBound))
            else {
                jobs.append(nil)
                continue
            }
            let arguments = code[found.upperBound..<close]
            if let open = arguments.firstIndex(of: "{") {
                jobs.append(RuleZeroScan.balanced(in: code, from: open))
            } else if let next = code[code.index(after: close)...].firstIndex(where: {
                !$0.isWhitespace
            }), code[next] == "{" {
                jobs.append(RuleZeroScan.balanced(in: code, from: next))
            } else {
                jobs.append(nil)
            }
        }
        return jobs
    }

    /// A `Task` spawned, in any spelling that makes one (#441):
    /// - the trailing closure, `Task {` and `Task.detached(priority: .low) {`;
    /// - the initialiser called with its closure inside the parentheses, `Task(operation: { … })`
    ///   and `Task.detached(priority: .low, operation: { … })` — neither has a `{` straight after
    ///   an argument list, and a closure holds parentheses of its own;
    /// - `Task.init`, `Task.detached`, `Task.immediate` and `Task.immediateDetached` named at all,
    ///   called or taken as a value;
    /// - any of them behind an explicit generic clause, one level of nesting deep.
    ///
    /// `Task.sleep`, `Task.isCancelled` and a `Task<Void, Never>?` annotation spawn nothing and are
    /// not matched; `MyTask {` is another name.
    static let taskSpawn =
        #"(?<![A-Za-z0-9_])Task\s*(?:<(?:[^<>]|<[^<>]*>)*>)?\s*"#
        + #"(?:\.\s*(?:detached|init|immediate|immediateDetached)(?![A-Za-z0-9_])|[({])"#

    /// A job cannot `await`, but it can spawn a `Task`, which typechecks inside one and runs after
    /// the turn has ended — a write outside any turn. No write-turn job spawns one, and every job
    /// is a closure written at its call (both b2 obligations). B1 has no job, so the tree half
    /// holds over none today; the fixtures show the scan bites.
    ///
    /// **Mutation:** make `writeTurnJobs` return nothing. Run: red here, at the fixture. The
    /// spellings of the spawn itself are `taskSpawnsAreFoundInEverySpelling`'s.
    @Test("No write-turn job spawns a Task, and every job is a closure at its call")
    func noWriteTurnJobSpawnsATask() throws {
        for file in try RuleZeroScan.files(under: "Sources") {
            for job in try Self.writeTurnJobs(in: file.code) {
                let body = try #require(
                    job, "\(file.path) hands a write turn a job that is not a closure at its call")
                #expect(
                    try RuleZeroScan.count(Self.taskSpawn, in: String(body)) == 0,
                    "\(file.path) spawns a Task inside a write turn, which escapes the turn")
            }
        }
        let fixture = """
            try await scheduler.withWriteTurn(on: channel) { channel in
                Task { try await channel.write([0x00], to: key) }
            }
            try await scheduler.withWriteTurn(on: channel) { channel in try channel.read(key) }
            try await scheduler.withWriteTurn(on: channel, { channel in
                Task.init { try await channel.write([0x00], to: key) }
            })
            try await scheduler.withWriteTurn(on: channel, restoreJob)
            """
        let jobs = try Self.writeTurnJobs(in: RuleZeroScan.code(of: fixture))
        #expect(jobs.count == 4)
        #expect(
            try jobs.map { try $0.map { try RuleZeroScan.count(Self.taskSpawn, in: String($0)) } }
                == [1, 0, 1, nil])
    }

    /// Each spelling is a whole job of its own, so the count is the scan's answer for it alone.
    /// The first group is what the pattern read before #441; the second is what it did not. The
    /// tree has no job to hold one, so these fixtures are the scan's only evidence today.
    ///
    /// **Mutations:** put the pre-#441 `taskSpawn` back, which needs a `{` after the argument
    /// list. Run: red here, at `Task(operation:`. Dropping `immediate|immediateDetached` from the
    /// new one is red at their own fixtures.
    @Test("A Task spawned inside a job is found in every spelling, and a lookalike is not")
    func taskSpawnsAreFoundInEverySpelling() throws {
        let before = [
            "Task { try await channel.write([0x00], to: key) }",
            "Task.detached { work() }", "Task.init { work() }",
            "Task<Void, Never> { work() }", "Task.detached(priority: .low) { work() }",
        ]
        let after = [
            "Task(operation: { work() })", "Task(priority: .low, operation: { work() })",
            "Task.detached(priority: .background, operation: { work(read(key)) })",
            "Task.init(operation: { work() })", "Task (operation: { work() })",
            "Task(operation: work)", "Task.detached(operation: work)",
            "Task<Void, Never>(operation: { work() })",
            "Task<[String: Array<Int>], any Error>.detached { try work() }",
            "Task<Void, Never>.init(operation: { work() })",
            "Swift.Task(operation: { work() })", "_Concurrency.Task.detached { work() }",
            "Task.immediate { work() }", "Task.immediateDetached(operation: { work() })",
            "let spawn = Task.detached", "let spawn = Task<Void, Never>.init",
            "let a = 1; Task(operation: { work() })",
        ]
        for source in before + after {
            #expect(
                try RuleZeroScan.count(Self.taskSpawn, in: RuleZeroScan.code(of: source)) == 1,
                "\(source)")
        }
        let lookalikes = [
            "try await Task.sleep(nanoseconds: 1)", "if Task.isCancelled { return }",
            "try Task.checkCancellation()", "let current: Task<Void, Never>? = nil",
            "var handle: Task<Void, Never>", "MyTask { work() }", "SubTask(operation: work)",
            "addTask { work() }", "Tasks(work)", "// Task { work() }",
            "let s = \"Task { work() }\"",
            "let priority = Task.currentPriority",
        ]
        for source in lookalikes {
            #expect(
                try RuleZeroScan.count(Self.taskSpawn, in: RuleZeroScan.code(of: source)) == 0,
                "\(source)")
        }
    }
}

/// The build settings that would open the seam to a plain-import test (#436's final review, S3):
/// `-Xfrontend -disable-access-control` makes every `private` and SPI member nameable, the
/// daemon's forwarder and entry point among them, and `-enable-private-imports` lets a
/// private import of a source file see them.
///
/// **What this checks, and no more.** Neither flag, nor `unsafeFlags`, appears as text in a root
/// `Package*.swift` (the alternate `Package@swift-<version>.swift` manifests included),
/// `project.yml`, a file under `.github/workflows/`, or a file under `scripts/`; and every target
/// the manifests declare takes its sources from `Sources/`, `Tests/` or `Tools/`, the directories
/// the other scans read. The manifest can pass a flag only through `unsafeFlags`, which is
/// refused with the other two. It does not see a flag passed from a developer's shell or an
/// environment variable, a SwiftPM toolset file, an Xcode build setting changed in the IDE or in
/// the gitignored `Configs/Signing.xcconfig`, or a target the manifests build with a constructor
/// it does not know. It catches the accident; the compiler's seam (ADR 0014's B1 seam amendment)
/// is the control.
@Suite("No build setting opens the seam to a test")
struct SeamBuildSettingTests {

    static func text(_ path: String) throws -> String {
        let url = RuleZeroScan.repositoryRoot.appendingPathComponent(path)
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// The names in the repository root: a manifest is only ever a root file.
    static func rootEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: RuleZeroScan.repositoryRoot.path)
    }

    /// Every file under `directory`, as paths from the repository root. Symbolic links are
    /// refused, so nothing the scan cannot see is read as if it were there.
    private static func files(under directory: String) throws -> [String] {
        let root = RuleZeroScan.repositoryRoot.appendingPathComponent(directory)
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]))
        let entries = enumerator.compactMap { $0 as? URL }
        SeamScanner.refuseSymbolicLinks(in: entries, under: root)
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        .map { RuleZeroScan.relativePath(of: $0) }
        .sorted()
    }

    /// **Mutations:** add `.unsafeFlags(["-Xfrontend", "-disable-access-control"])` to a test
    /// target's `swiftSettings`; copy `Package.swift` to `Package@swift-6.swift` with that line
    /// added (P02); put `-Xswiftc -enable-private-imports` on a `swift test` line in a workflow
    /// or a script. Run: red here, each.
    @Test("No manifest, project spec, workflow or script passes a flag that opens private or SPI")
    func noFlagOpensTheSeam() throws {
        let entries = try Self.rootEntries()
        let manifests = ManifestScan.manifestNames(among: entries)
        #expect(manifests.contains("Package.swift"), "the root manifest was not found")

        var read: [String] = manifests + ["project.yml"]
        for directory in [".github/workflows", "scripts"] {
            read += try Self.files(under: directory)
        }
        for path in read {
            let named = ManifestScan.flags(in: try Self.text(path))
            #expect(named.isEmpty, "\(path) names \(named)")
        }

        // Coverage, not decoration: the scan reads the workflow that legitimately passes
        // `-enable-testing`, so a green result is not a scan that read nothing.
        #expect(read.contains(".github/workflows/ci.yml"), "the CI workflow was not read")
        #expect(try Self.text(".github/workflows/ci.yml").contains("-Xswiftc -enable-testing"))
        #expect(read.contains { $0.hasPrefix("scripts/") }, "no script was read")
    }

    /// A target whose sources live outside `Sources/`, `Tests/` and `Tools/` would be code no scan
    /// here reads, whatever it imports and whatever flag it needs.
    ///
    /// **Mutations:** in `Package.swift`, give a test target `path: "Tests/../Probe"` (P04); add
    /// `.target(name: "Probe", path: "Probe")` and make a test target depend on it (P06); give a
    /// target `path: probePath` over a `let probePath = "Probe"` (P03). Run: red here, each.
    @Test("Every target in every manifest takes its sources from a directory the scans read")
    func everyTargetIsUnderAScannedRoot() throws {
        let root = RuleZeroScan.repositoryRoot
        var declared = 0
        var testTargets = 0
        for name in ManifestScan.manifestNames(among: try Self.rootEntries()) {
            for target in try ManifestScan.targets(in: try Self.text(name)) {
                declared += 1
                if target.kind == "testTarget" { testTargets += 1 }
                let problem = ManifestScan.problem(with: target) { path in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory)
                        && isDirectory.boolValue
                }
                #expect(problem == nil, "\(name): \(problem ?? "")")
            }
        }
        #expect(testTargets >= 5, "the manifests declare \(testTargets) test targets")
        #expect(declared >= 15, "the manifests declare \(declared) targets, not this package's")
    }
}
