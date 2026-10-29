import Foundation
import Testing
import os

@testable import AeolusHelper

/// `HelperLog` writes every line through one route, so the level a test reads from the sink is
/// the level the unified log was given.
///
/// `Logger` writes nowhere a test can read, so "this line is a fault" was, for the lines that
/// called `log.fault(...)` beside a separately tagged sink, a claim no test could check:
/// demoting the real call left every test green (the review of #349). Now there is one call to
/// the `Logger` in the file, it takes its type from `osLogType(for:)`, and the sink is handed the
/// same level value. The two tests below hold the two halves of that.
@Suite("HelperLog writes each line once, at the level its sink is told")
struct HelperLogTests {

    /// Each level maps to the unified log's type of the same name; notice is `.default`, which
    /// is what `Logger.notice` writes.
    ///
    /// **Mutation:** in `HelperLog.osLogType(for:)`, map `.fault` to `.default`. Run: red here —
    /// and nowhere else, because the sink is told the level, not the type.
    @Test("Every level is written at the unified log's type of the same name")
    func everyLevelMapsToItsOwnType() {
        let expected: [HelperLog.Level: OSLogType] = [
            .debug: .debug, .info: .info, .notice: .default, .error: .error, .fault: .fault,
        ]
        #expect(Set(expected.keys) == Set(HelperLog.Level.allCases), "a level has no mapping")
        for level in HelperLog.Level.allCases {
            #expect(
                HelperLog.osLogType(for: level) == expected[level],
                "\(level) is written at \(HelperLog.osLogType(for: level).rawValue)")
        }
    }

    /// `HelperLog.swift` reaches the unified log in exactly two places, one in each initialiser,
    /// and each is inside the closure handed to a `LogText.EscapingSink` that `emit` stores.
    /// A line written straight to a `Logger` would reach the unified log at a level its sink never
    /// hears about, or unescaped (#553).
    ///
    /// **The type is the control; this scan claims the accidents.** `emit` is an
    /// `EscapingSink`, so a message cannot reach either closure unescaped, and no `Logger` is
    /// stored, so a method has no `log` to write to. What the scan adds is the count: a second
    /// stored logger, a qualified receiver (`self.log.notice(`), another `Logger(` or an
    /// `os_log(` each change a number below. `HelperLogLevel.swift`, which holds the mapping,
    /// may write nothing at all.
    ///
    /// **Mutation:** add `private let strayLog = Logger(subsystem: "x", category: "y")` and make
    /// `info(_:)` call `strayLog.log("\(message, privacy: .public)")`. Run: red on `levels ==
    /// ["log.log(", "log.log("]` and on the `Logger(` count; the rest stay green.
    /// **Mutation:** make `fault(_:)` call `Logger(subsystem: "x", category: "y").fault("\(message,
    /// privacy: .public)")`. Run: red on the `Logger(` count alone here (`loggerCall` needs a word
    /// character before the dot, so it does not see a call on `)`), and on `HelperLog lines that
    /// quote an error escape it too` in `LogTextTests`.
    /// **Not mutations but compile errors**, which is the point of the stored type: assigning a
    /// closure to `emit` in either initialiser, and reading a `log` from a method.
    @Test("Every HelperLog line reaches the unified log through its escaping sink")
    func everyLineTakesTheOneRoute() throws {
        let code = try Self.strippedSource("HelperLog.swift")
        let levels = try Self.matches(of: Self.loggerCall, in: code)

        #expect(
            levels == ["log.log(", "log.log("],
            """
            HelperLog.swift writes to a logger as \(levels), not once per initialiser as \
            log.log(level:) inside its EscapingSink. A line written around emit reaches the \
            unified log unescaped, or at a level no sink sees.
            """)
        #expect(
            try Self.matches(of: #"\blog\.log\(level: Self\.osLogType\(for: level\)"#, in: code)
                .count == 2, "a log.log call does not take its type from osLogType(for:)")
        #expect(code.contains("private let emit: LogText.EscapingSink<Level>"))
        #expect(
            try Self.matches(of: #"\bemit\s*=\s*LogText\.EscapingSink\s*\{"#, in: code).count == 2,
            "an initialiser does not build its emit as a LogText.EscapingSink")
        #expect(code.contains("sink(level, message)"), "emit does not hand the sink its level")
        #expect(
            try Self.matches(of: #"\bLogger\s*\("#, in: code).count == 2,
            "HelperLog.swift builds a Logger other than its two initialisers' one each")
        #expect(try Self.matches(of: #"\bos_log\s*\("#, in: code).isEmpty)

        let vocabulary = try Self.strippedSource("HelperLogLevel.swift")
        #expect(
            try Self.matches(of: Self.loggerCall, in: vocabulary).isEmpty
                && Self.matches(of: #"\b(Logger|os_log)\s*\("#, in: vocabulary).isEmpty,
            "HelperLogLevel.swift writes to the unified log; only emit may")
    }

    /// The advertising line says what the plane said about writing, in both directions.
    ///
    /// **Mutation:** in `HelperLog.listening`, return the `.notBuilt` sentence for both cases.
    /// Run: red on `.built`.
    @Test(
        "The advertising line states the write path the plane reports",
        arguments: [FanWriteCapability.notBuilt, .built])
    func theListeningLineFollowsTheCapability(_ capability: FanWriteCapability) {
        let lines = RecordedHelperLines()
        HelperLog(
            subsystem: "dev.aeolus.AeolusHelperTests", category: "Listening",
            recording: { lines.append($0, $1) }
        ).listening(machServiceName: "test.service", build: "test", writeCapability: capability)

        let none = lines.levels(containing: "No SMC write path exists in this build.")
        let some = lines.levels(containing: "This build has an SMC write path.")
        #expect(none == (capability == .notBuilt ? [.notice] : []), "the no-write-path line")
        #expect(some == (capability == .built ? [.notice] : []), "the write-path line")
    }

    /// And the one call site asks the plane, rather than passing a literal: `main` cannot be run
    /// under test, so this is a source check of `AeolusHelperMain.bringUp`.
    ///
    /// **Mutation:** in `AeolusHelperMain.bringUp`, pass `writeCapability: .notBuilt`. Run: red.
    @Test("The daemon's advertising line asks the plane what it can write")
    func theDaemonAsksThePlaneWhenItAdvertises() throws {
        let code = HelperCompositionTests.strippingWhitespace(
            try Self.strippedSource("AeolusHelperMain.swift"))
        #expect(
            code.contains("writeCapability:helper.plane.writeCapability)"),
            "AeolusHelperMain.bringUp does not take the listening line's capability from the plane")
    }

    /// A call of a logging method on any receiver, qualified or not: `log.fault(`,
    /// `self.log.notice(`, `other.log(`.
    private static let loggerCall =
        #"\b\w+\s*\.\s*(fault|error|notice|debug|info|log|trace|warning|critical)\s*\("#

    private static func strippedSource(_ file: String) throws -> String {
        let url = try #require(
            try SeamScanner.swiftFiles().first { $0.lastPathComponent == file },
            "\(file) is not in the source tree")
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    private static func matches(of pattern: String, in code: String) throws -> [String] {
        try NSRegularExpression(pattern: pattern)
            .matches(in: code, range: NSRange(code.startIndex..., in: code))
            .compactMap { Range($0.range, in: code).map { String(code[$0]) } }
    }
}
