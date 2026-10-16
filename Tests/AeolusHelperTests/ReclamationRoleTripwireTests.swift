import Foundation
import Testing

/// § 5 holds the lease core, § 3's latch and the ledger through three roles, `HeldLeaseRole`,
/// `ThermalLatchRole` and `ReclamationLedgerRole` (#357, #380), and each role is what narrows
/// what § 5 can do to that actor. That is a claim about what a protocol declares and how a file
/// reaches what it holds, which no behavioural test observes: a role widened to the whole actor
/// passes every scenario, because the scenarios call only what § 5 calls. So it is asserted
/// against the source, four ways:
///
/// - **Each role declares exactly the calls § 5 makes**, refines nothing but `Sendable`, and so
///   carries no write verb. `ThermalLatchRole` reads one bit; `ReclamationLedgerRole` records
///   and clears a fan's cause; `HeldLeaseRole` asks and revokes one lease.
/// - **No role is extended, refined or renamed** anywhere under `Sources/`. An extension is a
///   member every existential gets, and one written there could convert the role back to the
///   actor and reach `release()` or `causes` through it.
/// - **Each role has its one conformer**, the actor it was cut from, so what § 5 talks to in
///   production is that actor (#380's acceptance).
/// - **The watchdog reaches each role only through its members.** `latch as?
///   ThermalEmergencyLatch`, or `let held = latch` and then a conversion, is the route back to
///   the actor's whole surface, and neither is a member access.
///
/// `AuthorityRoleTripwireTests` is the same discipline for the panic verb's roles over the plane.
@Suite("§ 5's roles over the lease core, the latch and the ledger carry what it calls")
struct ReclamationRoleTripwireTests {

    /// One role: the file it is declared in, its one conformer in `Sources/`, the property the
    /// watchdog holds it as, and its body, whitespace-collapsed, exactly as declared.
    struct Role: Sendable, CustomStringConvertible {
        let name: String
        let file: String
        let conformer: String
        let property: String
        let body: String

        var description: String { name }
    }

    static let roles: [Role] = [
        Role(
            name: "HeldLeaseRole", file: "HeldLeaseRole.swift", conformer: "LeaseAuthority",
            property: "leases",
            body: """
                func hasLiveLease(id: UUID, coveringFan fan: Int) async -> Bool \
                func revokeLease(id: UUID, forFan fan: Int, because cause: FanRestoreCause) \
                async -> LeaseRevocation
                """),
        Role(
            name: "ThermalLatchRole", file: "ThermalLatchRole.swift",
            conformer: "ThermalEmergencyLatch", property: "latch",
            body: "var isActive: Bool { get async }"),
        Role(
            name: "ReclamationLedgerRole", file: "ReclamationLedgerRole.swift",
            conformer: "ReclamationLedger", property: "ledger",
            body: """
                func markReclaimed(fanAt index: Int) async -> Bool \
                @discardableResult func markSupervisorBlind(fanAt index: Int) async -> Bool \
                func clearReclaimed(fanAt index: Int) async -> Bool
                """),
    ]

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

    /// **Mutation:** add `extension ReclamationLedgerRole { func probe() {} }` to
    /// `ReclamationLedgerRole.swift`. Run: red here.
    @Test("No role is extended, refined or renamed under Sources")
    func noRoleIsExtendedRefinedOrRenamed() throws {
        let names = Self.roles.map(\.name).joined(separator: "|")
        let patterns = [
            #"\bextension\s+(\#(names))\b"#,
            #"\bprotocol\s+\w+[^{:]*:[^{]*\b(\#(names))\b"#,
            #"\btypealias\s+\w+[^=\n]*=[^\n]*\b(\#(names))\b"#,
        ]
        var offences: [String] = []
        for file in try SeamScanner.swiftFiles() {
            let code = SeamScanner.strippingAllComments(
                try String(contentsOf: file, encoding: .utf8))
            for pattern in patterns {
                offences += try AuthorityRoleTripwireTests.matches(of: pattern, in: code)
                    .map { "\(file.lastPathComponent): \($0)" }
            }
        }
        #expect(
            offences.isEmpty,
            "\(offences) widen or rename one of § 5's roles, which is a way past their exact bodies"
        )
    }

    /// **Mutation:** add `struct ProbeLatch: ThermalLatchRole { var isActive: Bool { false } }` to
    /// `ThermalLatchRole.swift`. Run: red here.
    @Test("Each role has one conformer under Sources: the actor it narrows", arguments: roles)
    func eachRoleHasItsOneConformer(role: Role) throws {
        let conforming = try NSRegularExpression(
            pattern:
                #"\b(?:actor|class|struct|enum|extension)\s+(\w+)[^{]*?:[^{]*\b\#(role.name)\b"#)
        var conformers: [String] = []
        for file in try SeamScanner.swiftFiles() {
            let code = SeamScanner.strippingAllComments(
                try String(contentsOf: file, encoding: .utf8))
            let whole = NSRange(code.startIndex..., in: code)
            for match in conforming.matches(in: code, range: whole) {
                if let name = Range(match.range(at: 1), in: code) {
                    conformers.append(String(code[name]))
                }
            }
        }
        #expect(
            conformers == [role.conformer],
            """
            \(role.name) is conformed to by \(conformers) under Sources, and its one conformer \
            is \(role.conformer). What § 5 holds through the role in production is that actor.
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

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
            .trimmingCharacters(in: .whitespaces)
    }
}
