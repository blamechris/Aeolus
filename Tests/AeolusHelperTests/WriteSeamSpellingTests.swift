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

    /// Every job body handed to `withWriteTurn(on:…)` under `code`: the closure after the call's
    /// parenthesis, trailing or as the last argument.
    static func writeTurnJobs(in code: String) throws -> [Substring] {
        let call = try NSRegularExpression(pattern: #"(?<!func\s)withWriteTurn\s*\("#)
        var jobs: [Substring] = []
        for match in call.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let found = Range(match.range, in: code),
                let open = code[found.lowerBound...].firstIndex(of: "{")
            else { continue }
            jobs.append(RuleZeroScan.balanced(in: code, from: open))
        }
        return jobs
    }

    /// A job cannot `await`, but it can spawn a `Task`, which typechecks inside one and runs after
    /// the turn has ended — a write outside any turn. No write-turn job spawns one (a b2
    /// obligation). B1 has no job, so the tree half holds over none today; the fixtures show the
    /// scan bites.
    ///
    /// **Mutation:** make `writeTurnJobs` return nothing. Run: red here, at the fixture.
    @Test("No write-turn job spawns a Task")
    func noWriteTurnJobSpawnsATask() throws {
        for file in try RuleZeroScan.files(under: "Sources") {
            for job in try Self.writeTurnJobs(in: file.code) {
                #expect(
                    try SeamScanner.unstructuredTaskSpawns(inSource: String(job)) == 0,
                    "\(file.path) spawns a Task inside a write turn, which escapes the turn")
            }
        }
        let fixture = """
            try await scheduler.withWriteTurn(on: channel) { channel in
                Task { try await channel.write([0x00], to: key) }
            }
            try await scheduler.withWriteTurn(on: channel) { channel in try channel.read(key) }
            """
        let jobs = try Self.writeTurnJobs(in: RuleZeroScan.code(of: fixture))
        #expect(jobs.count == 2)
        #expect(
            try jobs.map { try SeamScanner.unstructuredTaskSpawns(inSource: String($0)) } == [1, 0])
    }
}
