import Foundation
import Testing

/// What level 6's file may name, and how it reaches what it holds (ADR 0014's A6 PR-2 amendment).
///
/// Claims about what a file names and a protocol declares, which no behavioural test observes: a
/// level 6 that held a `SafetyActorWriter`, or a role widened to the whole watchdog, passes every
/// scenario, because the scenarios call only what level 6 calls. So they are asserted against the
/// source, by census (`RoleCensus`, #402) rather than by a list of forbidden shapes:
///
/// - **The level-6 file never names `SafetyActorWriter`.** Its driver holds one and exposes no
///   target verb; naming the type here is the one way level 6 could hold a target verb that § 8
///   does not shape.
/// - **`ReclamationRegistrationRole` is named only where it is listed,** and declares exactly the
///   three calls level 6 makes on § 5.
/// - **Level 6 reaches its engaged set only through its transitions,** so no copy of it is carried
///   across an `await`.
///
/// Where the gate may be named and entered, level 6's file included, is
/// `ExaminationGateRouteTests`; the route to the driver's step verb is
/// `EngagementRouteTripwireTests` and `EngagementDriverTests.onlyTheDriverEngages`; level 6's
/// verbs are in
/// `WriteVerbAllowlistTests`.
@Suite("What level 6's file names, and how it reaches it")
struct LeaseApplierTripwireTests {

    static let levelSixPath = "AeolusHelper/Control/LeaseApplier.swift"
    static let levelSixFile = "LeaseApplier.swift"
    static let rolePath = "AeolusHelper/Safety/ReclamationRegistrationRole.swift"
    static let roleFile = "ReclamationRegistrationRole.swift"
    static let watchdogPath = "AeolusHelper/Safety/ReclamationWatchdog.swift"

    /// **Mutation:** add `private let spare: SafetyActorWriter<Plane>? = nil` to `LeaseApplier`.
    /// Run: red here, at the level-6 file.
    @Test("The level-6 file never names SafetyActorWriter")
    func theLevelSixFileNamesNoSafetyActorWriter() throws {
        let found = try RoleCensus.occurrences(roles: ["SafetyActorWriter"])
        #expect(
            found.contains { $0.path == "AeolusHelper/Safety/SafetyWriters.swift" },
            "the census found no SafetyActorWriter anywhere, so the assertion below is vacuous")
        let inLevelSix = found.filter { $0.path == Self.levelSixPath }
        #expect(
            inLevelSix.isEmpty,
            """
            \(Self.levelSixFile) names `SafetyActorWriter`:\(Self.lines(inLevelSix))
            Level 6 writes targets through `GovernedFanWriter` alone; its driver holds the \
            ungoverned writer for the engagement and the undo, and exposes no target verb.
            """)
    }

    /// Every statement under `Sources/` that may write the role's name: its declaration, the
    /// watchdog's conformance, and level 6's stored property and init parameter.
    static let roleListings = [
        RoleCensus.Listing(
            path: rolePath, statement: "protocol ReclamationRegistrationRole: Actor"),
        RoleCensus.Listing(
            path: watchdogPath,
            statement:
                "actor ReclamationWatchdog<Plane: FanControlPlane>: ReclamationRegistrationRole"),
        RoleCensus.Listing(
            path: levelSixPath, statement: "let reclamation: any ReclamationRegistrationRole"),
        RoleCensus.Listing(
            path: levelSixPath, statement: "reclamation: any ReclamationRegistrationRole"),
    ]

    /// **Mutation:** add `extension ReclamationRegistrationRole { func probe() {} }` to
    /// `LeaseApplier.swift`. Run: red here, at that line.
    @Test("The role level 6 tells § 5 through is named only where it is listed")
    func theRoleIsNamedOnlyWhereListed() throws {
        let verdict = RoleCensus.reconcile(
            try RoleCensus.occurrences(roles: ["ReclamationRegistrationRole"]),
            with: Self.roleListings)
        #expect(
            verdict.unlisted.isEmpty,
            """
            The role is named where it is not listed:\(Self.lines(verdict.unlisted))
            An extension, a refinement, a conformer, an alias or a cast widens what level 6 can do \
            to § 5. Say why here and in the role's documentation.
            """)
        #expect(
            verdict.missing.isEmpty,
            "Listed and not found:\(Self.lines(verdict.missing))")
    }

    /// **Mutation:** add `func cycle() async` to the role. Run: red here.
    @Test("The role declares exactly the three calls level 6 makes, and refines only Actor")
    func theRoleDeclaresExactlyLevelSixsCalls() throws {
        let code = SeamScanner.strippingAllComments(
            try MemberAccessScan.strippedSource(of: Self.roleFile))
        let declaration = try #require(
            code.range(
                of: #"protocol ReclamationRegistrationRole(?![A-Za-z0-9_])[^{]*\{[\s\S]*?\n\}"#,
                options: .regularExpression),
            "\(Self.roleFile) does not declare the role")
        let text = String(code[declaration])
        let open = try #require(text.firstIndex(of: "{"))
        let header = SeamScanner.collapsingWhitespace(String(text[..<open]))
        let body = SeamScanner.collapsingWhitespace(
            String(text[text.index(after: open)..<text.index(before: text.endIndex)]))

        #expect(header == "protocol ReclamationRegistrationRole: Actor")
        #expect(
            body
                == """
                func manualControlEngaged(_ fan: CommandableFan, under lease: UUID) async throws \
                func commandedTarget(_ commanded: CommandedTarget, under lease: UUID) \
                func manualControlHandedBack(fanAt index: Int, under lease: UUID) async
                """,
            "the role declares `\(body)`")
    }

    /// Every use of `engagements` in level 6's file is a member access, except its declaration.
    ///
    /// **Mutation:** in `LeaseApplier.step`, bind `let before = engagements` and ask
    /// `before.contains(index, under: lease)`. Run: red here.
    @Test("Level 6 reaches its engaged set only through its members")
    func levelSixReachesItsEngagedSetOnlyThroughItsMembers() throws {
        let code = SeamScanner.strippingAllComments(
            try MemberAccessScan.strippedSource(of: Self.levelSixFile))
        let uses = try NSRegularExpression(pattern: #"\bengagements\b"#)
        var wholeValueUses: [String] = []
        for match in uses.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let found = Range(match.range, in: code) else { continue }
            let after = code[found.upperBound...].drop { $0 == " " || $0 == "\n" }
            let member = after.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if after.first == ".", member != "self" { continue }
            let lineStart = code[..<found.lowerBound].lastIndex(of: "\n") ?? code.startIndex
            let lineEnd = code[found.upperBound...].firstIndex(of: "\n") ?? code.endIndex
            wholeValueUses.append(
                code[lineStart..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #expect(
            wholeValueUses == ["private var engagements = LeaseEngagements()"],
            "`engagements` is used as a whole value: \(wholeValueUses)")
    }

    private static func lines(_ items: [some CustomStringConvertible]) -> String {
        items.map { "\n  \($0)" }.joined()
    }
}
