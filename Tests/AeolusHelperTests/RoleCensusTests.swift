import Testing

/// `RoleCensus` against fixtures rather than against the tree it scans.
///
/// A census exercised only through `Sources` is exercised only for the spellings already written
/// there, and those are the listed ones. Every shape that follows was green under the pattern list
/// `ReclamationRoleTripwireTests` had first, or is the plain shape that list caught; each is
/// asserted here to come out as the statement it is, with the line it is on, so that
/// `eachRoleIsNamedOnlyWhereListed` has something to compare with a list.
@Suite("The role census reads every spelling of a role as the statement it is")
struct RoleCensusTests {

    private static let roles = ["HeldLeaseRole", "ThermalLatchRole", "ReclamationLedgerRole"]

    struct Spelling: Sendable, CustomStringConvertible {
        let name: String
        let source: String
        /// `line: statement`, in order.
        let found: [String]

        var description: String { name }
    }

    private static func census(_ source: String, path: String = "Fixture.swift") -> [String] {
        RoleCensus.occurrences(inSource: source, path: path, roles: roles)
            .map { "\($0.line): \($0.statement)" }
    }

    static let spellings: [Spelling] = [
        Spelling(
            name: "a plain extension",
            source: "extension ReclamationLedgerRole {\n    func probe() {}\n}",
            found: ["1: extension ReclamationLedgerRole"]),
        Spelling(
            name: "a plain refinement",
            source: "protocol Wider: ThermalLatchRole {}",
            found: ["1: protocol Wider: ThermalLatchRole"]),
        Spelling(
            name: "a plain typealias",
            source: "typealias LeaseView = HeldLeaseRole",
            found: ["1: typealias LeaseView = HeldLeaseRole"]),
        Spelling(
            name: "a plain conformer",
            source: "struct ProbeLatch: ThermalLatchRole {\n    var isActive: Bool { false }\n}",
            found: ["1: struct ProbeLatch: ThermalLatchRole"]),
        Spelling(
            name: "a backticked conformer",
            source: "struct `ProbeLatch`: ThermalLatchRole {}",
            found: ["1: struct ProbeLatch: ThermalLatchRole"]),
        Spelling(
            name: "a module-qualified extension",
            source: "extension AeolusHelper.ReclamationLedgerRole {}",
            found: ["1: extension AeolusHelper.ReclamationLedgerRole"]),
        Spelling(
            name: "a backticked extension",
            source: "extension `ReclamationLedgerRole` {}",
            found: ["1: extension ReclamationLedgerRole"]),
        Spelling(
            name: "a typealias broken after its equals sign",
            source: "typealias LedgerView =\n    ReclamationLedgerRole\n\nextension LedgerView {}",
            found: ["2: typealias LedgerView = ReclamationLedgerRole"]),
        Spelling(
            name: "a backticked alias, which a conformer then names instead of the role",
            source: "typealias `LedgerView` = ReclamationLedgerRole\n\nactor Probe: LedgerView {}",
            found: ["1: typealias LedgerView = ReclamationLedgerRole"]),
        Spelling(
            name: "an alias that gives back the actor",
            source: """
                typealias LatchView =
                    ThermalLatchRole

                extension LatchView {
                    var whole: ThermalEmergencyLatch? { self as? ThermalEmergencyLatch }
                }
                """,
            found: ["2: typealias LatchView = ThermalLatchRole"]),
        Spelling(
            name: "a binding and a cast",
            source: "let held = latch as? any ThermalLatchRole",
            found: ["1: let held = latch as? any ThermalLatchRole"]),
        Spelling(
            name: "a generic constraint",
            source: "func probe<T: HeldLeaseRole>(_ value: T) {}",
            found: ["1: func probe<T: HeldLeaseRole>"]),
        Spelling(
            name: "a composition, which names each of its roles",
            source: "typealias Both = HeldLeaseRole & ThermalLatchRole",
            found: [
                "1: typealias Both = HeldLeaseRole & ThermalLatchRole",
                "1: typealias Both = HeldLeaseRole & ThermalLatchRole",
            ]),
    ]

    @Test("Every spelling is a statement the census can list", arguments: spellings)
    func everySpellingIsAStatement(spelling: Spelling) {
        #expect(Self.census(spelling.source) == spelling.found)
    }

