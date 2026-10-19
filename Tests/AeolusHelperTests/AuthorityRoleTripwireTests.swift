import Foundation
import Testing

@testable import AeolusHelper

/// `SupervisedFanAuthority` holds two narrow roles of the plane — `KeystoneRestoring` and
/// `FanWriteCapabilityReporting` — beside the sightedness cache's read role (#269), level 6's
/// `LeaseApplying` (ADR 0014's A6 PR-3 amendment) and § 5's `ReclamationReporting`, one getter for
/// the snapshot's target (ADR 0014's #410 snapshot-target amendment), and nothing that can command
/// a fan
/// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D5). That is a
/// claim about what a type *holds* and what its file can *name*, which no behavioural test
/// observes: a whole plane behind a restore-only body restores exactly as the role does. So it is
/// asserted against the source, three ways, and each was evaded once before it took its present
/// shape (the review and delta review of #349). `PanicPathScopeTripwireTests` holds what the panic
/// verb *calls*.
///
/// The conversion ban binds the lease core's files too, since `LeaseAuthority` holds `envelopes`
/// as an existential over the plane (#270): `theLeaseCoreConvertsNoRole`.
@Suite("The panic verb's type holds its narrow roles, and nothing wider")
struct AuthorityRoleTripwireTests {

    /// `SupervisedFanAuthority.swift` names no plane, no writer that can command a fan, no
    /// permit and no forward write verb, and converts no value's type.
    ///
    /// Type names are matched as identifiers, qualified or not, through
    /// `WatchdogTripwireTests.mentions(of:in:)`, whose own fixtures cover that scan; the verbs
    /// are matched as text, because they arrive as member accesses that scan deliberately
    /// skips. A denylist sees only the names it knows, which is why the two tests below exist.
    ///
    /// **Mutation:** type `keystone` and its initialiser parameter as `any FanControlPlane` /
    /// `some FanControlPlane`, the composition passing `plane`. Run: red on `FanControlPlane`
    /// and on the coverage line — while every behavioural test stays green.
    /// **Mutation:** add `private func widen() { if case let wider as any
    /// FanWriteCapabilityReporting = keystone { _ = wider } }`. Run: red on the conversion ban.
    @Test("The panic verb's type holds the keystone and the capability, and no plane")
    func theAuthorityHoldsNoPlane() throws {
        let code = try Self.authoritySource()

        // Coverage: the plane's two roles and level 6's are named, so the scan below is reading
        // the file that holds them rather than an empty one.
        #expect(code.contains("any KeystoneRestoring"), "the keystone role is not held")
        #expect(
            code.contains("any FanWriteCapabilityReporting"), "the capability role is not held")
        #expect(code.contains("any LeaseApplying"), "level 6's role is not held")
        #expect(code.contains("any ReclamationReporting"), "§ 5's reporting role is not held")

