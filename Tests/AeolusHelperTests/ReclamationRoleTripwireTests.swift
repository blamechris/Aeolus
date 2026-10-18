import Foundation
import Testing

/// § 5 holds the lease core, § 3's latch and the ledger through three roles, `HeldLeaseRole`,
/// `ThermalLatchRole` and `ReclamationLedgerRole` (#357, #380), and each role is what narrows
/// what § 5 can do to that actor. That is a claim about what a protocol declares and how a file
/// reaches what it holds, which no behavioural test observes: a role widened to the whole actor
/// passes every scenario, because the scenarios call only what § 5 calls. So it is asserted
/// against the source, three ways:
///
/// - **Each role declares exactly the calls § 5 makes**, refines nothing but `Sendable`, and so
///   carries no write verb. `ThermalLatchRole` reads one bit; `ReclamationLedgerRole` records
///   and clears a fan's cause; `HeldLeaseRole` asks and revokes one lease.
/// - **Each role is named only where it is listed** (`RoleCensus`): its declaration, its one
///   conformer's conformance (the actor it was cut from, so what § 5 talks to in production is
///   that actor, #380's acceptance), and the watchdog's stored property and init parameter. An
///   extension is a member every existential gets, and one written there could convert the role
///   back to the actor and reach `release()` or `causes` through it; a refinement, a second
///   conformer and an alias do the same. Every one of them has to write the role's name, so none
///   can be spelled past a census as each could past a list of shapes: backticks, a module
///   qualifier and a line break after `=` were each green.
/// - **The watchdog reaches each role only through its members.** `latch as?
///   ThermalEmergencyLatch`, or `let held = latch` and then a conversion, is the route back to
///   the actor's whole surface, and neither is a member access.
///
/// `AuthorityRoleTripwireTests` is the same discipline for the panic verb's roles over the plane.
@Suite("§ 5's roles over the lease core, the latch and the ledger carry what it calls")
struct ReclamationRoleTripwireTests {

    /// One role: the path it is declared at under `Sources/`, its one conformer and the path that
    /// is declared at, the property the watchdog holds it as, and its body, whitespace-collapsed,
    /// exactly as declared.
    struct Role: Sendable, CustomStringConvertible {
        let name: String
        let path: String
        let conformer: String
        let conformerPath: String
        let property: String
        let body: String

        var description: String { name }
        var file: String { URL(fileURLWithPath: path).lastPathComponent }

        /// Every statement under `Sources/` that may write `name`: the declaration, the
        /// conformance, and the watchdog's stored property and init parameter (the second drops
        /// its modifier, as a parameter has none).
        var listings: [RoleCensus.Listing] {
            [
                RoleCensus.Listing(path: path, statement: "protocol \(name): Sendable"),
                RoleCensus.Listing(path: conformerPath, statement: "actor \(conformer): \(name)"),
                RoleCensus.Listing(
                    path: ReclamationRoleTripwireTests.watchdogPath,
                    statement: "let \(property): any \(name)"),
                RoleCensus.Listing(
                    path: ReclamationRoleTripwireTests.watchdogPath,
                    statement: "\(property): any \(name)"),
            ]
        }
    }

    static let roles: [Role] = [
        Role(
            name: "HeldLeaseRole", path: "AeolusHelper/Lease/HeldLeaseRole.swift",
            conformer: "LeaseAuthority", conformerPath: "AeolusHelper/Lease/LeaseAuthority.swift",
            property: "leases",
            body: """
                func hasLiveLease(id: UUID, coveringFan fan: Int) async -> Bool \
                func revokeLease(id: UUID, forFan fan: Int, because cause: FanRestoreCause) \
                async -> LeaseRevocation
                """),
        Role(
            name: "ThermalLatchRole", path: "AeolusHelper/Safety/ThermalLatchRole.swift",
            conformer: "ThermalEmergencyLatch",
            conformerPath: "AeolusHelper/Safety/ThermalEmergencyLatch.swift", property: "latch",
            body: "var isActive: Bool { get async }"),
        Role(
            name: "ReclamationLedgerRole",
            path: "AeolusHelper/Safety/ReclamationLedgerRole.swift",
            conformer: "ReclamationLedger",
            conformerPath: "AeolusHelper/Safety/ReclamationLedger.swift", property: "ledger",
            body: """
                func markReclaimed(fanAt index: Int) async -> Bool \
                @discardableResult func markSupervisorBlind(fanAt index: Int) async -> Bool \
                func clearReclaimed(fanAt index: Int) async -> Bool
                """),
    ]

    private static let watchdogPath = "AeolusHelper/Safety/ReclamationWatchdog.swift"
    private static let watchdogFile = "ReclamationWatchdog.swift"

