import Foundation
import Testing

/// The rule-zero scans, on synthetic sources: a scan that has silently stopped matching reports a
/// clean tree, so each is held to the spellings it must see and the ones it must not.
@Suite("The rule-zero scans")
struct RuleZeroScannerTests {

    private static func code(_ source: String) -> String { RuleZeroScan.code(of: source) }

    // MARK: - Reach

    @Test("A real connection is in reach however it is spelled")
    func reachIsFoundInEverySpelling() throws {
        let spellings = [
            "let connection = SMCConnection()",
            "let connection = SMCConnection (roundTrips: monitor)",
            "func read(through connection: SMCConnection) {}",
            "let helper = HelperComposition.production(log: log)",
            "let helper: HelperComposition<SMCFanControlPlane> = .production()",
            "let helper = HelperComposition<SMCFanControlPlane>\n    .production ()",
            "let provider = SMCSensorProvider()",
            "let provider = SMCSensorProvider(connection: connection)",
            "let f = HelperComposition.production",
            "let f = HC.production",
        ]
        for spelling in spellings {
            #expect(try RuleZeroScan.reaches(Self.code(spelling)), "\(spelling)")
        }
    }

    @Test("Another name, a comment and a string are not in reach")
    func lookalikesAreNotInReach() throws {
        let sources = [
            "let connection = InertSMCConnection()",
            "struct R: SMCConnectionRecycling {}",
            "// let connection = SMCConnection()",
            "let pin = \"let connection = SMCConnection()\"",
            "let kind = SMCSensorProvider.kind(for: key)",
            "let p = Production(); p.productionLine()",
            "let clock = SettleClock.production",
            "let connection = HelperConnection.production",
        ]
        for source in sources {
            #expect(try !RuleZeroScan.reaches(Self.code(source)), "\(source)")
        }
    }

    // MARK: - Construction sites

    /// Each fixture is judged as a test function's body, where real constructions are: at file
    /// scope a binding is a global, which the rule refuses outright (B2), and every fixture would
    /// then be rejected for that reason instead of its own.
    private static func judged(_ source: String) throws -> [RuleZeroScan.Construction] {
        try RuleZeroScan.constructions(in: Self.code("func fixture() async throws {\n\(source)\n}"))
    }

    @Test("A let required to hold no channel on its first use is accepted, for both kinds")
    func aRequiredConstructionIsAccepted() throws {
        let accepted = [
            "let helper = HelperComposition.production(log: log)\n"
                + "try #require(!helper.plane.holdsWriteChannel, \"why\")\nawait helper.bringUp()",
            "let helper = HelperComposition.production(\n    log: log,\n    watchdogTicks: t)\n"
                + "let composed = 1\ntry #require(\n    !helper . plane . holdsWriteChannel)",
            "let plane = SMCFanControlPlane(scheduler: s, connection: c)\n"
                + "try #require(!plane.holdsWriteChannel)",
            "let plane = supervisorPlane(over: provider)\ntry #require(!plane.holdsWriteChannel)",
            "let helper: HelperComposition<SMCFanControlPlane> = .production()\n"
                + "try #require(!helper.plane.holdsWriteChannel)",
            // B-1: swift-format breaks after `=`, and 65 bindings under Tests are written so.
            "let helper =\n    HelperComposition.production(log: log)\n"
                + "try #require(!helper.plane.holdsWriteChannel)",
            "let plane =\n\n    SMCFanControlPlane(\n        scheduler: s, connection: c)\n"
                + "try #require(!plane.holdsWriteChannel)",
            // B3: the initialiser's other two spellings.
            "let plane = SMCFanControlPlane.init(scheduler: s, connection: c)\n"
                + "try #require(!plane.holdsWriteChannel, \"why\")",
            "let plane: SMCFanControlPlane = .init(scheduler: s, connection: c)\n"
                + "try #require(!plane.holdsWriteChannel)",
            "func f() throws {\n    let helper = HelperComposition.production(log: log)\n"
                + "    try #require(!helper.plane.holdsWriteChannel)\n}",
        ]
        for source in accepted {
            let found = try Self.judged(source)
            #expect(found.count == 1 && found[0].violation == nil, "\(source): \(found)")
        }
    }