        let types = try WatchdogTripwireTests.mentions(
            of: [
                "FanControlPlane", "SMCFanControlPlane", "FanStateSensing", "SafetyActorWriter",
                "GovernedFanWriter", "CommandableFan", "AuthorisedFanTarget", "FanTargetRPM",
                "SMCConnection",
            ],
            in: code)
        let verbs = try [
            "commandTarget", "engageManualControl", "commandMaximum", "bridgeThenRestore",
            "bridgeToMaximumThenRestore", #"\bcommand\s*\("#,
        ].filter { try !Self.matches(of: $0, in: code).isEmpty }
        #expect(
            types.isEmpty && verbs.isEmpty,
            """
            SupervisedFanAuthority.swift names \(types + verbs). It is where a decoded client \
            message lands, and it may hold the keystone and the capability and nothing that \
            commands a fan — the shape E2 froze this boundary to (ADR 0014 D5).
            """)

        // A role held as an existential can be converted back to what it wraps, and the
        // conversion need not name a type the denylist knows: `keystone as? SomeAlias`, or
        // `if case let wider as any SomeProtocol = keystone`. The file has no `as` today, so the
        // token itself is refused, along with the two conversions that do not spell it.
        let conversions = try Self.conversions(in: code)
        #expect(
            conversions.isEmpty,
            "SupervisedFanAuthority.swift converts a value's type with \(conversions)")
    }

    /// The lease core's files convert no value's type, outside a `catch` clause's error binding
    /// ([#270](https://github.com/blamechris/Aeolus/issues/270)).
    ///
    /// `LeaseAuthority` holds `envelopes` as `any FanEnvelopeReading`, which in production is the
    /// plane itself (`envelopes: plane`), as `writeCapability` is. One conversion back hands the
    /// lease core `commandTarget(_:)` while every behavioural test stays green, and
    /// `LeaseAuthorityAccessTests.theLeaseCoreMintsNoPermit` sees only `commandable`. So these
    /// files take the ban above. The one shape exempt is `catch let <name> as <Type> {`, which
    /// binds a thrown error and converts no role. Comments are stripped and literals kept.
    ///
    /// **Mutation:** add `if case let wider as any FanControlPlane = envelopes { _ = wider }` to
    /// `refuseIfBoundsImplausible(_:wanting:)`. Run: red here, while every behavioural test stays
    /// green.
    @Test("The lease core converts no role it holds back to the plane")
    func theLeaseCoreConvertsNoRole() throws {
        let named = try SeamScanner.swiftFiles(under: "AeolusHelper").map(\.lastPathComponent)
            .filter { $0.hasPrefix("LeaseAuthority") && $0.hasSuffix(".swift") }
        let files = try Set(named).union(
            MemberAccessScan.filesDeclaring("LeaseAuthority", inTarget: "AeolusHelper").members
        ).sorted()
        let errorBinding = try NSRegularExpression(pattern: #"\bcatch\s+let\s+\w+\s+as\s+\w+\s*\{"#)

        var held = ""
        var offences: [String] = []
        for file in files {
            let code = SeamScanner.strippingAllComments(
                try MemberAccessScan.strippedSource(of: file))
            held += code
            let converting = errorBinding.stringByReplacingMatches(
                in: code, range: NSRange(code.startIndex..., in: code), withTemplate: "")
            offences += try Self.conversions(in: converting).map { "\(file): \($0)" }
        }
        // Coverage: the scan read the files that hold the role, not an empty set.
        #expect(files.contains("LeaseAuthorityRefusals.swift"), "the scan covers \(files)")
        #expect(held.contains("any FanEnvelopeReading"), "the envelope role is not held")
        #expect(
            offences.isEmpty,
            """
            \(offences): the lease core converts a value's type. It holds narrow roles so that it \
            cannot command a fan, and a conversion back to the plane undoes exactly that.
            """)
    }

    /// The authority's file declares exactly these `let`/`var` lines outside function bodies,
    /// and no type but the authority itself.
    ///
    /// The denylist above names types, so a name it does not know evades it:
    /// `typealias WholePlane = any FanControlPlane` in another file, then a stored
    /// `WholePlane` here, read as clean (the review of #349). So did this test's first form,
    /// which matched only lines **starting** with a short list of modifiers: `private(set) var`,
    /// `nonisolated(unsafe)` and `@usableFromInline let` all walked past it, and a `static let`
    /// inside a nested `private enum` sat at a depth it never read (the delta review of #349).
    ///
    /// What it guarantees now: **every** line at the file's top level or at the type's own depth
    /// that contains the word `let` or `var`, whatever precedes it, must be one of the
    /// declarations below, whole and whitespace-collapsed — so a stored property of any new
    /// name, any new type or any new modifier fails. And the file may declare no type,
    /// extension or protocol but `struct SupervisedFanAuthority`, so there is no deeper level
    /// for a declaration to hide in. What it cannot see: storage a macro or a property wrapper
    /// synthesises, and a value reached without being stored here (a global elsewhere). The
    /// denylist's verbs, the conversion ban and `nothingInSourcesAliasesAWiderRole` narrow
    /// those.
    ///
    /// **Mutation:** add `private(set) var plane: (any KeystoneRestoring)? = nil`, or
    /// `@usableFromInline let probe = 0`, or `nonisolated(unsafe) static var probe = 0`, to
    /// `SupervisedFanAuthority`. Run: red here. **Mutation:** add
    /// `private enum Hidden { static let probe = 0 }` inside it. Run: red here, on the type count.
    /// **Mutation:** remove `reclamation` from `allowed` (#410). Run: red here.
    @Test("The panic verb's file declares exactly its allowed properties, and no other type")
    func theAuthorityStoresOnlyItsAllowedProperties() throws {
        let allowed: Set<String> = [
            "private let reading: ReadOnlyFanAuthority",
            "private let leases: LeaseAuthority",
            "private let reconciliation: any ReconciliationBaselineReporting",
            "private let keystone: any KeystoneRestoring",
            "private let writeCapability: any FanWriteCapabilityReporting",
            "private let telemetry: any SightednessProving",
            "private let control: any LeaseApplying",
            "private let reclamation: any ReclamationReporting",
            "let controlGate = ControlMessageGate()",
            "private let log: HelperLog",
            "private static let shuttingDown = AeolusXPCFault.helperFailed(",
        ]
        let code = try Self.authoritySource()
        let declared = Self.storedDeclarations(in: code)

        // Coverage: a scan that found nothing would pass the comparison below vacuously.
        #expect(declared.contains("private let keystone: any KeystoneRestoring"))
        #expect(
            Set(declared) == allowed && declared.count == allowed.count,
            """
            SupervisedFanAuthority.swift declares \(declared.sorted()), not \
            \(allowed.sorted()). It may hold the keystone and the capability and nothing that \
            can command a fan (ADR 0014 D5). Every site below describes what it holds:
            \(PanicPathScopeTripwireTests.checklist)
            """)

        let types = try Self.matches(
            of: #"\b(enum|struct|class|actor|protocol|extension)\s+\w+"#, in: code)
        #expect(
            types == ["struct SupervisedFanAuthority"],
            "SupervisedFanAuthority.swift declares \(types); a nested type is a place to hide")
    }

    /// Nothing under `Sources/` gives a wider role a second name, or widens the two roles.
    ///
    /// The allowlist above holds `SupervisedFanAuthority.swift`; this holds the names that file
    /// could import. Three spellings, each of which reaches the plane without the word:
    ///
    /// - a `typealias` whose right-hand side names the plane, its read half, or a writer that
    ///   can command a fan;
    /// - a `protocol` refining one of those — `protocol WholePlane: FanControlPlane {}` — other
    ///   than `FanControlPlane`'s own declaration, which refines `FanStateSensing` (the delta
    ///   review of #349);
    /// - an `extension` of `KeystoneRestoring` or `FanWriteCapabilityReporting`, which would add
    ///   members to the very roles the authority is handed.
    ///
    /// **Mutation:** add `typealias WholePlane = any FanControlPlane`,
    /// `protocol WholePlane: FanControlPlane {}`, or
    /// `extension KeystoneRestoring { func probe() {} }` to `FanAuthority.swift`. Run: red here.
    @Test("Nothing in Sources renames the plane or a commanding writer, or widens the roles")
    func nothingInSourcesAliasesAWiderRole() throws {
        let wider =
            #"(SMCFanControlPlane|FanControlPlane|FanStateSensing|SafetyActorWriter|"#
            + #"GovernedFanWriter)"#
        let alias = #"typealias\s+\w+[^=\n]*=[^\n]*\b"# + wider + #"\b"#
        let refinement = #"protocol\s+\w+[^{:]*:[^{]*\b"# + wider + #"\b"#
        let widening = #"extension\s+(KeystoneRestoring|FanWriteCapabilityReporting)\b"#

        var offences: [String] = []
        for file in try SeamScanner.swiftFiles() {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            let found =
                try Self.matches(of: alias, in: code)
                + Self.matches(of: refinement, in: code).filter {
                    !$0.hasPrefix("protocol FanControlPlane:")
                }
                + Self.matches(of: widening, in: code)
            offences += found.map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(
            offences.isEmpty,
            "\(offences) name the plane or a commanding writer anew, or widen a role")
    }

    // MARK: - § 5's reporting role

    /// Every statement under `Sources/` that may write the snapshot's role over § 5: its
    /// declaration, the watchdog's conformance, and the authority's stored property and init
    /// parameter (`RoleCensus`, #402).
    static let reportingListings = [
        RoleCensus.Listing(path: reportingPath, statement: "protocol ReclamationReporting: Actor"),
        RoleCensus.Listing(
            path: reportingPath, statement: "extension ReclamationWatchdog: ReclamationReporting"),
        RoleCensus.Listing(
            path: authorityPath, statement: "let reclamation: any ReclamationReporting"),
        RoleCensus.Listing(
            path: authorityPath, statement: "reclamation: some ReclamationReporting"),
    ]

    static let reportingPath = "AeolusHelper/Safety/ReclamationReporting.swift"
    static let authorityPath = "AeolusHelper/SupervisedFanAuthority.swift"

    /// The role the authority holds § 5 as declares one synchronous getter and no verb, refines
    /// only `Actor`, and is named only where it is listed (ADR 0014's #410 snapshot-target
    /// amendment). A second requirement, an extension, a refinement, a conformer or an alias is
    /// one more thing a decoded client message is one `await` from doing to § 5.
    ///
    /// **Mutation:** add `func cycle() async` to the role. Run: red on the body. **Mutation:** add
    /// `extension ReclamationReporting { func probe() {} }` to `FanAuthority.swift`. Run: red on
    /// the census, at that line.
    @Test("§ 5's reporting role declares one getter and is named only where it is listed")
    func theReportingRoleDeclaresOneGetterAndIsNamedOnlyWhereListed() throws {
        let code = SeamScanner.strippingAllComments(
            try MemberAccessScan.strippedSource(of: "ReclamationReporting.swift"))
        let declaration = try #require(
            code.range(
                of: #"protocol ReclamationReporting(?![A-Za-z0-9_])[^{]*\{[\s\S]*?\n\}"#,
                options: .regularExpression),
            "ReclamationReporting.swift does not declare the role")
        let text = String(code[declaration])
        let open = try #require(text.firstIndex(of: "{"))
        let header = SeamScanner.collapsingWhitespace(String(text[..<open]))
        let body = SeamScanner.collapsingWhitespace(
            String(text[text.index(after: open)..<text.index(before: text.endIndex)]))
        #expect(header == "protocol ReclamationReporting: Actor")
        #expect(
            body == "func recordedTargets(under lease: UUID) -> [Int: Double]",
            "the role declares `\(body)`; it carries one synchronous getter and no verb")

        let verdict = RoleCensus.reconcile(
            try RoleCensus.occurrences(roles: ["ReclamationReporting"]),
            with: Self.reportingListings)
        #expect(
            verdict.unlisted.isEmpty,
            """
            § 5's reporting role is named where it is not listed:\(Self.lines(verdict.unlisted))
            An extension, a refinement, a conformer, an alias or a cast widens what the authority \
            can do to § 5. Say why here and in the role's documentation.
            """)
        #expect(verdict.missing.isEmpty, "Listed and not found:\(Self.lines(verdict.missing))")
    }

    private static func lines(_ items: [some CustomStringConvertible]) -> String {
        items.map { "\n  \($0)" }.joined()
    }

    // MARK: - Parsing

    /// Which of the three spellings of a type conversion `code` contains.
    private static func conversions(in code: String) throws -> [String] {
        try [#"\bas\b"#, #"\bunsafeBitCast\b"#, #"\bunsafeDowncast\b"#]
            .filter { try !Self.matches(of: $0, in: code).isEmpty }
    }

    private static func authoritySource() throws -> String {
        let url = try #require(
            try SeamScanner.swiftFiles().first {
                $0.lastPathComponent == "SupervisedFanAuthority.swift"
            })
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// Every line outside a function body that contains the word `let` or `var`, whatever
    /// precedes it: the text at brace depth 0 and 1, whitespace collapsed. A declaration split
    /// across lines is caught by whichever of its lines carries the keyword.
    private static func storedDeclarations(in code: String) -> [String] {
        var shallow = ""
        var depth = 0
        for character in code {
            if character == "{" { depth += 1 }
            if depth <= 1, character != "{", character != "}" { shallow.append(character) }
            if character == "}" { depth -= 1 }
        }
        return shallow.split(separator: "\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { $0.range(of: #"\b(let|var)\b"#, options: .regularExpression) != nil }
    }

    /// Every match of `pattern` in `code`, as text. `internal` for
    /// `LeaseBindingRaceTests.nothingSuspendsBelowTheMarker`, rather than a second copy.
    static func matches(of pattern: String, in code: String) throws -> [String] {
        try NSRegularExpression(pattern: pattern)
            .matches(in: code, range: NSRange(code.startIndex..., in: code))
            .compactMap { Range($0.range, in: code).map { String(code[$0]) } }
    }
}