    @Test("Against an empty list every spelling is unlisted", arguments: spellings)
    func everySpellingIsUnlistedAgainstAnEmptyList(spelling: Spelling) {
        let found = RoleCensus.occurrences(
            inSource: spelling.source, path: "Fixture.swift", roles: Self.roles)
        let verdict = RoleCensus.reconcile(found, with: [])

        #expect(verdict.unlisted.count == spelling.found.count)
        #expect(verdict.unlisted.allSatisfy { $0.path == "Fixture.swift" && $0.line >= 1 })
    }

    @Test("Comments hold no spelling, and a line number counts the lines they take")
    func commentsHoldNoSpellingAndKeepTheirLines() {
        let source = """
            /// ThermalLatchRole in a doc comment.
            /// HeldLeaseRole again.
            // ReclamationLedgerRole in a line comment.
            /* ThermalLatchRole
               in a block comment */
            struct Probe: ThermalLatchRole {}  // HeldLeaseRole, trailing
            """

        #expect(Self.census(source) == ["6: struct Probe: ThermalLatchRole"])
    }

    @Test("A longer identifier is not a role")
    func aLongerIdentifierIsNotARole() {
        let source = """
            struct ThermalLatchRoleBox {}
            let hasThermalLatchRole = 1
            let x_HeldLeaseRole = 2
            """

        #expect(Self.census(source).isEmpty)
    }

    @Test("A property, a parameter, a declaration and a conformance are read as listed")
    func theListedShapesAreReadAsListed() {
        let watchdog = """
            final class Watchdog {
                /// Doc for leases.
                private let leases: any HeldLeaseRole

                private let latch: any ThermalLatchRole

                init(
                    leases: any HeldLeaseRole,
                    latch: any ThermalLatchRole,
                    log: SafetyLog = SafetyLog()
                ) {
                    self.leases = leases
                }
            }
            """
        let declarations = """
            protocol HeldLeaseRole: Sendable {
                func hasLiveLease(id: UUID) async -> Bool
            }

            actor LeaseAuthority: HeldLeaseRole {}
            """

        #expect(
            Self.census(watchdog) == [
                "3: let leases: any HeldLeaseRole", "5: let latch: any ThermalLatchRole",
                "8: leases: any HeldLeaseRole", "9: latch: any ThermalLatchRole",
            ])
        #expect(
            Self.census(declarations) == [
                "1: protocol HeldLeaseRole: Sendable", "5: actor LeaseAuthority: HeldLeaseRole",
            ])
    }

    @Test("A listed statement is used up once, and is the listed file's alone")
    func reconcilingUsesUpEachListedStatementOnce() {
        let listed = [
            RoleCensus.Listing(path: "A.swift", statement: "let latch: any ThermalLatchRole"),
            RoleCensus.Listing(path: "A.swift", statement: "latch: any ThermalLatchRole"),
        ]
        let source = """
            final class Watchdog {
                private let latch: any ThermalLatchRole
                init(latch: any ThermalLatchRole) {}
            }
            """
        func verdict(_ source: String, path: String) -> RoleCensus.Verdict {
            RoleCensus.reconcile(
                RoleCensus.occurrences(inSource: source, path: path, roles: Self.roles),
                with: listed)
        }

        let exact = verdict(source, path: "A.swift")
        #expect(exact.unlisted.isEmpty && exact.missing.isEmpty)

        let twice = verdict(
            source + "\nstruct Other { let latch: any ThermalLatchRole }", path: "A.swift")
        #expect(twice.unlisted.map(\.line) == [5], "a listed statement written a second time")
        #expect(twice.missing.isEmpty)

        let fewer = verdict(
            "final class Watchdog {\n    private let latch: any ThermalLatchRole\n}",
            path: "A.swift")
        #expect(fewer.unlisted.isEmpty)
        #expect(fewer.missing.map(\.statement) == ["latch: any ThermalLatchRole"])

        let elsewhere = verdict(source, path: "B.swift")
        #expect(elsewhere.unlisted.count == 2, "the same statements in another file")
        #expect(elsewhere.missing.count == 2)
    }
}