    @Test("Every way past the rule is a violation")
    func everyWayPastTheRuleIsAViolation() throws {
        let rejected = [
            "let helper = HelperComposition.production(log: log)\nawait helper.bringUp()",
            "let helper = HelperComposition.production(log: log)\n"
                + "try? #require(!helper.plane.holdsWriteChannel)",
            "let helper = HelperComposition.production(log: log)\n"
                + "try! #require(!helper.plane.holdsWriteChannel)",
            "var helper = HelperComposition.production(log: log)\n"
                + "try #require(!helper.plane.holdsWriteChannel)",
            "let f = HelperComposition.production\nlet helper = f(log, t, w, { _ in nil })",
            "use(HelperComposition.production())",
            "let observer = HelperComposition.production(log: log).powerObserver\n"
                + "try #require(!observer.plane.holdsWriteChannel)",
            "let helper = HelperComposition.production(log: log)\nlet p = helper.plane\n"
                + "try #require(!helper.plane.holdsWriteChannel)",
            "let helper = HelperComposition.production(log: log)\n"
                + "#expect(!helper.plane.holdsWriteChannel)",
            "let plane = SMCFanControlPlane(scheduler: s, connection: c)\n"
                + "try #require(plane.holdsWriteChannel)",
            "let helper = HelperComposition.production(log: log)\n"
                + "try #require(!helper.holdsWriteChannel)",
            "// try #require\nlet helper = HelperComposition.production(log: log)",
            // B-1's shape, unrequired: it must be judged on its binding, and judged red.
            "let helper =\n    HelperComposition.production(log: log)\nawait helper.bringUp()",
            // An initialiser the scan cannot read is outside every let, which is a violation.
            "let helper = try await\n    HelperComposition.production(log: log)\n"
                + "try #require(!helper.plane.holdsWriteChannel)",
            // S-3: an optional binding's first use is not the require.
            "let helper: HelperComposition? = .production(log: log)\nawait helper?.bringUp()",
            "let helper = HC.production(log: log)\nawait helper.bringUp()",
            // Codex: the whole first argument must be the negation.
            "let helper = HelperComposition.production(log: log)\n"
                + "try #require(!helper.plane.holdsWriteChannel || true)",
            "let helper = HelperComposition.production(log: log)\n"
                + "try #require(!helper.plane.holdsWriteChannel == false, \"why\")",
            "let plane = SMCFanControlPlane(scheduler: s, connection: c)\n"
                + "try #require(!plane.holdsWriteChannel && x)",
            // B1: a require that a block can swallow or skip.
            "let helper = HelperComposition.production(log: log)\n"
                + "do { try #require(!helper.plane.holdsWriteChannel) } catch {}\n_ = helper.plane",
            "let helper = HelperComposition.production(log: log)\n"
                + "withKnownIssue { try #require(!helper.plane.holdsWriteChannel) }",
            "let helper = HelperComposition.production(log: log)\n"
                + "if Bool.random() { try #require(!helper.plane.holdsWriteChannel) }",
            "let helper = HelperComposition.production(log: log)\n"
                + "Task { try #require(!helper.plane.holdsWriteChannel) }",
            // The same blocks as formatted, where the `try` begins a line of its own and only
            // the open brace says it can be swallowed or skipped.
            "let helper = HelperComposition.production(log: log)\n"
                + "do {\n    try #require(!helper.plane.holdsWriteChannel)\n} catch {}\n_ = helper.plane",
            "let helper = HelperComposition.production(log: log)\n"
                + "withKnownIssue {\n    try #require(!helper.plane.holdsWriteChannel)\n}",
            "let helper = HelperComposition.production(log: log)\n"
                + "if Bool.random() {\n    try #require(!helper.plane.holdsWriteChannel)\n}",
            "let helper = HelperComposition.production(log: log)\n"
                + "Task {\n    try #require(!helper.plane.holdsWriteChannel)\n}",
            // …or an argument, which an autoclosure can swallow.
            "let helper = HelperComposition.production(log: log)\n"
                + "swallow(try #require(!helper.plane.holdsWriteChannel))",
            // B2: a stored property, required or not, and `self.` is a use.
            "struct S {\n    let helper = HelperComposition.production(log: log)\n"
                + "    func t() throws { try #require(!helper.plane.holdsWriteChannel) }\n}",
            "func t() async {\n    let helper = HelperComposition.production(log: log)\n"
                + "    await self.helper.bringUp()\n"
                + "    try #require(!helper.plane.holdsWriteChannel)\n}",
            // B3: the other spellings, unrequired.
            "let plane = SMCFanControlPlane.init(scheduler: s, connection: c)\n_ = plane.isOpen",
            "let plane: SMCFanControlPlane = .init(scheduler: s, connection: c)\n_ = plane",
        ]
        for source in rejected {
            let found = try Self.judged(source)
            #expect(
                !found.isEmpty && found.contains { $0.violation != nil }, "\(source): \(found)")
            // Rejected for its own shape: only the stored-property fixture is refused as stored.
            let asStored = found.contains { $0.violation?.contains("stored property") == true }
            #expect(asStored == source.hasPrefix("struct"), "\(source): \(found)")
        }
    }

    @Test("A declaration and a string are not constructions")
    func declarationsAndStringsAreNotConstructions() throws {
        let sources = [
            "func supervisorPlane(over provider: P) -> SMCFanControlPlane { fatalError() }",
            "static func production(log: HelperLog) -> Graph { fatalError() }",
            "let pin = \"let helper = HelperComposition.production(log: log)\"",
            "let source = #\"SMCFanControlPlane(scheduler: s, connection: c)\"#",
            "let clock = SettleClock.production",
            "let connection = HelperConnection.production",
        ]
        for source in sources {
            let found = try Self.judged(source)
            #expect(found.isEmpty, "\(source): \(found)")
        }
    }

    /// B-1 by itself: the binding is found across the break, so the violation names it.
    ///
    /// **Mutation:** in `letAndVarBindings`, start the initialiser at the `=` instead of at its
    /// first non-blank character. Run: red here, and at `aRequiredConstructionIsAccepted`.
    @Test("A binding that breaks after its = is judged on that binding")
    func aBreakAfterTheEqualsKeepsItsBinding() throws {
        let found = try Self.judged(
            "let helper =\n    HelperComposition.production(log: log)\nawait helper.bringUp()")
        #expect(found.map(\.binding) == ["helper"], "\(found)")
        #expect(found.first?.violation?.contains("not the holdsWriteChannel require") == true)
    }

    @Test("A hardware gate is found on the suite, and on a file that extends it")
    func theGateIsFoundAndInherited() throws {
        let files = [
            RuleZeroScan.File(
                path: "A.swift",
                code: Self.code(
                    "@Suite(.enabled(if: SMCConnection.isHardwareAvailable())) struct Real {}")),
            RuleZeroScan.File(path: "B.swift", code: Self.code("extension Real { func t() {} }")),
            RuleZeroScan.File(path: "C.swift", code: Self.code("extension Other {}")),
            RuleZeroScan.File(path: "D.swift", code: Self.code("// isHardwareAvailable")),
        ]
        #expect(try RuleZeroScan.hardwareGated(files) == ["A.swift", "B.swift"])
    }

}
