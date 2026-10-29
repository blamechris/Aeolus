import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// A helper log line keeps the firmware's text as evidence and escapes the characters that
/// would break or hide the line around it (#553).
///
/// The decision, so a later reader does not reverse it: a log is **evidence**, so it is
/// escaped (`\u{2028}`), not stripped. A UI label or `fanctl`'s stderr line exists to be read
/// and drops what it cannot show (`FaultText.displayable`); an operator running `log show`
/// after a firmware surprise needs to see that the type code was `U+2028` followed by `a`.
@Suite("LogText — a log line escapes what would break it and keeps the rest")
struct LogTextTests {

    /// The oracle is the Unicode general category, not `FaultText`'s predicate, which is what
    /// `LogText` is held to.
    private static func inTheFourCategories(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    private static let allScalars: [Unicode.Scalar] = (0...0x10FFFF).compactMap {
        Unicode.Scalar($0)
    }

    /// The escape, spelled without `LogText`'s own code: upper-case hexadecimal, four digits
    /// at least.
    private static func expectedEscape(_ scalar: Unicode.Scalar) -> String {
        String(format: "\\u{%04X}", scalar.value)
    }

    // MARK: - The pure escaper

    /// Every scalar in Cc, Cf, Zl and Zp is written out, one at a time so a failure names the
    /// scalar; everything else comes back as it went in, in one string so the run is cheap.
    ///
    /// **Mutation:** make `LogText.escaped` return `text` unchanged. Run: red on the first
    /// expectation, for all of them.
    /// **Mutation (#553):** in `FaultText.isRemovedFromDisplay`, delete `.lineSeparator,
    /// .paragraphSeparator`. Run: red, naming U+2028 and U+2029.
    @Test("Every scalar in Cc, Cf, Zl and Zp is written out, and nothing else is touched")
    func everyRemovedScalarIsWrittenOutAndNothingElseChanges() {
        let removed = Self.allScalars.filter(Self.inTheFourCategories)
        #expect(removed.count > 200)
        #expect(removed.contains("\u{2028}") && removed.contains("\u{2029}"))

        let wrong = removed.filter {
            LogText.escaped("a\($0)b") != "a" + Self.expectedEscape($0) + "b"
        }
        #expect(wrong.isEmpty, "not escaped as \\u{XXXX}: \(wrong.map(Self.expectedEscape))")

        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: Self.allScalars.filter { !Self.inTheFourCategories($0) })
        let untouched = String(kept)
        #expect(
            Array(LogText.escaped(untouched).unicodeScalars) == Array(untouched.unicodeScalars),
            "a scalar outside Cc, Cf, Zl and Zp was changed")
    }

    @Test("The escapes read as the scalar's own number, padded to four digits")
    func theEscapesAreReadable() {
        #expect(LogText.escaped("a\u{2028}b") == #"a\u{2028}b"#)
        #expect(LogText.escaped("a\u{2029}b") == #"a\u{2029}b"#)
        #expect(LogText.escaped("a\nb") == #"a\u{000A}b"#)
        #expect(LogText.escaped("a\u{202E}b") == #"a\u{202E}b"#)
        #expect(LogText.escaped("a\u{E0001}b") == #"a\u{E0001}b"#, "a five-digit scalar")
    }

    @Test("Text with nothing to escape is returned as it is, backslashes included")
    func plainTextIsUntouched() {
        for text in ["", "FNum declares flt", #"C:\path\u{2028} already written"#, "é ✓ 温度"] {
            #expect(LogText.escaped(text) == text)
        }
    }

    /// `emit` applies it to a message a caller may already have escaped.
    @Test("Escaping twice is escaping once")
    func escapingIsIdempotent() {
        let once = LogText.escaped("a\u{2028}b\nc\u{202E}")
        #expect(LogText.escaped(once) == once)
    }

    // MARK: - SafetyLog

    /// The site #553 names: `StartupReconciliation.reconcile()`'s enumeration `catch`, which
    /// puts `String(describing: error)` into `reconciliationEnumerationFailed(detail:)` at
    /// `.fault`. The real pass over a real scripted plane, with an enumeration that throws a
    /// firmware-shaped description, so the interpolation, the description and the escape are
    /// all the production ones.
    ///
    /// **Mutation:** in `SafetyLog.init(escapingInto:)`, assign
    /// `emit = { level, message in sink(level, message) }`. Run: red on the first two
    /// expectations.
    @Test("Startup reconciliation's enumeration failure logs the firmware's text, escaped")
    func theEnumerationFailureLineEscapesTheDetail() async throws {
        let recorded = RecordedLog()
        let plane = ScriptedControlPlane(
            fans: [0: .held(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let reconciliation = LeaseFixture.reconciliation(
            over: plane,
            enumeration: ScriptedFanEnumeration(
                failure: FakeProviderError(
                    description: "read FNum: FNum declares \u{2028}a\n[forged] \u{202E}fault")),
            clock: TestClock(),
            log: SafetyLog(recording: { recorded.append($0, $1) }))

        await reconciliation.reconcile()

        let lines = recorded.lines(containing: "could not enumerate this machine's fans")
        let line = try #require(lines.first, "the enumeration failure was not logged")
        #expect(lines.count == 1)
        #expect(
            line.contains(#"FNum declares \u{2028}a\u{000A}[forged] \u{202E}fault"#),
            "the firmware's text is not in the line, escaped: \(line)")
        #expect(recorded.faults.contains(line), "the enumeration failure is not at .fault")
        let raw = recorded.lines.filter {
            $0.unicodeScalars.contains(where: Self.inTheFourCategories)
        }
        #expect(raw.isEmpty, "a raw line break or bidirectional control reached the log")
    }

    /// The funnel, not the one site: lines that interpolate an error elsewhere in `SafetyLog`
    /// reach the log through the same `emit`.
    ///
    /// **Mutation:** as above. Run: red on every row.
    @Test("Other SafetyLog lines that quote an error escape it too")
    func otherSafetyLinesEscapeToo() {
        let recorded = RecordedLog()
        let log = SafetyLog(recording: { recorded.append($0, $1) })
        let hostile = "type \u{2028}a\u{2029}b"

        log.reconciliationReadFailed(fanAt: 0, detail: hostile, unreconciled: [0])
        log.emergencyWriteFailed(verb: "restore", fan: 0, detail: hostile)
        log.reclamationWriteFailed(verb: "re-assert", fan: 0, detail: hostile)
        log.thermalEmergencyCycleUnreadable(detail: hostile)

        #expect(recorded.lines.count == 4)
        for line in recorded.lines {
            #expect(line.contains(#"type \u{2028}a\u{2029}b"#), "not escaped: \(line)")
            #expect(!line.unicodeScalars.contains(where: Self.inTheFourCategories))
        }
    }

    // MARK: - HelperLog

    /// `HelperLog.emit` escapes before the unified log and the sink both. Lines that quote a
    /// firmware-derived `reason` or a `detail` are the ones that can carry the text.
    ///
    /// **Mutation:** in `HelperLog.emit`, delete `let message = LogText.escaped(message)`.
    /// Run: red on every row.
    @Test("HelperLog lines that quote an error escape it too")
    func helperLogLinesEscapeTheirQuotedText() {
        let lines = RecordedHelperLines()
        let log = HelperLog(
            subsystem: "dev.aeolus.AeolusHelperTests", category: "LogText",
            recording: { lines.append($0, $1) })
        let hostile = "FNum declares \u{2028}a\nforged \u{202E}line"
        let escaped = #"FNum declares \u{2028}a\u{000A}forged \u{202E}line"#

        log.sensorDiscoveryFailed(reason: hostile)
        log.sensorRefreshFailed(reason: hostile)
        log.teardownRestoreFailed(detail: hostile)
        log.panicRestoreRefused(connection: ConnectionID(), detail: hostile)

        #expect(lines.levels(containing: escaped).count == 4, "a quoted error was not escaped")
        for scalar in ["\u{2028}", "\n", "\u{202E}"] {
            #expect(
                lines.levels(containing: scalar).isEmpty,
                "U+\(String(scalar.unicodeScalars.first?.value ?? 0, radix: 16)) reached a line")
        }
    }
}
