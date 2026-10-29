import Foundation
import Testing

/// What holds a helper log line to its escaping sink, beyond the stored type (#560).
///
/// **The stored type is the control; every scan here is lexical.** `SafetyLog`, `HelperLog` and
/// `LeaseLog` each hold their way to the unified log as a `LogText.EscapingSink`, a type whose
/// one operation escapes the message, and `LogTextTests` pins that stored type by reflection.
/// That makes an initialiser that assigns a closure of its own a compile error. It cannot
/// stop a method that reaches the unified log without going through the sink, and these scans
/// are what notice one.
///
/// A lexical scan never converges. It counts the spellings it was written for, so it catches
/// an accident (a line written in the wrong place, in the wrong file) and not a determined
/// edit: there is always another spelling, and whoever writes it can edit the expectation as
/// easily as the code. Each test below says what it counts and what it does not see, and
/// claims no more. All of them **fail closed**: a file they expect and cannot read throws, and
/// a count they expect to be positive is positive, so an empty read is red and not a pass.
@Suite("A helper log line reaches the unified log through its escaping sink, in every file")
struct LogRouteTests {

    /// `SafetyLog.swift` reaches the unified log in exactly one place, the closure its shipping
    /// initialiser hands to `emit`, and nowhere else.
    ///
    /// What it counts, in comment-stripped source: the `Logger` type (one, in that
    /// initialiser), `os_log` (none), a call of a logging method on a receiver (two, the
    /// `notice` and the `fault` of that closure), the assignments to `emit` (two, one per
    /// initialiser), and that the closure logs the message as `.public`. A method that builds
    /// its own `Logger`, calls `os_log`, or logs through a second stored one changes a number.
    ///
    /// What it does not see: a spelling outside those three (`NSLog`, `OSLog`'s own
    /// initialiser, another log type's method), and an edit that changes a count and its
    /// expectation together. `Logger` is matched as a token, so `os.Logger`, a typealias and
    /// an annotation are seen. This is the file that, until #560, no test read as source: an
    /// in-file `SafetyLog` method that logged directly was caught only by a recording test of
    /// that particular line.
    ///
    /// **Mutation (S1):** in `SafetyLog.degradedCycle`, add `Logger(subsystem: "x", category:
    /// "y").fault("\(provenance, privacy: .public)")`. Run, against the full suite: red on the
    /// `routes(in:) ==` expectation alone.
    /// **Mutation (S2):** add `os_log("\(provenance, privacy: .public)")` there instead. Run: red
    /// on `routes(in:) ==` and on the `os_log … isEmpty` expectation; nothing else.
    /// **Mutation (S3):** add `private let strayLogger = Logger(subsystem: "x", category: "y")`
    /// and have `degradedCycle` call `strayLogger.fault(…)`. Run: red on `routes(in:) ==` here
    /// and on `children.count == 1` in `LogTextTests`' shipping-`SafetyLog` test; nothing else.
    /// **Not a mutation but a compile error**, which is the point of the stored type: an
    /// initialiser that assigns a bare closure to `emit` (#557's R3).
    @Test("Every SafetyLog line reaches the unified log through its escaping sink")
    func safetyLogTakesTheOneRoute() throws {
        let code = try LogSource.stripped("Safety/SafetyLog.swift")

        #expect(
            try LogSource.routes(in: code) == ["Logger", "logger.notice(", "logger.fault("],
            """
            SafetyLog.swift reaches the unified log by something other than the one Logger its \
            shipping initialiser builds and the notice/fault closure it hands to emit. A line \
            written around emit reaches the unified log unescaped, or at a level no sink sees.
            """)
        #expect(try LogSource.matches(of: #"\bos_log\b"#, in: code).isEmpty)
        #expect(code.contains("private let emit: LogText.EscapingSink<Level>"))
        #expect(
            try LogSource.matches(of: #"\bemit\s*=\s*LogText\.EscapingSink\s*\{"#, in: code).count
                == 1,
            "the shipping initialiser does not build its emit as a LogText.EscapingSink { … }")
        #expect(
            try LogSource.matches(of: #"\bemit\s*=\s*LogText\.EscapingSink\(sink\)"#, in: code)
                .count == 1,
            "the recording initialiser does not build its emit as LogText.EscapingSink(sink)")
        #expect(
            try LogSource.matches(of: #"\bemit\s*="#, in: code).count == 2,
            "emit is assigned other than by the two initialisers, once each")
        #expect(
            try LogSource.matches(
                of: #"\blogger\.(notice|fault)\("# + LogSource.publicMessage + #"\)"#, in: code
            ).count == 2, "a logger call does not log the sink's message as .public")
    }

    /// `LeaseLog.swift` reaches the unified log in exactly two places, one in each initialiser,
    /// each inside the closure handed to a `LogText.EscapingSink` that `emit` stores. The same
    /// shape as `HelperLog.swift`, which it was restructured to match (#560).
    ///
    /// What it counts, in comment-stripped source: the `Logger` type (two, one per
    /// initialiser), `os_log` (none), a call of a logging method on a receiver (two, each
    /// `logger.log(level:)`), that each takes its type from `osLogType(for:)` and logs the
    /// message `.public`, and the assignments to `emit` (two). The old `log.<level>(` calls
    /// have no `log` left to be written against, which is a compile error and not a count.
    ///
    /// What it does not see: as for `safetyLogTakesTheOneRoute`.
    ///
    /// **Mutation (L1):** in `LeaseLog.supervisorStopped`, add `Logger(subsystem: "x", category:
    /// "y").fault("\(leasesOutstanding, privacy: .public)")` before its `emit`. Run, against the
    /// full suite: red on the `routes(in:) ==` expectation alone.
    /// **Mutation (L2):** add `os_log("\(leasesOutstanding, privacy: .public)")` there instead.
    /// Run: red on `routes(in:) ==` and on `os_log … isEmpty`; nothing else.
    /// **Mutation (L3):** add `private let strayLogger = Logger(subsystem: "x", category: "y")`
    /// and have `supervisorStopped` call `strayLogger.fault(…)`. Run: red on `routes(in:) ==`
    /// here and on `children.count == 1` in `LogTextTests`' shipping-`LeaseLog` test; nothing
    /// else.
    /// **Mutation (L5):** in `init(recording:)`'s closure, log the message `privacy: .private`.
    /// Run: red on the `osLogType(for:)` and `.public` count alone.
    /// **Mutation (T1):** declare `emit` as `@Sendable (Level, String) -> Void` and have each
    /// initialiser assign a closure that escapes inside. Run, against the full suite: red on
    /// the `#require(… as? LogText.EscapingSink<LeaseLog.Level>)` in `LogTextTests`, and on
    /// four expectations here (the `osLogType(for:)` and `.public` count, the declared type, the
    /// `emit = LogText.EscapingSink {` count, `sink(level, message)`); nothing else.
    /// **Not a mutation but a compile error:** assigning a bare closure to `emit` in
    /// `init(recording:)` is `cannot assign value of type '(_, _) -> ()' to type
    /// 'LogText.EscapingSink<LeaseLog.Level>'`.
    @Test("Every LeaseLog line reaches the unified log through its escaping sink")
    func leaseLogTakesTheOneRoute() throws {
        let code = try LogSource.stripped("Lease/LeaseLog.swift")

        #expect(
            try LogSource.routes(in: code)
                == ["Logger", "logger.log(", "Logger", "logger.log("],
            """
            LeaseLog.swift reaches the unified log by something other than one Logger and one \
            logger.log(level:) inside the EscapingSink of each initialiser. A line written \
            around emit reaches the unified log unescaped, or at a level no sink sees.
            """)
        #expect(try LogSource.matches(of: #"\bos_log\b"#, in: code).isEmpty)
        let typed = #"\blogger\.log\(level: Self\.osLogType\(for: level\), "#
        #expect(
            try LogSource.matches(of: typed + LogSource.publicMessage + #"\)"#, in: code).count
                == 2,
            "a logger call does not take its type from osLogType(for:) and log the message .public")
        #expect(code.contains("private let emit: LogText.EscapingSink<Level>"))
        #expect(
            try LogSource.matches(of: #"\bemit\s*=\s*LogText\.EscapingSink\s*\{"#, in: code).count
                == 2,
            "an initialiser does not build its emit as a LogText.EscapingSink")
        #expect(
            try LogSource.matches(of: #"\bemit\s*="#, in: code).count == 2,
            "emit is assigned other than by the two initialisers, once each")
        #expect(code.contains("sink(level, message)"), "emit does not hand the sink its level")
    }

    /// A file that is not a log's own, but declares an `extension` of `HelperLog`, `SafetyLog`
    /// or `LeaseLog`, reaches the unified log by no route at all (#560).
    ///
    /// The extension is where a line goes when its own file is full: `HelperLog.swift` sits at
    /// the `file_length` limit, and the reviewer of #557 added a `HelperLogProbe.swift` whose
    /// `extension HelperLog` method built a `Logger` and logged to it, with the full suite
    /// green. The reflection tests see stored properties and not a method's locals, and each
    /// log's in-file scan reads that log's own file only.
    ///
    /// What it counts, in the comment-stripped source of every file under `Sources/AeolusHelper`
    /// that declares one of those three types other than its home: the `Logger` type, `os_log`,
    /// and a logging-method call on any receiver, as in the in-file scans. Zero of each.
    ///
    /// What it does not see: a file that extends nothing and builds a `Logger` of its own
    /// (`WatchdogLog.swift` is one, for good reason: it is a different log with a different
    /// vocabulary); an extension spelled so the declaration pattern misses it
    /// (`extension AeolusHelper.HelperLog`); a call through another log type's method; and every
    /// spelling the in-file scans do not see.
    ///
    /// It reads the home files by their relative path, so a probe that is *named*
    /// `HelperLog.swift` in another directory is still scanned. It also requires that the scan
    /// found each log's home, so a rename that moved a home out from under it is red and not a
    /// scan of nothing.
    ///
    /// **Mutation (X1):** add `Sources/AeolusHelper/HelperLogProbe.swift`, the reviewer's of
    /// #557: `extension HelperLog { func sensorProbeFailed(reason:) { Logger(subsystem: …,
    /// category: …).error("…\(reason, privacy: .public)") } }`. Run, against the full suite:
    /// red on `reaching.isEmpty` alone, 16 issues where the baseline has 15 known ones.
    /// **Mutation (X2):** `Sources/AeolusHelper/Safety/SafetyLogProbe.swift`, an `extension
    /// SafetyLog` method that calls `os_log`. Run: red on `reaching.isEmpty` alone.
    /// **Mutation (X3):** `Sources/AeolusHelper/Lease/LeaseLogProbe.swift`, an `extension
    /// LeaseLog` method that builds a `Logger`. Run: red on `reaching.isEmpty` alone.
    /// **Control (X4):** `Sources/AeolusHelper/Lease/LeaseLogProbe.swift` declaring `struct
    /// StrayLog { let logger = Logger(…) }`, which extends no log. Run: green, as the doc above
    /// says it is not this test's to judge.
    @Test("No file but a log's own extends it and reaches the unified log")
    func noOtherFileExtendsALogAndWritesToTheUnifiedLog() throws {
        let homes = [
            "HelperLog": "HelperLog.swift",
            "SafetyLog": "Safety/SafetyLog.swift",
            "LeaseLog": "Lease/LeaseLog.swift",
        ]
        let files = try LogSource.helperFiles()
        #expect(files.count > 50, "the scan found too few helper files: \(files.count)")

        var declaredIn: [String: Set<String>] = [:]
        var reaching: [String: [String]] = [:]
        for (path, code) in files {
            for log in try LogSource.logsDeclared(in: code) {
                declaredIn[log, default: []].insert(path)
            }
            let routes = try LogSource.routesOfAnExtension(in: code)
            if !homes.values.contains(path), !routes.isEmpty { reaching[path] = routes }
        }

        for (log, home) in homes {
            #expect(
                declaredIn[log]?.contains(home) == true,
                "\(home) does not declare \(log): the scan is not reading the log's home")
        }
        #expect(
            reaching.isEmpty,
            """
            \(reaching) extends a log and reaches the unified log itself. Its lines would skip the \
            log's EscapingSink, so a firmware- or client-derived string in one could carry a line \
            break or a bidirectional control. Write the line in the log's own file.
            """)
    }

    /// `EscapingSink` is defined by exactly the text that was reviewed: one stored closure, one
    /// initialiser that stores it as given, and a `callAsFunction` that is `sink(level,
    /// LogText.escaped(message))`. #557's round-3 delta review ran an edit that kept the type's
    /// shape and defeated it: `init(_:)` pre-wraps the escape, `callAsFunction` stops escaping,
    /// and a new factory stores a closure unwrapped for the shipping `SafetyLog` alone. The
    /// reflection tests still saw one child, the recording tests still escaped, and all 1,575
    /// `AeolusHelperTests` passed (#560).
    ///
    /// What it compares: the body of `struct EscapingSink`, in `LogText.swift` with comments and
    /// every whitespace character removed, against the text above. An extra initialiser, a
    /// second stored property, a factory, a changed `callAsFunction` or a changed access level
    /// each make it unequal, which is every step of that edit.
    ///
    /// What it does not do: prove that the sink escapes. `theSinkEscapesBeforeItsClosureHears
    /// TheMessage` does, by running it. This is a change detector on the definition, so an
    /// intended edit to `EscapingSink` is a two-file edit that a reviewer reads, which is the
    /// point; it is the only thing that reads the type's source. It does not see `LogText
    /// .escaped`, which the sweep in `LogTextTests` holds, or another type written beside
    /// `EscapingSink` that a log stores instead, which the reflection tests refuse.
    ///
    /// **Mutation (E1):** #560's comment verbatim. `init(_:)` stores `{ level, message in
    /// sink(level, LogText.escaped(message)) }`, `callAsFunction` calls `sink(level, message)`,
    /// a private second initialiser and a `static func raw(_:)` store a closure unwrapped, and
    /// only the shipping `SafetyLog.init(subsystem:category:)` is switched to `.raw { … }`. Run,
    /// against the full suite: red here on `body == reviewed`, and on the `emit =
    /// LogText.EscapingSink {` count in `safetyLogTakesTheOneRoute`, which sees the `.raw`
    /// spelling; nothing else. With this test skipped (`--skip`) the second one remains, alone,
    /// so that spelling of the edit is seen twice. A bypass that left the shipping call site
    /// byte-identical would be seen only here.
    /// **Mutation (E2):** give `EscapingSink` a second initialiser and call it from nowhere.
    /// Run: red here alone.
    /// **Mutation (E4):** drop `private` from the stored closure. Run: red here alone.
    /// **Mutation (A):** `callAsFunction` calls `sink(level, message)`. Run: red here, and on the
    /// behavioural rows `LogTextTests` holds.
    @Test("EscapingSink is the text that was reviewed: one initialiser, and it escapes")
    func theEscapingSinkIsTheTextThatWasReviewed() throws {
        let code = try LogSource.stripped("LogText.swift")
        let body = try #require(
            try LogSource.compactBody(of: #"\bstruct\s+EscapingSink\b"#, in: code),
            "LogText.swift does not declare struct EscapingSink")
        let reviewed =
            "privateletsink:@Sendable(Level,String)->Void"
            + "init(_sink:@escaping@Sendable(Level,String)->Void){self.sink=sink}"
            + "funccallAsFunction(_level:Level,_message:String)"
            + "{sink(level,LogText.escaped(message))}"

        #expect(
            body == reviewed,
            """
            EscapingSink is no longer the reviewed text. It must keep one stored closure, exactly \
            one initialiser that stores it as given, and a callAsFunction that hands the closure \
            LogText.escaped(message). Found (whitespace removed): \(body)
            """)
    }

    /// The detector behind the three scans above, held to fixtures: a scan tested only through
    /// the tree it reads is tested only for the shapes already written, and the tree today has
    /// no file that fails the test above.
    ///
    /// **Mutation (D1):** in `LogSource.route`, drop `\bLogger\b|`. Run, against the full suite:
    /// red on the first fixture, `routesOfAnExtension(in: probe) == ["Logger"]`, and on the
    /// `routes(in:) ==` expectation of both in-file scans, which read the same pattern; the
    /// `os_log` and qualified-call fixtures stay green, because those spellings are still seen.
    @Test("The detector sees an extension that builds a Logger, calls os_log, or logs through one")
    func theDetectorSeesTheShapesItIsAskedAbout() throws {
        let probe = """
            extension HelperLog {
                func sensorProbeFailed(reason: String) {
                    Logger(subsystem: "x", category: "y").error("\\(reason, privacy: .public)")
                }
            }
            """
        let osLog = #"extension SafetyLog { func f(_ d: String) { os_log("\(d)") } }"#
        let qualified = #"extension LeaseLog { func f() { self.stray.notice("x") } }"#
        let clean = "extension LeaseLog { func f() -> Int { 1 + 1 } }"
        let unrelated = #"struct WatchdogLog { let l = Logger(subsystem: "x", category: "y") }"#

        #expect(try LogSource.routesOfAnExtension(in: probe) == ["Logger"])
        #expect(try LogSource.routesOfAnExtension(in: osLog) == ["os_log"])
        #expect(try LogSource.routesOfAnExtension(in: qualified) == ["stray.notice("])
        #expect(try LogSource.routesOfAnExtension(in: clean).isEmpty)
        #expect(
            try LogSource.routesOfAnExtension(in: unrelated).isEmpty,
            "a file that extends no log is not this scan's to judge")
        #expect(try LogSource.logsDeclared(in: probe) == ["HelperLog"])
        #expect(try LogSource.logsDeclared(in: unrelated).isEmpty)
    }
}
