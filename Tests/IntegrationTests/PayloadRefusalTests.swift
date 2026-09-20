import FanKit
import Foundation
import Testing

@testable import AeolusXPC

/// **What a refused client is actually told**, which is the assertion
/// [#276](https://github.com/blamechris/Aeolus/issues/276) found missing everywhere.
///
/// `XPCValidationTests` covers refusal thoroughly and stops at `wireCode ==
/// "malformedPayload"`. That is enough to prove a payload was rejected and says nothing about
/// the sentence the rejection carries — which is how `malformedDetail(for:)` came to map every
/// `.dataCorrupted` to *"is not well-formed JSON"*, including this project's own refusals,
/// without a single test going red. A client that sent syntactically perfect JSON containing a
/// non-finite curve point was sent looking for a syntax error that did not exist.
///
/// So every test here compares the **detail**, and the suite is arranged around the one
/// distinction the mechanism has to preserve: our refusals are recognised and rendered,
/// Foundation's are not and must stay flattened.
@Suite("What a refused payload tells the client")
struct PayloadRefusalTests {

    private static func detail(ofRefusing json: String) throws -> String {
        let thrown = try #require(
            fault(from: { _ = try AeolusXPCValidation.decodeFanSettings(from: Data(json.utf8)) }),
            "the payload was accepted, so there is no detail to inspect")
        guard case .malformedPayload(let detail) = thrown else {
            Issue.record("expected a malformedPayload fault, got \(thrown)")
            return ""
        }
        return detail
    }

    /// A `[FanSetting]` naming a curve with no points — a control that commands nothing.
    ///
    /// This is `Control.isHonourable`'s reachable arm. Its sibling, a non-finite fixed RPM,
    /// is **not** reachable through `AeolusXPCCoding.decoder()` — see below.
    private static let dishonourableControl = """
        [{"fanIndex":0,"control":{"curve":{"_0":{"points":[],\
        "source":{"sensorKeys":["TC0P"],"aggregation":"maximum"},\
        "hysteresisCelsius":2,"maximumRampRPMPerSecond":100}}}}]
        """

    // MARK: - Our own refusals are rendered

    /// **Acceptance criterion 1**, end to end through the decoder the helper actually runs.
    ///
    /// Asserted against `PayloadRefusal`'s own `description` rather than a repeated string
    /// literal: a literal here would be a second copy of the wire text and the first thing to
    /// drift when a case is reworded. The `!=` against the flattened string is the regression
    /// this issue is about, stated separately so a failure says *which* half broke.
    ///
    /// **Mutation:** in `malformedDetail(for:)`, drop the `underlyingError` branch and return
    /// `"is not well-formed JSON"` for every `.dataCorrupted`, as it was written before #276.
    /// Run: red.
    @Test("A refusal this project wrote reaches the client as itself")
    func ourOwnRefusalsAreRendered() throws {
        let detail = try Self.detail(ofRefusing: Self.dishonourableControl)

        #expect(detail == PayloadRefusal.controlNotHonourable.description)
        #expect(
            detail != "is not well-formed JSON",
            "the payload was well-formed JSON — this is #276 exactly")
    }

    /// The same mechanism for `.curvePointNotFinite`, which **cannot** be reached through
    /// `decodeFanSettings` — and that is a fact about the payload, not a gap in this test.
    ///
    /// `AeolusXPCCoding.decoder()` leaves `nonConformingFloatDecodingStrategy` at `.throw`,
    /// so a literal `NaN`/`Infinity` token is refused by Foundation before
    /// `FanCurve.init(from:)` runs, and a numeric overflow such as `1e400` is refused by the
    /// JSON parser as unrepresentable. Both are genuine `dataCorrupted` errors *of
    /// Foundation's*, and both correctly report as malformed JSON. So #276's first acceptance
    /// criterion — "a settings payload refused for a non-finite curve point" — describes a
    /// payload the shipped decoder cannot produce, and #275's guard is a second line behind a
    /// strategy that is the first. `FanSettingTests.nonFiniteFixedRPMDecodedThrows` records
    /// the same reasoning for its own guard.
    ///
    /// What can be asserted, and is, is the half that would actually break: the error
    /// `FanCurve.init(from:)` really throws is carried through `malformedDetail(for:)`
    /// unflattened. The decoder here is the one a future configuration would have to look
    /// like for the guard to matter at all.
    ///
    /// **Mutation:** the same one as above. Run: red.
    @Test(
        "A non-finite curve point's refusal survives malformedDetail",
        arguments: ["NaN", "Infinity", "-Infinity"])
    func aNonFiniteCurvePointsRefusalIsRendered(_ token: String) throws {
        let json = """
            {"points":[{"temperatureCelsius":"\(token)","rpm":1200}],\
            "source":{"sensorKeys":["TC0P"],"aggregation":"maximum"},\
            "hysteresisCelsius":2,"maximumRampRPMPerSecond":100}
            """
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")

        var thrown: (any Error)?
        do {
            _ = try decoder.decode(FanCurve.self, from: Data(json.utf8))
        } catch {
            thrown = error
        }
        let error = try #require(thrown, "the non-finite point was accepted")

        #expect(
            AeolusXPCValidation.malformedDetail(for: error)
                == PayloadRefusal.curvePointNotFinite.description)
    }

    // MARK: - Foundation's are not

    /// **Acceptance criterion 2.** Foundation's own refusals stay flattened, quoting nothing.
    ///
    /// The marker is the whole point of the second assertion, and choosing a payload that can
    /// actually carry it into `debugDescription` is the whole point of this doc block. The
    /// first version of this test sent `{["marker" not json at all` — and for *that* payload
    /// `debugDescription` reads "The given data was not valid JSON." and the underlying
    /// `NSError` reads "Unexpected character '[' around line 1, column 3.". The parser reports
    /// a **column**, not the token, so the marker appeared in neither and the assertion
    /// labelled as the boundary check could not fail under any implementation. A review caught
    /// that; it was a test that passes but cannot fail, in the test written to guard the
    /// boundary.
    ///
    /// An unrecognised `Aggregation` is the payload that does carry it. The enum's
    /// **synthesised** `Codable` conformance throws a `.dataCorrupted` whose
    /// `debugDescription` is "Cannot initialize Aggregation from invalid String value
    /// \(theClientsBytes)" — client text verbatim, in the exact field a careless fix would
    /// return, and reachable through `AeolusXPCCoding.decoder()` from syntactically perfect
    /// JSON.
    ///
    /// That it reports as "is not well-formed JSON" is itself #276's complaint, unfixed: a
    /// synthesised conformance cannot be routed through `PayloadRefusal`, so the closed
    /// vocabulary covers the hand-written refusals only.
    /// [#284](https://github.com/blamechris/Aeolus/issues/284) carries it. Flattening is the
    /// *safe* answer here, which is why this is a follow-on rather than a blocker — and why
    /// this test asserts the flattening rather than waiting for the fix.
    ///
    /// **Mutation:** return `context.debugDescription` instead of the flattened string in
    /// `malformedDetail(for:)`'s `.dataCorrupted` case. Run: red on **both** assertions — a
    /// fix that trusts the free-form string satisfies the test above and puts a client's bytes
    /// in a root daemon's log line.
    @Test("Foundation's own refusals stay flattened, and quote none of the client's bytes")
    func foundationsRefusalsStayFlattened() throws {
        let marker = "sentinelValueFromTheClient"
        let json = """
            [{"fanIndex":0,"control":{"curve":{"_0":{"points":[],\
            "source":{"sensorKeys":["TC0P"],"aggregation":"\(marker)"},\
            "hysteresisCelsius":2,"maximumRampRPMPerSecond":100}}}}]
            """
        let detail = try Self.detail(ofRefusing: json)

        #expect(detail == "is not well-formed JSON")
        #expect(detail.contains(marker) == false, "the client's own bytes reached the detail")
    }

    // MARK: - The vocabulary stays closed

    /// **Acceptance criterion 3, the half a behavioural test cannot reach.** No
    /// hand-written `.dataCorrupted` is constructed anywhere except through
    /// `DecodingError.refusing(_:forKey:in:)`.
    ///
    /// `DecodingError.dataCorruptedError(forKey:in:debugDescription:)` — the convenience all
    /// five sites used before #276 — has no parameter for an `underlyingError`, so a site that
    /// reaches for it produces a refusal indistinguishable from Foundation's and is silently
    /// flattened back to *"is not well-formed JSON"*. Nothing at runtime can see that: the
    /// site refuses correctly, the payload is rejected, and only the sentence is wrong. That
    /// is precisely how this defect survived to be found by reading.
    ///
    /// ## Two needles, and neither needs a `case`-line heuristic
    ///
    /// The first version of this scan counted bare `.dataCorrupted(` and dropped whole lines
    /// beginning `case ` so that `malformedDetail`'s own pattern match would not fail the
    /// guard protecting it. A review showed that both halves were wrong: a construction
    /// sharing a line with its pattern — `case (nil, nil): throw
    /// DecodingError.dataCorruptedError(…)` — was dropped with it, and a `case` reflowed
    /// across two lines by `swift format` was counted as a construction. The guard could be
    /// evaded by formatting and could be broken by formatting.
    ///
    /// The spellings below need neither exception. `dataCorruptedError(` is a static factory
    /// and can never appear in a pattern. `DecodingError.dataCorrupted(` is the only way to
    /// construct one where no contextual type is supplied, which a `throw` never is — and if
    /// somebody does write that spelling in a pattern, it is counted, which is the
    /// conservative direction.
    ///
    /// Whitespace before the parenthesis is normalised away first, because `foo (bar)` is a
    /// legal call in Swift and a needle anchored to `(` would otherwise miss it. `swift format
    /// --strict` would reject that spelling in CI, but a guard that depends on the formatter
    /// having run is a guard with a precondition nobody states — raised in review on this PR.
    ///
    /// ## The positive control is separate, and deliberate
    ///
    /// An emptiness check over a pattern that had quietly stopped matching anything would pass
    /// for ever — #203's lesson. So the sanctioned construction is asserted by count in its
    /// own file, through the same walker and the same matcher, which is what proves the scan
    /// is looking at real source rather than at nothing.
    ///
    /// **Mutation A:** put the convenience back at any site, including on a `case` line —
    /// `case (nil, nil): throw DecodingError.dataCorruptedError(forKey: .value, in: container,
    /// debugDescription: "x")` in `Fan.swift`. Run: red, naming the file.
    /// **Mutation B:** delete the `.dataCorrupted(` construction from
    /// `DecodingError.refusing`. Run: red on the positive control.
    @Test("Every hand-written .dataCorrupted refusal travels as a PayloadRefusal")
    func everyRefusalInSourcesTravelsAsAValue() throws {
        var banned: [String] = []
        for file in try Self.swiftFilesUnderSourcesAndTools() {
            let code = Self.callSpellings(try String(contentsOf: file, encoding: .utf8))
            let count =
                Self.occurrences(of: "dataCorruptedError(", in: code)
                + Self.occurrences(of: "DecodingError.dataCorrupted(", in: code)
            if count > 0 { banned.append("\(file.lastPathComponent) x\(count)") }
        }

        #expect(
            banned.isEmpty,
            """
            a .dataCorrupted is constructed outside DecodingError.refusing(_:forKey:in:): \
            \(banned). The convenience initialiser cannot carry an underlyingError, so such \
            a refusal is indistinguishable from a Foundation syntax error and reaches the \
            client as "is not well-formed JSON" — #276, which nothing at runtime can see.
            """)

        let sanctioned = Self.occurrences(
            of: ".dataCorrupted(", in: Self.callSpellings(try Self.refusalSource()))
        #expect(
            sanctioned == 1,
            """
            DecodingError.refusing no longer builds exactly one .dataCorrupted. This is the \
            scan's positive control: without it the check above passes whenever the needles \
            stop matching anything at all.
            """)
    }

    /// No case carries a value, and no case's sentence interpolates one.
    ///
    /// `FanReading.init(from:)` threw `"a fan reading must be finite, got \(value)"` until
    /// #276, and only the flattening being replaced here kept that value out of a root
    /// daemon's log. Since #276 the case's own text *is* the wire text, so this is the
    /// property that keeps the boundary honest.
    ///
    /// Two assertions, because banning interpolation alone is not enough — a review pointed
    /// out that a case with an associated value could render `"unknown sensor key " + key` and
    /// pass a `\(` scan while putting client text on the wire. Excluding associated values
    /// outright closes that: with nothing client-supplied in scope, concatenation can only
    /// append a constant.
    ///
    /// **The compiler gets there first, and the honest framing of the second assertion is
    /// that it guards the way *around* the compiler.** `CaseIterable` cannot be derived for an
    /// enum with associated values, so `case fanReadingNotFinite(Double)` alone does not
    /// build — verified by running it: *"type 'PayloadRefusal' does not conform to protocol
    /// 'CaseIterable'"*. What the assertion catches is the workaround: hand-writing
    /// `static var allCases` to keep the conformance while adding the value. That is a
    /// plausible thing for someone to do in good faith, having been stopped by the compiler
    /// and not knowing why the conformance was there.
    ///
    /// The interpolation scan is bounded to `description`'s own body rather than running to
    /// the end of the file, so a `\(` in the `DecodingError` extension below cannot fail this
    /// test with a message about a case that does not exist.
    ///
    /// **Mutation A:** `return "a fan reading is not finite: \(Double.nan)"`. Run: red on the
    /// interpolation assertion.
    /// **Mutation B:** `case fanReadingNotFinite(Double)`, the arm updated to match, a
    /// hand-written `allCases` restoring the conformance, and `Fan.swift`'s construction
    /// updated. Run: red on the associated-value assertion. Without the hand-written
    /// `allCases` it does not compile, which is the point above.
    @Test("Every refusal is a bare case, and its sentence is value-free")
    func everyRefusalIsValueFree() throws {
        for refusal in PayloadRefusal.allCases {
            #expect(refusal.description.isEmpty == false, "\(refusal) renders as nothing")
        }

        let body = Self.strippingComments(try Self.refusalSource())
        let declarations =
            body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
        #expect(declarations.isEmpty == false, "PayloadRefusal declares no cases")
        #expect(
            declarations.allSatisfy { !$0.contains("(") },
            """
            a PayloadRefusal case carries an associated value: \(declarations). Its \
            description is what crosses the privilege boundary, so a case with a value in \
            scope is one concatenation away from putting a client's bytes on the wire — \
            which a scan for interpolation would not see.
            """)

        let declaration = try #require(
            body.range(of: "public var description: String {"),
            "PayloadRefusal no longer declares `description`")
        let afterDeclaration = body[declaration.upperBound...]
        let close = afterDeclaration.range(of: "\n    }")
        let arms = String(afterDeclaration[..<(close?.lowerBound ?? afterDeclaration.endIndex)])
        #expect(
            arms.contains("\\(") == false,
            """
            a PayloadRefusal case interpolates a value into its description. That string is \
            what crosses the privilege boundary and what lands in a root daemon's log — see \
            the type's own doc comment, and the `got \\(value)` this replaced.
            """)
    }

    // MARK: - Source scanning

    /// `Sources`, located from this file rather than the working directory.
    ///
    /// `SeamScanner.sourcesRoot` walks up from `#filePath` the same way; this target cannot
    /// import it (it lives in `AeolusHelperTests`), so the walk is repeated rather than
    /// shared — `XPCDeclarationFingerprintTests` records the same reason.
    private static func swiftFilesUnderSourcesAndTools() throws -> [URL] {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/IntegrationTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
        // `Tools/` holds package targets of its own — PowerObserver and SMCSampler — so a
        // scan claiming to cover the project's sources has to walk it too.
        return ["Sources", "Tools"].flatMap { directory -> [URL] in
            let root = repository.appendingPathComponent(directory)
            guard
                let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil)
            else { return [] }
            return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
    }

    /// `PayloadRefusal.swift`'s text, for the two assertions made against the source.
    private static func refusalSource() throws -> String {
        let url = try #require(
            try swiftFilesUnderSourcesAndTools().first {
                $0.lastPathComponent == "PayloadRefusal.swift"
            },
            "PayloadRefusal.swift was not found")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Drops `//` comments, so the type's own doc comment naming the banned spelling does not
    /// fail the scan that bans it. Block comments are not used in this project's sources.
    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Comment-stripped source with whitespace before a `(` removed.
    ///
    /// `DecodingError.dataCorrupted (context)` is a legal call and would slip past a needle
    /// ending in `(`. Normalising rather than widening the needle keeps one spelling to
    /// reason about, and covers a newline before the parenthesis as well as a space.
    private static func callSpellings(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var pendingWhitespace = ""
        for character in strippingComments(source) {
            if character.isWhitespace {
                pendingWhitespace.append(character)
                continue
            }
            if character != "(" { out += pendingWhitespace }
            pendingWhitespace = ""
            out.append(character)
        }
        return out + pendingWhitespace
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }
}
