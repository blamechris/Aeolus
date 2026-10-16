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
    private static let watchdogFile = "ReclamationWatchdog.swift"

    // MARK: - No use escapes

    /// Every use of the verb in `Sources/AeolusHelper` is one the receiver scan attributes.
    ///
    /// The count of attributed uses is a floor set at what the tree holds — three in the driver,
    /// one in the watchdog, one in the writer's forward — so a scan that stopped reading, a
    /// renamed directory or a regex that matched nothing cannot report a clean tree over
    /// source nobody read.
    ///
    /// **Mutation:** in `ReclamationWatchdog.reassert`, before the driver's call, add `_ = try
    /// await [writer][0].engageManualControl(of: permit)`. Run: red here, and `onlyTheDriverEngages`
    /// stays green, which is why this test exists.
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
            attributed >= 5,
            """
            the scan attributed \(attributed) uses of `\(Self.verb)` across the helper. It is \
            supposed to find three in the driver, one in the watchdog and one in the writer's \
            forward, so the assertion below is green over nothing.
            """)
        #expect(
            escaped.isEmpty,
            """
            a use of `\(Self.verb)` has a receiver the scan cannot read: \(escaped). A fan \
            engaged around the driver is one § 3 never heard of, and ADR 0009's #343 amendment \
            rests on every engaged fan being in § 3's registry.
            """)
    }

    // MARK: - The name the watchdog is allowed

    /// The watchdog's one use of the verb is through a `driver` bound to the lease-bound driver.
    ///
    /// `onlyTheDriverEngages` allows the receiver `driver` in `ReclamationWatchdog.swift`, and a
    /// name proves nothing about what it is bound to. `let driver = engagement.under(lease:
    /// lease)` is the only binding of that name in the file, so `let driver = writer` — which
    /// would pass that test unchanged — is a failure here.
    ///
    /// **Mutation:** in `ReclamationWatchdog.reassert`, replace `engagement.under(lease: lease)`
    /// with `engagement`, the composed driver bound to no lease. Run: red here, and
    /// `onlyTheDriverEngages` stays green — the name is unchanged and the declaration is not.
    @Test("The watchdog engages through the lease-bound driver")
    func theWatchdogEngagesThroughTheBoundDriver() throws {
        let file = try #require(
            try SeamScanner.swiftFiles(under: "AeolusHelper")
                .first { $0.lastPathComponent == Self.watchdogFile },
            "\(Self.watchdogFile) is not in the source tree")
        let source = try String(contentsOf: file, encoding: .utf8)

        #expect(try SeamScanner.receivers(of: Self.verb, inSource: source) == ["driver"])
        let bindings = try Self.bindings(of: "driver", inSource: source)
        #expect(
            bindings.introduced == 1 && bindings.toTheBoundDriver == 1,
            """
            `driver` is introduced \(bindings.introduced) times in \(Self.watchdogFile), and \
            \(bindings.toTheBoundDriver) of them bind it to `engagement.under(lease:)`. The \
            receiver name is what `onlyTheDriverEngages` allows; this is what makes the name \
            mean the driver.
            """)
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
}
