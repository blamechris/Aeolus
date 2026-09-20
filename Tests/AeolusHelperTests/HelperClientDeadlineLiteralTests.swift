import Foundation
import Testing

@testable import AeolusXPCClient

/// **No test names a deadline tighter than the product's without saying what asserts it.**
///
/// `HelperClientDeadlineTests.noHarnessDefaultImposesATighterDeadlineThanTheProduct` covers every
/// bound a test can *inherit*, and says so precisely: two harness defaults, both defined by
/// reference to the shipping trio. It covers no explicitly passed deadline at all, and
/// [#255](https://github.com/blamechris/Aeolus/issues/255) left deciding whether a source scan
/// should exist as its own acceptance bullet. This is that decision, taken rather than left
/// implied.
///
/// **Why a source scan rather than review.** The defect
/// [#250](https://github.com/blamechris/Aeolus/issues/250) is not a wrong number; it is a
/// number nobody had a reason to look at. A bound below the product's is legitimate where the
/// expiry *is* the assertion, and indistinguishable at a glance from one invented to keep a
/// suite quick — so the two have to be told apart by something that fails when nobody is
/// reading. Review found three of these sites across two rounds of #254 and left the panic
/// column for a third; that is the recall a scan is for.
///
/// **The rule, verb by verb.** Every term of every `HelperClientDeadlines` construction under
/// `Tests/` must either resolve to a duration **no tighter than the product's** for that verb, or
/// appear in `exemptions` below with a reason. A term resolves if it is a duration literal or a
/// `HelperClientDeadlines.<constant>` reference; anything else — a local, a `Self.` constant — is
/// opaque to a scanner and must be exempted by name. That is the correct default: an opaque term
/// is exactly how a short bound gets in unremarked, and writing one costs a line here.
///
/// **"Every construction" is enforced, not assumed.** The scan reads the spelling
/// `HelperClientDeadlines(`, so a construction written `.init(…)` — whether spelled
/// `HelperClientDeadlines.init(…)` or left to inference as `deadlines: .init(…)` — would carry
/// terms this scan never sees. Rather than widen the pattern and hope it stays wide,
/// `noDeadlineIsConstructedInAFormThisScanCannotRead` fails on that spelling and names the
/// explicit form to use. A scanner whose completeness rests on nobody choosing a legal
/// alternative spelling is the shape of guard this file exists to replace.
///
/// **Two limits, stated rather than discovered later.**
///
/// - It reads the *source*, so a term's value is what the text says. `HelperClientDeadlines`
///   itself being tightened moves the product bound and every literal compared against it, and
///   this test stays green — the same blindness
///   `noHarnessDefaultImposesATighterDeadlineThanTheProduct` documents, closed by the same two
///   slow-peer tests, which exercise a real round trip against no constant at all.
/// - Comments are stripped first, as everywhere in this suite, so a construction quoted in prose
///   is invisible. Three doc comments in this target carry the token — two of them spelling out a
///   mutation, one quoting a `grep` for it — and a tripwire that fires on the sentence explaining
///   the rule is a tripwire nobody keeps. String literals are *not* stripped, so this file's own
///   failure messages deliberately never spell the constructor's name followed by an open
///   parenthesis.
@Suite("Explicitly passed client deadlines")
struct HelperClientDeadlineLiteralTests {

    /// One term of one construction: `panicVerb: .seconds(5)`, with where it was written.
    ///
    /// **No line number, deliberately.** `SeamScanner.strippingComments` *removes* comment lines
    /// rather than blanking them, so a position in the stripped text does not name a line in the
    /// file — the first draft of this reported `HelperClientTeardownTests.swift:140` for a site at
    /// 250. Making the shared primitive line-preserving would fix that and would also change the
    /// text handed to every one of its twenty-odd callers, which is a wide change to buy a nicer
    /// message; the enclosing declaration names the site as usefully and costs nothing.
    private struct Term {
        let file: String
        /// The `func` or `static let` the construction sits in, for the failure message — never
        /// for the exemption key. See `exemptions`.
        let context: String
        let verb: String
        let text: String
    }

