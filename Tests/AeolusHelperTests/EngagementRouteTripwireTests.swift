import Foundation
import Testing

/// [#343](https://github.com/blamechris/Aeolus/issues/343): the engagement driver is the only
/// route to a writer's `engageManualControl(of:)`, and no spelling of a use gets around the
/// scan that says so.
///
/// ## What rests on it
///
/// ADR 0009's #343 amendment declines a watcher of its own for a fan whose lease-end handback the
/// firmware refused, because § 3's registry still holds it and four mechanisms act on it from
/// there. That holds for **every** fan Aeolus engages only while the driver is the one caller of
/// the step verb: the driver tells § 3 about a fan before a hand-back of it can be refused, and a
/// second route to the verb would engage fans § 3 never heard of. ADR 0014's A6 contract, item 1,
/// is the rule; this is the test that holds it.
///
/// ## What is new here, and what is not
///
/// `EngagementDriverTests.onlyTheDriverEngages` already pins *who* uses the verb, as a set of
/// `file: receiver` pairs read by `SeamScanner.receivers(of:inSource:)`: the driver through its
/// `writer`, the watchdog through its `driver`, and `SafetyActorWriter`'s one-line forward
/// through its `plane`. A receiver scan reads a word and a `.`, which leaves three ways to reach
/// the verb that it cannot attribute, and a fourth that lets it attribute the wrong word:
///
/// - **A receiver that is not a word**: a call result, `makeWriter().engageManualControl(of:)`,
///   or a subscript, `writers[0].engageManualControl(of:)`.
/// - **No receiver**: a bare `engageManualControl(of:)` inside an extension of a type that
///   declares it.
/// - **A trailing comment between the receiver and the dot**: `writer  // driver` above
///   `.engageManualControl(of:)` read as the receiver `driver`, the one name the watchdog is
///   allowed.
/// - **The allowed name bound to something else**: `let driver = writer`.
///
/// The first two are caught by comparing `SeamScanner.mentions(of:inSource:)` with the receivers
/// the scan attributed, the third by `SeamScanner.strippingAllComments(_:)`, and the fourth by
/// reading how the watchdog's `driver` is bound.
@Suite("The route to a writer's step verb")
struct EngagementRouteTripwireTests {

    private static let verb = "engageManualControl"
    /// The two files that engage through a driver: § 5's and level 6's (ADR 0014's A6 PR-2
    /// amendment). Each may use the verb only through a `driver` bound to
    /// `engagement.under(lease:)`.
    private static let engagingFiles = ["ReclamationWatchdog.swift", "LeaseApplier.swift"]

    // MARK: - No use escapes

    /// Every use of the verb in `Sources/AeolusHelper` is one the receiver scan attributes.
    ///
    /// The count of attributed uses is a floor set at what the tree holds — three in the driver,
    /// one in the watchdog, one in level 6's `apply`, one in the writer's forward — so a scan that
    /// stopped reading, a renamed directory or a regex that matched nothing cannot report a clean
    /// tree over source nobody read.
    ///
    /// **Mutation:** in `ReclamationWatchdog.reassert`, before the driver's call, add `_ = try
    /// await [writer][0].engageManualControl(of: permit)`. Run: red here, and
    /// `onlyTheDriverEngages` stays green, which is why this test exists.
    /// **Mutation:** in `SafetyActorWriter`, add `func sneaky(_ fan: CommandableFan) async throws
    /// { _ = try await engageManualControl(of: fan) }`. Run: red here, and green there.
    /// **Mutation (the floor's own):** scan `"AeolusXPC"` instead of `"AeolusHelper"`. Run: red on
    /// the floor alone — the escaped list is empty over a directory that never names the verb.
    ///
    /// The next test, and `onlyTheDriverEngages`, are what go red for a use that *is* attributed:
    /// `writer.engageManualControl(of: permit)`, `writer . engageManualControl (of: permit)` and
    /// `writer  // driver` with `.engageManualControl(of: permit)` on the next line, each added
    /// the same way. Run: red on both of them, and not here.
    @Test("No use of the step verb escapes the receiver scan")
    func noUseOfTheStepVerbEscapesTheReceiverScan() throws {
        var attributed = 0
        var escaped: [String] = []
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let source = try String(contentsOf: file, encoding: .utf8)
            let named = try SeamScanner.mentions(of: Self.verb, inSource: source)
            let seen = try SeamScanner.receivers(of: Self.verb, inSource: source).count
            attributed += seen
            if named != seen {
                escaped.append("\(file.lastPathComponent): \(named) named, \(seen) attributed")
            }
        }

