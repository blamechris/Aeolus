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

    /// `Task {`, `Task.detached {` and `Task.init {`, with any generic clause or argument list.
    static let taskSpawn =
        #"(?<![A-Za-z0-9_])Task\s*(?:\.\s*(?:detached|init))?\s*(?:<[^<>]*>)?"#
        + #"\s*(?:\([^()]*\))?\s*\{"#

    /// A job cannot `await`, but it can spawn a `Task`, which typechecks inside one and runs after
    /// the turn has ended — a write outside any turn. No write-turn job spawns one, and every job
    /// is a closure written at its call (both b2 obligations). B1 has no job, so the tree half
    /// holds over none today; the fixtures show the scan bites.
    ///
    /// **Mutation:** make `writeTurnJobs` return nothing. Run: red here, at the fixture.
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
}

/// The build settings that would open the seam to a plain-import test (#436's final review, S3):
/// `-Xfrontend -disable-access-control` makes every `private` and SPI member nameable, the
/// daemon's forwarder and entry point among them, and `-enable-private-imports` lets a
/// private import of a source file see them. Neither is passed anywhere, and nothing can pass one
/// through the manifest without `unsafeFlags`, which is refused too.
@Suite("No build setting opens the seam to a test")
struct SeamBuildSettingTests {

    static let openingFlags = ["unsafeFlags", "-disable-access-control", "-enable-private-imports"]

    private static func text(_ file: String) throws -> String {
        try String(
            contentsOf: RuleZeroScan.repositoryRoot.appendingPathComponent(file), encoding: .utf8)
    }

    /// **Mutation:** add `.unsafeFlags(["-Xfrontend", "-disable-access-control"])` to a test
    /// target's `swiftSettings`. Run: red here.
    @Test("Package.swift and project.yml pass no flag that opens private or SPI members")
    func noFlagOpensTheSeam() throws {
        for file in ["Package.swift", "project.yml"] {
            let text = try Self.text(file)
            for flag in Self.openingFlags {
                #expect(!text.contains(flag), "\(file) names \(flag)")
            }
        }
    }

    /// The `path:` of every `.testTarget` in `manifest` that names one; a target that names none
    /// takes `Tests/<name>`.
    static func testTargetPaths(in manifest: String) throws -> (targets: Int, paths: [String]) {
        let target = try NSRegularExpression(pattern: #"\.testTarget\s*\("#)
        var targets = 0
        var paths: [String] = []
        let range = NSRange(manifest.startIndex..., in: manifest)
        for match in target.matches(in: manifest, range: range) {
            guard let found = Range(match.range, in: manifest) else { continue }
            let body = RuleZeroScan.balanced(
                in: manifest, from: manifest.index(before: found.upperBound))
            targets += 1
            guard let path = body.range(of: #"path\s*:\s*"[^"]*""#, options: .regularExpression)
            else { continue }
            paths.append(String(body[path].drop { $0 != "\"" }.dropFirst().dropLast()))
        }
        return (targets, paths)
    }

    /// A test target whose sources live outside `Tests/` would be a test no scan here reads.
    @Test("Every test target's sources are under Tests")
    func everyTestTargetIsUnderTests() throws {
        let (targets, paths) = try Self.testTargetPaths(in: try Self.text("Package.swift"))
        for path in paths {
            #expect(path.hasPrefix("Tests/"), "a test target's sources are at \(path)")
        }
        #expect(targets >= 5, "the manifest declares \(targets) test targets, not this package's")
    }

    /// **Mutation:** in `testTargetPaths`, skip a target's `path:`. Run: red here.
    @Test("A test target's path is read, and one outside Tests is seen")
    func testTargetPathsAreRead() throws {
        let manifest = """
            .testTarget(name: "A", dependencies: ["X"]),
            .testTarget(name: "B", dependencies: [], path: "Sources/Probe"),
            .target(name: "C", path: "Sources/C"),
            """
        let (targets, paths) = try Self.testTargetPaths(in: manifest)
        #expect(targets == 2)
        #expect(paths == ["Sources/Probe"])
    }
}