    /// **Mutation:** add `var engagedBy: CriticalTemperature? { get async }` to `ThermalLatchRole`,
    /// with `var engagedBy: CriticalTemperature? { get async { await latch.engagedBy } }` on
    /// `ParkableThermalLatch` so the test target still builds. Run: red here, while every
    /// behavioural test stays green.
    @Test("Each role declares exactly the calls § 5 makes, and refines nothing", arguments: roles)
    func eachRoleDeclaresExactlyWhatSectionFiveCalls(role: Role) throws {
        let code = SeamScanner.strippingAllComments(
            try MemberAccessScan.strippedSource(of: role.file))
        let declaration = try #require(
            code.range(
                of: #"protocol \#(role.name)(?![A-Za-z0-9_])([^{]*)\{([\s\S]*?)\n\}"#,
                options: .regularExpression),
            "\(role.file) does not declare `protocol \(role.name)`")
        let text = String(code[declaration])
        let header = Self.collapsed(String(text[..<(text.firstIndex(of: "{") ?? text.endIndex)]))
        let open = try #require(text.firstIndex(of: "{"))
        let body = Self.collapsed(
            String(text[text.index(after: open)..<text.index(before: text.endIndex)]))

        #expect(
            header == "protocol \(role.name): Sendable",
            """
            `\(header)`: a role refines `Sendable` and nothing else. A refinement hands § 5 every \
            requirement of what it refines.
            """)
        #expect(
            body == role.body,
            """
            \(role.name) declares `\(body)`, and § 5 makes exactly `\(role.body)`. A role carries \
            the calls § 5 makes and no write verb; one more is one more thing § 5 can do to \
            \(role.conformer). Say why here, and in the role's documentation.
            """)
    }

    /// Every spelling of a role's name under `Sources/` is one of the listed statements, and every
    /// listed one is found. Comments and backticks are removed and newlines are whitespace, so
    /// `` extension `ReclamationLedgerRole` ``, `extension AeolusHelper.ReclamationLedgerRole` and
    /// a `typealias` broken after its `=` are the statements they look like.
    ///
    /// **Mutations (ten new files under `Sources/AeolusHelper/Safety/`, one per probe, built
    /// together):** a conformer ``struct `ProbeLatch`: ThermalLatchRole``; `extension
    /// AeolusHelper.ReclamationLedgerRole`; a backticked extension; `typealias LedgerView =` and
    /// then `ReclamationLedgerRole` on the next line, with `extension LedgerView {}`; a backticked
    /// alias and an actor conforming through it; and `typealias LatchView =`, then
    /// `ThermalLatchRole`, with `extension LatchView { var whole: ThermalEmergencyLatch? { self as?
    /// ThermalEmergencyLatch } }`; and the four plain spellings the earlier pattern list caught: an
    /// `extension`, a refinement, a `typealias` and a conformer. Run: red here with exactly those
    /// ten and nothing else, each at its own file and line (the name's: line 2 where an `=` ends
    /// line 1), and `Listed and not found` passing. The earlier pattern list, run against the same
    /// ten, caught the four plain ones and none of the six others.
    @Test("Each role is named under Sources only where it is listed")
    func eachRoleIsNamedOnlyWhereListed() throws {
        let found = try RoleCensus.occurrences(roles: Self.roles.map(\.name))
        let verdict = RoleCensus.reconcile(found, with: Self.roles.flatMap(\.listings))

        #expect(
            verdict.unlisted.isEmpty,
            """
            A role is named where it is not listed:\(Self.lines(verdict.unlisted))
            An extension, a refinement, a conformer, an alias or a cast has to write the name, and \
            each one widens what § 5 can do to the actor behind it. Say why here and in the \
            role's documentation.
            """)
        #expect(
            verdict.missing.isEmpty,
            """
            Listed and not found:\(Self.lines(verdict.missing))
            Either the role is no longer what § 5 holds there, or the statement is spelled \
            another way; the list is this test's to be told about.
            """)
    }

    /// Every use of the three properties in the watchdog's file is a member access, except the
    /// declaration, the initialiser's parameter and its assignment. Whitespace before the `.` is
    /// skipped and `.self` refused, as `ReclamationWatchdogAccessTests` does for `registry`.
    ///
    /// **Mutation:** in `currentRuling()`, bind `let held = latch` and ask `await held.isActive`.
    /// Run: red here.
    @Test("The watchdog reaches each role only through its members", arguments: roles)
    func theWatchdogReachesEachRoleOnlyThroughItsMembers(role: Role) throws {
        let code = SeamScanner.strippingAllComments(
            try MemberAccessScan.strippedSource(of: Self.watchdogFile))
        let uses = try NSRegularExpression(pattern: #"\b\#(role.property)\b"#)
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

        let type = "any \(role.name)"
        let assignment = "self.\(role.property) = \(role.property)"
        let expected = [
            "private let \(role.property): \(type)", "\(role.property): \(type),",
            assignment, assignment,
        ]
        #expect(
            wholeValueUses.sorted() == expected.sorted(),
            """
            `\(role.property)` is used as a whole value in \(Self.watchdogFile) beyond its \
            declaration and initialiser: \(wholeValueUses). A role passed on, bound or \
            converted is the route back to \(role.conformer)'s whole surface; reach it through \
            a member.
            """)
    }

    private static func lines(_ items: [some CustomStringConvertible]) -> String {
        items.map { "\n  \($0)" }.joined()
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
            .trimmingCharacters(in: .whitespaces)
    }
}