        #expect(
            attributed >= 6,
            """
            the scan attributed \(attributed) uses of `\(Self.verb)` across the helper. It is \
            supposed to find three in the driver, one in the watchdog, one in level 6's apply and \
            one in the writer's forward, so the assertion below is green over nothing.
            """)
        #expect(
            escaped.isEmpty,
            """
            a use of `\(Self.verb)` has a receiver the scan cannot read: \(escaped). A fan \
            engaged around the driver is one § 3 never heard of, and ADR 0009's #343 amendment \
            rests on every engaged fan being in § 3's registry.
            """)
    }

    // MARK: - The name § 5 and level 6 are allowed

    /// § 5's and level 6's one use each of the verb is through a `driver` bound to the
    /// lease-bound driver.
    ///
    /// `onlyTheDriverEngages` allows the receiver `driver` in `ReclamationWatchdog.swift` and
    /// `LeaseApplier.swift`, and a name proves nothing about what it is bound to. `let driver =
    /// engagement.under(lease: lease)` is the only binding of that name in each file, so `let
    /// driver = writer` — which would pass that test unchanged — is a failure here.
    ///
    /// **Mutation:** in `ReclamationWatchdog.reassert`, replace `engagement.under(lease: lease)`
    /// with `engagement`, the composed driver bound to no lease. Run: red here, and
    /// `onlyTheDriverEngages` stays green — the name is unchanged and the declaration is not.
    /// **Mutation:** the same in `LeaseApplier.step`. Run: red here, on the level-6 file.
    @Test("§ 5 and level 6 engage through the lease-bound driver", arguments: engagingFiles)
    func eachEngagesThroughTheBoundDriver(_ name: String) throws {
        let file = try #require(
            try SeamScanner.swiftFiles(under: "AeolusHelper")
                .first { $0.lastPathComponent == name },
            "\(name) is not in the source tree")
        let source = try String(contentsOf: file, encoding: .utf8)

        #expect(try SeamScanner.receivers(of: Self.verb, inSource: source) == ["driver"])
        let bindings = try Self.bindings(of: "driver", inSource: source)
        #expect(
            bindings.introduced == 1 && bindings.toTheBoundDriver == 1,
            """
            `driver` is introduced \(bindings.introduced) times in \(name), and \
            \(bindings.toTheBoundDriver) of them bind it to `engagement.under(lease:)`. The \
            receiver name is what `onlyTheDriverEngages` allows; this is what makes the name \
            mean the driver.
            """)
    }

    /// The files the test above reads are every file that engages through a `driver`, and each
    /// is in the tree: a file left off the list is one whose binding nothing checks.
    ///
    /// **Mutation:** drop `"LeaseApplier.swift"` from `engagingFiles`. Run: red here, and the test
    /// above stays green over the one file left.
    @Test("The bound-driver check reads every file that engages through a driver")
    func theBoundDriverCheckReadsEveryEngagingFile() throws {
        var engaging: [String] = []
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let source = try String(contentsOf: file, encoding: .utf8)
            if try SeamScanner.receivers(of: Self.verb, inSource: source).contains("driver") {
                engaging.append(file.lastPathComponent)
            }
        }
        #expect(engaging.sorted() == Self.engagingFiles.sorted())
    }

    /// How a name is introduced in one file's code, and how many of those bind it to the
    /// lease-bound driver.
    ///
    /// An introduction is a `let` or `var`, a label-and-colon (a parameter or a call's argument
    /// label), or a closure parameter followed by `in`. Wide on purpose: a second introduction
    /// of the name fails the count, and that is the point.
    private static func bindings(
        of name: String, inSource source: String
    ) throws -> (introduced: Int, toTheBoundDriver: Int) {
        let code = SeamScanner.strippingAllComments(source)
        let range = NSRange(code.startIndex..., in: code)
        let introduced = try NSRegularExpression(
            pattern: #"\b(?:let|var)\s+"# + name + #"\b|\b"# + name + #"\s*:|\b"# + name
                + #"\s+in\b"#)
        let bound = try NSRegularExpression(
            pattern: #"\b(?:let|var)\s+"# + name
                + #"\s*=\s*engagement\s*\.\s*under\s*\(\s*lease\s*:"#)
        return (
            introduced.numberOfMatches(in: code, range: range),
            bound.numberOfMatches(in: code, range: range)
        )
    }

    // MARK: - The scans, on fixtures

    /// The mention count sees what the receiver scan cannot attribute, and neither is fooled by
    /// a comment or a spelling.
    ///
    /// A fixture rather than the tree, for `SeamScannerParsingTests`' reason: nothing in
    /// `Sources` is written these ways today, so a test that only scans the tree cannot know
    /// the scans work.
    ///
    /// **Mutation (this suite's own):** make `SeamScanner.mentions(of:inSource:)` return
    /// `receivers(of:inSource:).count`. Run: red here and only here — the tree test compares
    /// the two, so the fixture is what notices that they have become one.
    /// **Mutation:** drop the `declared` subtraction from `mentions`. Run: red here and in the
    /// tree test, which counts the four declarations as uses.
    /// **Mutation:** in `receivers(of:inSource:)`, strip with `strippingComments` rather than
    /// `strippingAllComments`. Run: red here, on the `tail` fixture; with a `writer  // driver`
    /// use added to the watchdog besides, `onlyTheDriverEngages` stays green and the watchdog
    /// test goes red on the receiver count.
    /// **Mutation:** narrow the whitespace normalisation in `receivers(of:inSource:)` to
    /// `([?!]?)\.`. Run: red here, on the `writer . engageManualControl (` fixture, and in
    /// `theMemberScanSeesEverySpelling`.
    @Test("The scans see every spelling, and a trailing comment is not a receiver")
    func theScansSeeEverySpelling() throws {
        let source = """
            func engageManualControl(of fan: CommandableFan) async throws {}
            _ = try await makeWriter().engageManualControl(of: fan)
            _ = try await writers[0].engageManualControl(of: fan)
            _ = try await engageManualControl(of: fan)
            _ = try await writer . engageManualControl (of: fan)
            _ = try await tail  // driver
                .engageManualControl(of: fan)
            _ = try await clean.engageManualControl(of: fan)  // other.engageManualControl(of: fan)
            // commented.engageManualControl(of: fan)
            let link = "https://example.com"; _ = try await after.engageManualControl(of: fan)
            """

        #expect(try SeamScanner.mentions(of: Self.verb, inSource: source) == 7)
        #expect(
            try SeamScanner.receivers(of: Self.verb, inSource: source)
                == ["writer", "tail", "clean", "after"])
    }

    /// The binding scan counts every way the name can be introduced, and tells the bound driver
    /// from anything else.
    ///
    /// **Mutation (this suite's own):** make `bindings(of:inSource:)` count only the `let`/`var`
    /// alternative. Run: red here, on the parameter and closure fixtures.
    @Test("The binding scan counts every introduction of the name")
    func theBindingScanCountsEveryIntroduction() throws {
        let bound = try Self.bindings(
            of: "driver", inSource: "let driver = engagement.under(lease: lease)")
        #expect(bound.introduced == 1 && bound.toTheBoundDriver == 1)

        let aliased = try Self.bindings(of: "driver", inSource: "let driver = writer")
        #expect(aliased.introduced == 1 && aliased.toTheBoundDriver == 0)

        let spaced = try Self.bindings(
            of: "driver", inSource: "let driver=engagement . under ( lease : lease)")
        #expect(spaced.introduced == 1 && spaced.toTheBoundDriver == 1)

        let elsewhere = try Self.bindings(
            of: "driver",
            inSource: """
                func reassert(driver: Other) {}
                let queue = { driver in driver.go() }
                // let driver = writer
                """)
        #expect(elsewhere.introduced == 2 && elsewhere.toTheBoundDriver == 0)
    }

    // MARK: - The comment stripper's string literals

    /// A comment marker inside a string literal opens no comment, in a multi-line literal and
    /// in a single-line one with an escaped quote.
    ///
    /// Both are the shapes `strippingAllComments(_:)` walks literals for, and both put a `//`
    /// where dropping it would drop a use after it: the first holds a lone `"` and a use inside
    /// the literal, the second an escaped `\"` followed by a use on the same line. Fixtures, for
    /// the first test's reason: nothing in `Sources` is written these ways.
    ///
    /// **Mutation:** delete the `"""` branch from `strippingAllComments(_:)`. Run: red on the
    /// multi-line fixture — the lone `"` pairs with a delimiter quote, the `//` after it is read as
    /// a comment, and the use inside the literal is dropped.
    /// **Mutation:** in `SeamScanner.copyDelimited`, replace the escape branch's condition
    /// `source[index] == "\\"` with `false`. Run: red on the escaped-quote fixture — the literal
    /// ends at the escaped quote, and the use after it is dropped as a comment.
    @Test("A comment marker inside a string literal opens no comment")
    func aCommentMarkerInsideAStringLiteralOpensNoComment() throws {
        let multiline = #"""
            let text = """
                say "hi // not a comment, but a use: writer.engageManualControl(of: fan)
                """
            _ = try await after.engageManualControl(of: fan)
            """#
        #expect(SeamScanner.strippingAllComments(multiline).contains("// not a comment"))
        #expect(try SeamScanner.mentions(of: Self.verb, inSource: multiline) == 2)

        let escaped = #"""
            let text = "a\"// still a string"; _ = try await after.engageManualControl(of: fan)
            """#
        #expect(SeamScanner.strippingAllComments(escaped).contains("// still a string"))
        #expect(try SeamScanner.mentions(of: Self.verb, inSource: escaped) == 1)
        #expect(try SeamScanner.receivers(of: Self.verb, inSource: escaped) == ["after"])
    }

    /// No raw string literal in `Sources/AeolusHelper` holds both a `"` and a `//`, and no line
    /// interpolates and then holds a `"` and a `//`.
    ///
    /// These were the two blind spots `strippingAllComments(_:)` had until #436: it counted quotes
    /// and did not lex, so a raw string `#"say "hi" // x"#`, or a literal nested in an
    /// interpolation, `"\(String("//"))"`, put the count out of step, the `//` read as a comment,
    /// and the rest of its line was dropped. The shared walker now lexes both, raw strings and
    /// interpolations (`SeamScannerLiteralTests`), so this is depth, not the only control: were
    /// the lexer to regress, the helper would still hold no literal that exploits either. Kept for
    /// that, and because it costs one file read. In the style of
    /// `noBlockCommentIsWrittenInSources`.
    ///
    /// **Mutation:** add `private let probe = #"say "hi" // x"#` at file scope in
    /// `SafetyWriters.swift`. Run: red here, naming the file.
    /// **Mutation:** add `private let laneLabel = "\(String("//"))"; private let
    /// laneHiddenFromTheScan = PlaneAdmission.thermalCycle` in `ConnectionHealth.swift`. Run: red
    /// here, naming the file — and green in every lane census, which the stripper blinds.
    @Test("No raw string in the helper holds a quote and a comment marker")
    func noRawStringHoldsAQuoteAndACommentMarker() throws {
        var offenders: [String] = []
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in try Self.rawStringsHoldingAQuoteAndACommentMarker(in: source) {
                offenders.append("\(file.lastPathComponent): \(literal)")
            }
            for line in try Self.interpolationsHoldingAQuoteAndACommentMarker(in: source) {
                offenders.append("\(file.lastPathComponent): \(line)")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            a raw string literal, or an interpolation, holds a `"` and a `//`: \(offenders). \
            A scanner that misreads either reads the `//` as a comment and drops the rest of \
            the line, which can hide a use of the step verb from every scan in this suite; \
            #436's lexer reads both correctly, and this keeps the helper out of the shape in \
            case it stops.
            """)
    }

    /// The scan behind that test, on literals it must and must not report.
    ///
    /// **Mutation (this suite's own):** make `rawStringsHoldingAQuoteAndACommentMarker(in:)`
    /// return nothing. Run: red here — the tree holds no raw string, so the tree test alone
    /// cannot tell a working scan from a dead one.
    @Test("The raw string scan reports a quote with a comment marker, and nothing else")
    func theRawStringScanReportsOnlyTheRiskyLiterals() throws {
        let reported = try Self.rawStringsHoldingAQuoteAndACommentMarker(
            in: ###"""
                let a = #"say "hi" // x"#
                let b = #"https://example.com"#
                let c = #"say "hi""#
                let d = ##"""
                    "quoted" and // marker
                    """##
                let e = "an ordinary \"string\" // is the walker's"
                // let f = #"a "b" // c"#
                """###)

        #expect(reported.count == 2, "reported \(reported)")
        #expect(reported.first?.contains("say \"hi\" // x") == true)
        #expect(reported.last?.contains("// marker") == true)
    }

    /// Every raw string literal in `source`, comments stripped first, that holds both a `"` and
    /// a `//`: single-line (`#"…"#`) and multi-line (`#"""…"""#`), with any number of `#`.
    private static func rawStringsHoldingAQuoteAndACommentMarker(
        in source: String
    ) throws -> [String] {
        let code = SeamScanner.strippingComments(source)
        let literal = try NSRegularExpression(
            pattern: ##"(#+)(?:"""([\s\S]*?)"""|"([^\n]*?)")\1"##)
        return literal.matches(in: code, range: NSRange(code.startIndex..., in: code))
            .compactMap { match in
                let content = [2, 3]
                    .compactMap { Range(match.range(at: $0), in: code).map { String(code[$0]) } }
                    .first
                guard let content, content.contains("\""), content.contains("//") else {
                    return nil
                }
                return Range(match.range, in: code).map { String(code[$0]) }
            }
    }
}
