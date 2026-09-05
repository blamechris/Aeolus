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
}