    /// A term the scanner cannot resolve, or one that is deliberately tighter than the product,
    /// licensed by name.
    ///
    /// **Keyed on the term's text and not on the test's name**, which is the one design decision
    /// here worth arguing with. Keying on the enclosing function would name the site more
    /// precisely and would need the scanner to attribute a construction to the `func` around it —
    /// a parse that is wrong in the easy case, because the statement immediately above one of
    /// these sites is `let deadline = Duration.milliseconds(250)` and the nearest preceding
    /// declaration is therefore the local, not the test. The text is what distinguishes a
    /// licensed term from a new one: a site that starts passing `.seconds(5)` for a handshake
    /// matches nothing here and fires, which is the case that matters. The cost is that one entry
    /// licenses every site in its file that spells the term the same way — `gatedVerb: deadline`
    /// in `HelperClientTeardownTests` is two sites under one entry — and both of those are the
    /// same assertion, so the entry's reason is true of both.
    private struct Exemption {
        let file: String
        let verb: String
        let text: String
        let reason: String
    }

    private static let exemptions: [Exemption] = [
        Exemption(
            file: "HelperClientTests.swift", verb: "gatedVerb", text: "deadline",
            reason: """
                `aMessageNobodyAnswersHasItsOwnError` asserts \
                `helperNeverAnswered(after: 250 ms)` — the expiry of this exact bound is the \
                test, and the value is read back out of the thrown error.
                """),
        Exemption(
            file: "HelperClientTests.swift", verb: "handshakeVerb", text: "handshakeDeadline",
            reason: """
                `theHandshakeIsSentWithinItsOwnDeadline` asserts that `hello` is sent within \
                the handshake bound and not a gated verb's, which is only distinguishable by \
                making this one impossibly small — 1 ns — while the gated verb stays generous.
                """),
        Exemption(
            file: "HelperClientTeardownTests.swift", verb: "gatedVerb", text: "deadline",
            reason: """
                Both sites are about a gated verb timing out: \
                `aTimedOutVerbDoesNotWedgeTheVerbsAfterIt` and \
                `thePanicPathSurvivesATimedOutVerb` each assert \
                `helperNeverAnswered(after: 250 ms)` before going on to the verb that must \
                survive it.
                """),
        Exemption(
            file: "FanctlResetTests.swift", verb: "gatedVerb", text: "Self.observableDeadline",
            reason: """
                `aHelperThatNeverAnswersIsReportedAsUnknown` asserts that `run()` renders the \
                deadline it actually waited, so the injected figure has to be one neither \
                `HelperClientDeadlines` nor the mutation names — 2 s — or the message cannot \
                distinguish the binding from the constant.
                """),
        Exemption(
            file: "FanctlResetTests.swift", verb: "panicVerb", text: "Self.observableDeadline",
            reason: """
                The same assertion on the verb `fanctl reset --all` actually sends: the panic \
                path is where that command's round trip waits, so this is the term the message \
                names.
                """),
    ]

    /// The product's bound per verb, read off the shipping value rather than restated.
    private static let product: [String: Duration] = [
        "gatedVerb": HelperClientDeadlines.default.gatedVerb,
        "panicVerb": HelperClientDeadlines.default.panicVerb,
        "handshakeVerb": HelperClientDeadlines.default.handshakeVerb,
    ]

    /// **Mutation:** in `HelperClientTeardownTests.thePanicPathSurvivesATimedOutVerb`, put
    /// `handshakeVerb: .seconds(5)` back. Run: red here, naming the file, the line and the two
    /// durations — which is #255's first site reported by a test instead of by a review round.
    @Test("No explicitly passed deadline is tighter than the product's unless it is exempt")
    func noExplicitDeadlineIsTighterThanTheProduct() throws {
        for term in try Self.terms() {
            let bound = try #require(
                Self.product[term.verb], "\(term.verb) is not a verb this client has a bound for")

            if let resolved = Self.duration(of: term.text) {
                if resolved >= bound { continue }
                #expect(
                    Self.licence(for: term) != nil,
                    """
                    \(term.file), in `\(term.context)`, allows \(term.verb) \(resolved) where \
                    the product allows \(bound). A harness that tightens a deadline is not \
                    testing the client; it is testing the runner, and it fails on a slow one \
                    while the client under it is correct (#250, #255). If the expiry is the \
                    assertion, say so in this suite's exemption list.
                    """)
                continue
            }

