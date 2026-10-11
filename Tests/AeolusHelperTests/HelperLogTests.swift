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

    /// `HelperLog.swift` calls its `Logger` exactly once, in `emit(_:_:)`, with the type from
    /// `osLogType(for:)`. A line written straight to `log.fault(...)` would reach the unified
    /// log at a level its sink never hears about, which is the divergence this file exists to
    /// prevent.
    ///
    /// **The scan is of any receiver, not of the name `log`.** Its first form looked for `log.`
    /// not preceded by a word character *or a dot*, so `self.log.notice(` walked past it (the
    /// delta review of #349). It now counts every `<name>.<level>(` call, whatever comes before
    /// the name, plus `os_log(` and every `Logger(` construction, so a second logger or a
    /// qualified receiver is a failure too. `HelperLogLevel.swift`, which holds the mapping,
    /// may write nothing at all.
    ///
    /// **Mutation:** in `HelperLog.panicRestoreRefused`, replace `fault(` with `log.notice(` —
    /// written straight to the `Logger`. Run: red here, and on the fault assertions in
    /// `PanicVerbMachineWideRestoreTests` and `FanctlResetCorruptedStateTests`.
    /// **Mutation:** in `HelperLog.teardownRestoreFailed`, replace `fault(` with
    /// `self.log.notice(`. Run: red here.
    /// **Mutation:** in `emit(_:_:)`, write `log.log(level: .default, …)` rather than taking the
    /// type from `osLogType(for:)` — every line demoted while the sink still reads its level.
    /// Run: red here only.
    @Test("Every HelperLog line reaches the unified log through emit")
    func everyLineTakesTheOneRoute() throws {
        let code = try Self.strippedSource("HelperLog.swift")
        let levels = try Self.matches(of: Self.loggerCall, in: code)

        #expect(
            levels == ["log.log("],
            """
            HelperLog.swift writes to a logger as \(levels), not once as log.log(level:). A \
            line written around emit(_:_:) reaches the unified log at a level no sink sees.
            """)
        #expect(code.contains("log.log(level: Self.osLogType(for: level)"))
        #expect(code.contains("sink?(level, message)"), "emit does not hand the sink its level")
        #expect(
            try Self.matches(of: #"\bLogger\s*\("#, in: code).count == 2,
            "HelperLog.swift builds a Logger other than its two initialisers' one each")
        #expect(try Self.matches(of: #"\bos_log\s*\("#, in: code).isEmpty)

        let vocabulary = try Self.strippedSource("HelperLogLevel.swift")
        #expect(
            try Self.matches(of: Self.loggerCall, in: vocabulary).isEmpty
                && Self.matches(of: #"\b(Logger|os_log)\s*\("#, in: vocabulary).isEmpty,
            "HelperLogLevel.swift writes to the unified log; only emit(_:_:) may")
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
