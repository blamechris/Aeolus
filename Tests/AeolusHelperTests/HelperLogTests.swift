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
    /// **Mutation:** in `HelperLog.panicRestoreRefused`, replace `fault(` with `log.notice(` —
    /// written straight to the `Logger`. Run: red here, and on the fault assertions in
    /// `PanicVerbMachineWideRestoreTests` and `FanctlResetCorruptedStateTests`.
    /// **Mutation:** in `emit(_:_:)`, write `log.log(level: .default, …)` rather than taking the
    /// type from `osLogType(for:)` — every line demoted while the sink still reads its level.
    /// Run: red here only.
    @Test("Every HelperLog line reaches the unified log through emit")
    func everyLineTakesTheOneRoute() throws {
        let url = try #require(
            try SeamScanner.swiftFiles().first { $0.lastPathComponent == "HelperLog.swift" })
        let code = SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
        let calls = try NSRegularExpression(pattern: #"(?<![\w.])log\s*\.\s*(\w+)\s*\("#)
            .matches(in: code, range: NSRange(code.startIndex..., in: code))
            .compactMap { Range($0.range(at: 1), in: code).map { String(code[$0]) } }

        #expect(
            calls == ["log"],
            """
            HelperLog.swift calls its Logger as \(calls), not once as log.log(level:). A line \
            written around emit(_:_:) reaches the unified log at a level no sink sees.
            """)
        #expect(code.contains("log.log(level: Self.osLogType(for: level)"))
        #expect(code.contains("sink?(level, message)"), "emit does not hand the sink its level")
    }
}