            #expect(
                Self.licence(for: term) != nil,
                """
                \(term.file), in `\(term.context)`, passes \(term.verb) `\(term.text)`, which \
                this scan cannot resolve to a duration — so it cannot tell a bound the test \
                asserts from one invented to keep the suite quick. Name it in this suite's \
                exemption list with what asserts it, or pass a `HelperClientDeadlines` \
                constant.
                """)
        }
    }

    /// Every exemption is still doing something.
    ///
    /// A licence outliving the site it was written for is worse than no licence: it is a
    /// pre-approval waiting for the next term to spell itself the same way, in a file where the
    /// reviewer has already been told that spelling is fine. #254 fixed two of these sites and
    /// the comment naming the third survived the issue it pointed at — the same shape one level
    /// up.
    ///
    /// **Mutation:** delete the `thePanicPathSurvivesATimedOutVerb` half of the
    /// `HelperClientTeardownTests` gated exemption by changing that test's bound to
    /// `HelperClientDeadlines.gatedVerb`, and the entry stays used by the other site — which is
    /// the cost of a text key, recorded rather than hidden. Deleting *both* sites reddens this.
    @Test("Every deadline exemption is still used by a site that exists")
    func everyExemptionIsStillUsed() throws {
        let terms = try Self.terms()
        for exemption in Self.exemptions {
            #expect(
                terms.contains {
                    $0.file == exemption.file && $0.verb == exemption.verb
                        && $0.text == exemption.text
                },
                """
                nothing in \(exemption.file) passes \(exemption.verb) `\(exemption.text)` any \
                more, so this exemption licenses nothing and is waiting to license something \
                else. Its reason was: \(exemption.reason)
                """)
        }
    }

    private static func licence(for term: Term) -> Exemption? {
        exemptions.first {
            $0.file == term.file && $0.verb == term.verb && $0.text == term.text
        }
    }

    /// `.seconds(30)` and `Duration.milliseconds(250)` and `HelperClientDeadlines.gatedVerb`;
    /// `nil` for anything else.
    private static func duration(of text: String) -> Duration? {
        let named: [String: Duration] = product.merging([
            "reconciliationBudget": HelperClientDeadlines.reconciliationBudget,
            "spawnAllowance": HelperClientDeadlines.spawnAllowance,
        ]) { current, _ in current }

        if let constant = text.split(separator: ".").last, text.hasPrefix("HelperClientDeadlines.")
        {
            return named[String(constant)]
        }

        guard
            let match = text.range(
                of: #"^(Duration)?\.(seconds|milliseconds|microseconds|nanoseconds)\(\d+\)$"#,
                options: .regularExpression)
        else { return nil }
        let call = text[match].drop(while: { $0 != "." }).dropFirst()
        guard let open = call.firstIndex(of: "("),
            let amount = Int(call[call.index(after: open)..<call.index(before: call.endIndex)])
        else { return nil }

        switch call[..<open] {
        case "seconds": return .seconds(amount)
        case "milliseconds": return .milliseconds(amount)
        case "microseconds": return .microseconds(amount)
        case "nanoseconds": return .nanoseconds(amount)
        default: return nil
        }
    }

    /// Every labelled term of every construction under `Tests/`, comments stripped.
    private static func terms() throws -> [Term] {
        var found: [Term] = []
        for file in try SeamScanner.swiftFilesUnderTests() {
            found += terms(
                inSource: SeamScanner.strippingComments(
                    try String(contentsOf: file, encoding: .utf8)),
                file: file.lastPathComponent)
        }
        #expect(
            !found.isEmpty,
            "no explicitly passed client deadline was found at all, so this scan asserts nothing")
        return found
    }

    private static func terms(inSource code: String, file: String) -> [Term] {
        // Spelled in two pieces so this scan does not find itself: string literals survive
        // comment stripping, and a scanner that reports its own message text as a call site is
        // one nobody keeps.
        let constructor = "HelperClientDeadlines" + "("
        var found: [Term] = []
        var searched = code.startIndex

        while let start = code.range(of: constructor, range: searched..<code.endIndex) {
            searched = start.upperBound
            guard
                let open = code.index(start.upperBound, offsetBy: -1, limitedBy: code.endIndex),
                let close = SeamScanner.closingParenthesis(in: code, openingAt: open)
            else { continue }

            let context = enclosingDeclaration(in: code, before: start.lowerBound)
            for argument in arguments(of: String(code[code.index(after: open)..<close])) {
                guard let colon = argument.firstIndex(of: ":") else { continue }
                found.append(
                    Term(
                        file: file,
                        context: context,
                        verb: SeamScanner.collapsingWhitespace(String(argument[..<colon])),
                        text: SeamScanner.collapsingWhitespace(
                            String(argument[argument.index(after: colon)...]))))
            }
        }
        return found
    }

    /// The argument clause split at depth-zero commas, so `.seconds(5)` stays in one piece.
    private static func arguments(of clause: String) -> [String] {
        var components: [String] = []
        var current = ""
        var depth = 0

        for character in clause {
            switch character {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            default: break
            }
            if character == "," && depth == 0 {
                components.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        components.append(current)
        return components.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The nearest `func` or `static let` declared above a construction, for the failure message
    /// only.
    ///
    /// A bare `let` is deliberately not matched: the statement immediately above three of these
    /// sites is `let deadline = Duration.milliseconds(250)`, so matching locals would name the
    /// local instead of the test at exactly the sites a reader most needs named. `static let`
    /// catches the two suite-level defaults, which sit outside any `func`. It is allowed to be
    /// approximate because nothing is keyed on it — `exemptions` records why.
    ///
    /// **The matches are enumerated and the last one taken, rather than searched `.backwards`.**
    /// `range(of:options:range:)` with `[.regularExpression, .backwards]` returned the *first*
    /// match in the range, so every site in a file was attributed to that file's first `func` —
    /// which is a failure message confidently naming the wrong test, and worse than none.
    private static func enclosingDeclaration(in code: String, before start: String.Index) -> String
    {
        guard
            let expression = try? NSRegularExpression(pattern: #"(func|static\s+let)\s+\w+"#),
            let last = expression.matches(
                in: code, range: NSRange(code.startIndex..<start, in: code)
            ).last,
            let declaration = Range(last.range, in: code)
        else { return "file scope" }
        return SeamScanner.collapsingWhitespace(String(code[declaration]))
    }

    /// `.init(…)` carries the same terms and this scan cannot read them.
    ///
    /// `terms()` finds the spelling `HelperClientDeadlines(`. Swift accepts two others for the
    /// same call — `HelperClientDeadlines.init(…)`, and bare `.init(…)` where the parameter type
    /// makes it unambiguous — and a term inside either is invisible to the assertion above while
    /// looking exactly like one that was checked. That is the one route a fixed pattern leaves
    /// open, so it is closed here rather than documented as a limit: the remedy is one word at
    /// the call site, and the failure says so.
    ///
    /// Keyed on the verb labels rather than on the type name, because the inferred spelling
    /// never names the type. Any of the three is enough — a construction carrying none of them
    /// sets no deadline and is not this scan's business.
    @Test("No deadline is constructed in a form this scan cannot read")
    static func noDeadlineIsConstructedInAFormThisScanCannotRead() throws {
        let needle = ".init" + "("
        var offenders: [String] = []

        for file in try SeamScanner.swiftFilesUnderTests() {
            let code = SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8))
            var searched = code.startIndex
            while let start = code.range(of: needle, range: searched..<code.endIndex) {
                searched = start.upperBound
                guard
                    let open = code.index(start.upperBound, offsetBy: -1, limitedBy: code.endIndex),
                    let close = SeamScanner.closingParenthesis(in: code, openingAt: open)
                else { continue }
                let clause = String(code[code.index(after: open)..<close])
                guard product.keys.contains(where: { clause.contains($0 + ":") }) else { continue }
                offenders.append(
                    "\(file.lastPathComponent): \(SeamScanner.collapsingWhitespace(clause))")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A client deadline is constructed with `.init(`, which this file's scan does not read, \
            so its terms are unchecked while looking checked: \
            \(offenders.joined(separator: " | ")). \
            Spell it `HelperClientDeadlines(…)` at the call site — the scan reads that form, and \
            reading it is the whole point of #255's acceptance bullet.
            """)
    }

}
