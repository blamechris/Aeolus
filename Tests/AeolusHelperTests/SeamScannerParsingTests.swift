import Foundation
import Testing

/// The parser behind every source-scanning tripwire in this target, tested against fixtures
/// rather than against the tree it scans.
///
/// A scanner exercised only through `Sources` is exercised only for the shapes already
/// written there. Every limit `SeamScanner.functions(in:)` states was, until #177, a claim
/// about the parser that nothing checked — and two of them were false: block comments were
/// *not* stripped, and a nested generic clause silently matched nothing. Both were prose
/// asserting the opposite of the code, in a suite whose whole subject is guards that say
/// more than they do.
@Suite("The seam scanner parses what its stated limits say it parses")
struct SeamScannerParsingTests {

    private func scan(_ code: String) throws -> [SeamScanner.Function] {
        try SeamScanner.functions(inSource: code, file: "Fixture.swift")
    }

    // MARK: - Comments

    /// The inverted limit. A signature quoted in prose is not that signature, and a tripwire
    /// that fires on the sentence explaining the rule is a tripwire nobody keeps — which the
    /// doc comments claimed of `/* … */` while only `//` was implemented.
    @Test("A declaration inside a block comment is not a declaration")
    func blockCommentsAreStripped() throws {
        let found = try scan(
            """
            /* The forbidden shape, for the reader:
               func setFanSpeed(_ rpm: Double, ofFan index: Int) async throws
            */
            func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {}
            """)

        #expect(found.map(\.name) == ["readEnvelope"])
    }

    /// Swift nests block comments, so taking the first `*/` would end the span early and
    /// scan the rest of the outer comment as code.
    @Test("Nested block comments close at the outer delimiter")
    func nestedBlockCommentsAreStripped() throws {
        let found = try scan(
            """
            /* outer
               /* inner */
               func setFanSpeed(_ rpm: Double, ofFan index: Int) async throws
            */
            func reconnect() async throws {}
            """)

        #expect(found.map(\.name) == ["reconnect"])
    }

    /// A `/*` inside a string literal opens nothing. Treating one as a comment would swallow
    /// the rest of the file and take every later declaration with it — a scanner that finds
    /// nothing is a green tripwire.
    @Test("A block-comment delimiter inside a string literal opens no comment")
    func stringLiteralsDoNotOpenComments() throws {
        let found = try scan(
            """
            let note = "/*"
            func commandTarget(_ target: AuthorisedFanTarget) async throws {}
            let close = "*/"
            func restoreToAutomatic(_ scope: FanRestoreScope) async throws {}
            """)

        #expect(found.map(\.name) == ["commandTarget", "restoreToAutomatic"])
    }

