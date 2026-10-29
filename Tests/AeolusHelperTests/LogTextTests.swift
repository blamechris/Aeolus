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

    /// The escape, spelled without `LogText`'s own code: upper-case hexadecimal, four digits
    /// at least.
    private static func expectedEscape(_ scalar: Unicode.Scalar) -> String {
        String(format: "\\u{%04X}", scalar.value)
    }

    // MARK: - The pure escaper

    /// Every scalar in Cc, Cf, Zl and Zp is written out, one at a time so a failure names the
    /// scalar; everything else comes back as it went in, a run of the code space to a string, so
    /// the sweep gives the pool back between runs (`CodeSpace`, #570).
    ///
    /// **Mutation:** make `LogText.escaped` return `text` unchanged. Run: red on `wrong.isEmpty`,
    /// listing every removed scalar; `runsChanged == 0` stays green, as nothing changes.
    /// **Mutation (#553):** in `FaultText.isRemovedFromDisplay`, delete `.lineSeparator,
    /// .paragraphSeparator`. Run: red on `wrong.isEmpty`, listing the escapes of U+2028 and
    /// U+2029 and nothing else.
    @Test("Every scalar in Cc, Cf, Zl and Zp is written out, and nothing else is touched")
    func everyRemovedScalarIsWrittenOutAndNothingElseChanges() async {
        var removed: [Unicode.Scalar] = []
        var runsChanged = 0
        await CodeSpace.forEachRun { run in
            removed += run.filter(Self.inTheFourCategories)
            var kept = String.UnicodeScalarView()
            kept.append(contentsOf: run.filter { !Self.inTheFourCategories($0) })
            let untouched = String(kept)
            if Array(LogText.escaped(untouched).unicodeScalars) != Array(untouched.unicodeScalars) {
                runsChanged += 1
            }
        }
        #expect(removed.count > 200)
        #expect(removed.contains("\u{2028}") && removed.contains("\u{2029}"))

        let wrong = removed.filter {
            LogText.escaped("a\($0)b") != "a" + Self.expectedEscape($0) + "b"
        }
        #expect(wrong.isEmpty, "not escaped as \\u{XXXX}: \(wrong.map(Self.expectedEscape))")
        #expect(runsChanged == 0, "a scalar outside Cc, Cf, Zl and Zp was changed")
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

    // MARK: - The sink that forces the escape

    /// What the sink hands its closure, and with which level.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var levels: [HelperLog.Level] = []
        private var messages: [String] = []

        func append(_ level: HelperLog.Level, _ message: String) {
            lock.withLock {
                levels.append(level)
                messages.append(message)
            }
        }

        var heard: (levels: [HelperLog.Level], messages: [String]) {
            lock.withLock { (levels, messages) }
        }
    }

    /// `EscapingSink` is what the shipping `SafetyLog()` and `HelperLog()` store, and nothing
    /// observes them: every test builds the recording initialiser. This is the one place the
    /// escape is held to the type itself, so a sink that stopped escaping is red here and not
    /// only in whichever log's rows happen to read it back.
    ///
    /// **Mutation:** in `EscapingSink.callAsFunction`, call `sink(level, message)` rather than
    /// `sink(level, LogText.escaped(message))`. Run: red on the `messages` expectation; the
    /// `levels` expectation stays green, because the level is not touched either way.
    /// **Mutation:** make `LogText.escaped` return `text` unchanged. Run: red on the same one.
    @Test("An EscapingSink hands its closure the escaped message and the level as it came")
    func theSinkEscapesBeforeItsClosureHearsTheMessage() {
        let heard = Heard()
        let sink = LogText.EscapingSink<HelperLog.Level> { heard.append($0, $1) }

        sink(.error, "FNum declares \u{2028}a\n\u{202E}b")
        sink(.fault, "nothing to escape")

        #expect(heard.heard.levels == [.error, .fault])
        #expect(
            heard.heard.messages == [
                #"FNum declares \u{2028}a\u{000A}\u{202E}b"#, "nothing to escape",
            ])
    }

    // MARK: - The shipping logs hold the sink and nothing else

    /// Every other test builds `SafetyLog(recording:)`, so the shipping `SafetyLog()` that the
    /// composition and `StartupReconciliation` default to is read back by nothing, and a
    /// conflicted merge or a tidy-up that gave it a closure of its own would leave the suite
    /// green. The stored type is the control, and this is what pins the stored type: the log's
    /// only child is an `EscapingSink`, and the sink's only child is its closure. Reflection,
    /// because the type of a private property cannot be named from a test any other way.
    ///
    /// Building the log writes nothing: its initialiser makes a `Logger` and a closure, and
    /// `Logger.init` does not log.
    ///
    /// **Mutation (T1):** in `SafetyLog.swift`, declare `emit` as `@Sendable (Level, String) ->
    /// Void`, give `init(subsystem:category:)` main's `emit = { level, message in switch … }`
    /// and `init(recording:)` an `emit` closure that calls `sink(level, LogText.escaped(message))`.
    /// Run, against the full suite: red on the `#require(… as? LogText.EscapingSink<SafetyLog
    /// .Level>)` alone, with every other test green.
    /// **Mutation:** add a second stored property to `SafetyLog`, `private let strayLogger =
    /// Logger(subsystem: "x", category: "y")`. Run: red on `children.count == 1` alone.
    /// **Mutation (E2):** give `EscapingSink` a second stored property and a factory that skips
    /// the escape, and have only the shipping `SafetyLog.init(subsystem:category:)` use it. Run:
    /// red on `Mirror(reflecting: emit).children.count == 1`, here and in the `HelperLog` test
    /// below, because the type itself grew.
    @Test("The shipping SafetyLog() stores one EscapingSink and nothing else")
    func shippingSafetyLogHoldsOnlyAnEscapingSink() throws {
        let children = Array(Mirror(reflecting: SafetyLog()).children)
        #expect(children.count == 1, "SafetyLog stores something besides its sink: \(children)")
        let emit = try #require(
            children.first?.value as? LogText.EscapingSink<SafetyLog.Level>,
            "SafetyLog's shipping initialiser does not store an EscapingSink")
        #expect(
            Mirror(reflecting: emit).children.count == 1,
            "an EscapingSink holds something besides its closure")
    }

    /// The same, for the shipping `HelperLog()`, which `AeolusHelperMain` builds and no test
    /// reads back. `HelperLogTests.everyLineTakesTheOneRoute` counts the places the *file*
    /// reaches `os_log`; this pins what the type *stores*. Neither sees an extension of
    /// `HelperLog` in another file.
    ///
    /// **Mutation (T1):** in `HelperLog.swift`, declare `emit` as `@Sendable (Level, String) ->
    /// Void` and have each initialiser assign a closure that escapes inside. Run, against the
    /// full suite: red on the `#require(… as? LogText.EscapingSink<HelperLog.Level>)` here, and
    /// on two expectations of `everyLineTakesTheOneRoute` (the declared type and the
    /// `emit = LogText.EscapingSink {` count); nothing else.
    /// **Mutation:** add `private let strayLogger = Logger(subsystem: "x", category: "y")` to
    /// `HelperLog`. Run: red on `children.count == 1` here, and on the route scan's `Logger(`
    /// count.
    /// **Mutation (E2):** as for `SafetyLog`, with only the shipping `HelperLog` initialiser using
    /// the non-escaping factory. Run: red on `Mirror(reflecting: emit).children.count == 1`, here
    /// and in the `SafetyLog` test, and on the scan's `emit = LogText.EscapingSink {` count.
    @Test("The shipping HelperLog() stores one EscapingSink and nothing else")
    func shippingHelperLogHoldsOnlyAnEscapingSink() throws {
        let children = Array(Mirror(reflecting: HelperLog()).children)
        #expect(children.count == 1, "HelperLog stores something besides its sink: \(children)")
        let emit = try #require(
            children.first?.value as? LogText.EscapingSink<HelperLog.Level>,
            "HelperLog's shipping initialiser does not store an EscapingSink")
        #expect(
            Mirror(reflecting: emit).children.count == 1,
            "an EscapingSink holds something besides its closure")
    }

    // MARK: - SafetyLog

    /// The site #553 names: `StartupReconciliation.reconcile()`'s enumeration `catch`, which
    /// puts `String(describing: error)` into `reconciliationEnumerationFailed(detail:)` at
    /// `.fault`. The real pass over a real scripted plane, with an enumeration that throws a
    /// firmware-shaped description, so the interpolation, the description and the escape are
    /// all the production ones.
    ///
    /// **Mutation:** in `LogText.EscapingSink.callAsFunction`, call `sink(level, message)`
    /// rather than `sink(level, LogText.escaped(message))`. Run: red on the `line.contains(…)`
    /// expectation and on `raw.isEmpty`; `lines.count == 1` and the `.fault` expectation stay
    /// green, because the line is still logged once, at the right level.
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
    /// **Mutation:** the `callAsFunction` one above. Run: red on both expectations, on all four
    /// rows.
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

    /// `HelperLog` holds its route as a `LogText.EscapingSink`, so a line reaches the unified log
    /// and a test's sink escaped. Lines that quote a firmware-derived `reason` or a `detail` are
    /// the ones that can carry the text.
    ///
    /// **Mutation:** the `callAsFunction` one above. Run: red on both expectations.
    ///
    /// This row reads back the *recording* `HelperLog`, so it cannot see the shipping one.
    /// What holds the shipping escape is the stored type, pinned by
    /// `shippingHelperLogHoldsOnlyAnEscapingSink`, plus `everyLineTakesTheOneRoute` for a
    /// `Logger` or `os_log` call written inline in `HelperLog.swift`. A `HelperLog` extension in
    /// another file is covered by neither.
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