    /// The same, for the multi-line form `HelperLog` is written in.
    @Test("A block-comment delimiter inside a multi-line string opens no comment")
    func multiLineStringLiteralsDoNotOpenComments() throws {
        let found = try scan(
            #"""
            let note = """
                /* not a comment
                """
            func commandTarget(_ target: AuthorisedFanTarget) async throws {}
            """#)

        #expect(found.map(\.name) == ["commandTarget"])
    }

    /// A `/*` inside a `//` comment opens nothing either — the line comment wins, and the
    /// stripper must not read a delimiter out of prose it is about to discard.
    @Test("A block-comment delimiter inside a line comment opens no comment")
    func lineCommentsDoNotOpenBlockComments() throws {
        let found = try scan(
            """
            // a ratio written /* like this
            func commandTarget(_ target: AuthorisedFanTarget) async throws {}
            """)

        #expect(found.map(\.name) == ["commandTarget"])
    }

    // MARK: - Signatures

    /// `<[^>]*>` cannot span a nested `>`, so such a declaration matched **nothing at all**
    /// and went silently uncounted — the same failure mode as `\([^)]*\)` on a nested `)`,
    /// and the one an allowlist cannot survive.
    @Test("A generic clause containing a nested angle bracket does not hide the declaration")
    func nestedGenericClausesAreParsed() throws {
        let found = try scan(
            "func decode<T: Decoding<Wire>>(_ payload: Data, as type: T.Type) async throws {}")

        #expect(found.map(\.name) == ["decode"])
        #expect(found.first?.labels == ["_", "as"])
        #expect(found.first?.parameterTypes == ["Data", "T.Type"])
    }

    /// The key that #177 widened. An overload differing only in a parameter's type is a
    /// different verb, and an allowlist keyed on labels alone filed it under the acknowledged
    /// one — the exact silent addition the suite exists to stop.
    @Test("An overload differing only in a parameter type gets its own key")
    func overloadsDoNotCollapseOntoOneKey() throws {
        let found = try scan(
            """
            func command(_ rpm: Double, of fan: CommandableFan) async throws {}
            func command(_ rpm: Double, of index: Int) async throws {}
            """)

        #expect(
            Set(found.map(\.key)) == [
                "Fixture.swift: command(_: Double, of: CommandableFan)",
                "Fixture.swift: command(_: Double, of: Int)",
            ])
    }

    /// The collapse that stays. A protocol requirement and its same-file conformer have
    /// byte-identical signatures, which is how `LeaseClock` and `CriticalTemperatureSensing`
    /// are written; widening the key must not turn those into two entries to maintain.
    @Test("A protocol requirement and its same-file conformer still share one key")
    func identicalSignaturesStillCollapse() throws {
        let found = try scan(
            """
            protocol LeaseClocking {
                func sleep(until deadline: ContinuousClock.Instant) async throws
            }
            struct LeaseClock: LeaseClocking {
                func sleep(until deadline: ContinuousClock.Instant) async throws {}
            }
            """)

        #expect(found.count == 2)
        #expect(Set(found.map(\.key)) == ["Fixture.swift: sleep(until: ContinuousClock.Instant)"])
    }

    /// The limit that is real and now says so: an operator declaration is not `func <name>`,
    /// so `SafetyPrecedence.swift`'s `static func <` is outside every scan here.
    @Test("An operator declaration is outside the scan, as the limits say")
    func operatorDeclarationsAreNotScanned() throws {
        let found = try scan(
            """
            static func < (lhs: SafetyActorLevel, rhs: SafetyActorLevel) -> Bool {}
            func cycle() async throws {}
            """)

        #expect(found.map(\.name) == ["cycle"])
    }

    /// The parse `\([^)]*\)` cannot do, restated as a property of the parser rather than of
    /// the one mutation that demonstrated it.
    @Test("A parameter carrying its own parentheses does not truncate the declaration")
    func nestedParenthesesAreParsed() throws {
        let found = try scan(
            "func engageManualControl(of fan: CommandableFan, "
                + "logging note: () -> String = { \"\" }) async throws {}")

        #expect(found.first?.labels == ["of", "logging"])
        #expect(found.first?.parameterTypes == ["CommandableFan", "() -> String"])
        #expect(found.first?.isAsync == true)
    }

    /// A `//` comment trailing the parameter list did not merely reach the effects clause —
    /// it **became** it, non-empty, so the wrapped `async throws` on the next line was never
    /// looked at. `isAsync` came back `false` and the verb left the population without
    /// reddening anything, which is the silent-drop failure the whole allowlist rests on not
    /// happening.
    @Test("A comment trailing the parameter list does not hide a wrapped effects clause")
    func aTrailingCommentDoesNotHideTheEffectsClause() throws {
        let found = try scan(
            """
            func commandUngoverned(_ requestedRPM: Double, of index: Int)  // ungoverned
                async throws -> CommandedTarget
            """)

        #expect(found.map(\.name) == ["commandUngoverned"])
        #expect(found.first?.isAsync == true)
        #expect(found.first?.effects == "async throws -> CommandedTarget")
    }

    /// The same, with a `{` inside the trailing comment. The line scan stops at a `{` — that
    /// is what keeps a body out of the clause — so a comment mentioning one would have ended
    /// the line before the newline, and the wrapped clause would have been lost by a second
    /// route.
    @Test("A brace inside a trailing comment does not end the line early")
    func aBraceInsideATrailingCommentIsIgnored() throws {
        let found = try scan(
            """
            func commandUngoverned(_ requestedRPM: Double, of index: Int)  // as in { … }
                async throws -> CommandedTarget
            """)

        #expect(found.first?.isAsync == true)
    }

    /// A comment trailing a *complete* declaration still names no effects, and the body's
    /// `{` still stops the clause before it.
    @Test("A comment after the body's brace is not read as an effects clause")
    func aCommentAfterTheBodyIsNotAnEffectsClause() throws {
        let found = try scan("func reconnect() async throws {}  // reconnects")

        #expect(found.first?.effects == "async throws")
    }

    /// `parameterListStart` walked the generic clause without the return-arrow guard
    /// `topLevelComponents` has always had, so a constraint that is itself a function type
    /// closed the clause early, the `(` was never found, and the declaration went **silently
    /// uncounted** — the same shape as the nested-`>` defect, one level in.
    @Test("A generic constraint containing a function type does not hide the declaration")
    func genericConstraintsContainingAnArrowAreParsed() throws {
        let found = try scan(
            "func command<T: Sequence<() -> Void>>(_ rpm: Double, of fan: CommandableFan) "
                + "async throws {}")

        #expect(found.map(\.name) == ["command"])
        #expect(found.first?.parameterTypes == ["Double", "CommandableFan"])
    }

    /// A bare `>` in a default value is a comparison and closes nothing. Letting it drive the
    /// depth negative put the following comma below depth zero, so every later parameter was
    /// swallowed into the first component — and a permit in the second named no permit.
    @Test("A comparison in a default value does not swallow the later parameters")
    func aComparisonInADefaultValueDoesNotSwallowParameters() throws {
        let found = try scan(
            "func f(_ rpm: Double = 1 > 0 ? 1 : 2, of fan: CommandableFan) async throws {}")

        #expect(found.first?.labels == ["_", "of"])
        #expect(found.first?.parameterTypes == ["Double", "CommandableFan"])
    }

    // MARK: - Unstructured task spawns

    /// The spelling the first pattern missed. `Task<Void, Never> { … }` is a legal way to
    /// write exactly the thing `everyUnstructuredTaskHandsOffToThePopulation` counts, so a
    /// pattern blind to it asserted a number that was not the number it claimed — and the
    /// hole it left is the one route around "a synchronous function cannot `await`".
    @Test("An explicitly generic Task is counted as a spawn site")
    func explicitlyGenericTasksAreCounted() throws {
        #expect(
            try SeamScanner.unstructuredTaskSpawns(
                inSource: "_ = Task<Void, Never> { await Task.yield() }") == 1)
    }

    /// Every other spelling in the tree, so widening the pattern for the generic case did not
    /// quietly cost one of them.
    @Test("The plain, detached, prioritised and self-capturing spellings are all counted")
    func everySpawnSpellingIsCounted() throws {
        let source = """
            Task { await session.invalidate() }
            Task.detached(priority: .utility) { await supervisor.run() }
            Task<[Key], Error> { [self] in try await walkEveryKey() }
            Task.detached { await emergency.cycle() }
            """

        #expect(try SeamScanner.unstructuredTaskSpawns(inSource: source) == 4)
    }

    /// A stored `Task` is a handle, not a spawn. The optional's `?` is what separates them,
    /// and the pattern must not read the type annotation as a site.
    @Test("A stored Task handle is not a spawn site")
    func storedTaskHandlesAreNotSpawnSites() throws {
        let source = """
            private var discovery: Task<[DiscoveredSensorKey], Error>?

            func f() {
                let walk: Task<[DiscoveredSensorKey], Error>
                if let discovery {
                    walk = discovery
                }
            }
            """

        #expect(try SeamScanner.unstructuredTaskSpawns(inSource: source) == 0)
    }

    // MARK: - The premise the block-comment stripper rests on

    /// `strippingBlockComments` argues that its quote-counter cannot weaken a scan because
    /// `depth` never rises over this tree. That is a claim about `Sources`, not about the
    /// code, and it was resting on nobody having checked. It is checked here, so the day a
    /// block comment is written is the day the argument is re-read rather than the day it
    /// quietly stops holding.
    @Test("No block comment is written in Sources, which the stripper's argument assumes")
    func noBlockCommentIsWrittenInSources() throws {
        for file in try SeamScanner.swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains("/*"),
                """
                \(file.lastPathComponent) contains a block comment. `strippingBlockComments` \
                argues its quote-counting string handling cannot weaken a scan because \
                `depth` never rises over this tree — re-read that argument, because it no \
                longer holds by inspection.
                """
            )
        }
    }
}
