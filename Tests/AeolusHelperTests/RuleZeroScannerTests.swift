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
        ]
        for source in sources {
            #expect(try !RuleZeroScan.reaches(Self.code(source)), "\(source)")
        }
    }

    // MARK: - Driven calls

    private static func calls(_ source: String) throws -> (String, [RuleZeroScan.DrivenCall]) {
        let tightened = RuleZeroScan.tightened(Self.code(source))
        return (tightened, try RuleZeroScan.drivenCalls(in: tightened))
    }

    @Test("Every verb that writes once the plane can is found, with the plane to require")
    func everyDrivenCallIsFound() throws {
        let (_, found) = try Self.calls(
            """
            await helper.bringUp()
            await helper
                .signalTeardown
                .run(stoppingSupervisorsWith: {})
            await helper.prepareWritePath ( )
            await helper.reconcileFans()
            _ = try await helper.authority.apply([], leaseID: id, from: connection)
            try await plane.restoreToAutomatic(.everyFan)
            _ = try await rig.helper.plane.engageManualControl(of: fan)
            _ = await plane.prepareWritePath(enumerating: fans)
            """)
        #expect(
            found.map { "\($0.call) ← \($0.guardPath)" } == [
                "helper.bringUp ← helper.plane",
                "helper.signalTeardown.run ← helper.plane",
                "helper.prepareWritePath ← helper.plane",
                "helper.reconcileFans ← helper.plane",
                "helper.authority.apply ← helper.plane",
                "plane.restoreToAutomatic ← plane",
                "rig.helper.plane.engageManualControl ← rig.helper.plane",
                "plane.prepareWritePath ← plane",
            ])
        #expect(
            found.map(\.root) == [
                "helper", "helper", "helper", "helper", "helper", "plane", "rig", "plane",
            ])
    }

    @Test("A declaration of a verb is not a call of one")
    func aDeclarationIsNotACall() throws {
        let (_, found) = try Self.calls(
            "func restoreToAutomatic(_ scope: FanRestoreScope) async throws {}\n"
                + "func bringUp() async {}"
        )
        #expect(found.isEmpty)
    }

    @Test("The require is accepted only as the statement just before, and only as a require")
    func theGuardIsReadExactly() throws {
        let guarded = [
            "try #require(helper.plane.writeCapability == .notBuilt)\nawait helper.bringUp()",
            "try #require(\n    helper.plane.writeCapability == .notBuilt,\n    \"why\")\n"
                + "await helper.bringUp()",
            "try #require(helper . plane . writeCapability==.notBuilt, \"\\(x)\")  "
                + "await helper.bringUp()",
        ]
        for source in guarded {
            let (code, found) = try Self.calls(source)
            #expect(found.count == 1 && RuleZeroScan.isGuarded(found[0], in: code), "\(source)")
        }

        let unguarded = [
            "await helper.bringUp()",
            "try #require(helper.plane.writeCapability == .notBuilt)\nlet x = 1\n"
                + "await helper.bringUp()",
            "#expect(helper.plane.writeCapability == .notBuilt)\nawait helper.bringUp()",
            "try #require(other.plane.writeCapability == .notBuilt)\nawait helper.bringUp()",
            "try #require(helper.plane.writeCapability != .notBuilt)\nawait helper.bringUp()",
            "try #require(helper.plane.writeCapability == .notBuilt || true)\n"
                + "await helper.bringUp()",
            "// try #require(helper.plane.writeCapability == .notBuilt)\nawait helper.bringUp()",
        ]
        for source in unguarded {
            let (code, found) = try Self.calls(source)
            #expect(found.count == 1 && !RuleZeroScan.isGuarded(found[0], in: code), "\(source)")
        }
    }

    @Test("A scripted graph bound here is exempt; the real graph, a parameter and a helper are not")
    func theExemptionReadsTheBinding() throws {
        func exempt(_ source: String) throws -> Bool {
            let (code, found) = try Self.calls(source)
            let call = try #require(found.last)
            guard
                let initializer = try RuleZeroScan.binding(of: call.root, before: call.at, in: code)
            else { return false }
            return try RuleZeroScan.composesAFake(initializer, in: code)
        }

        #expect(
            try exempt(
                """
                private static func composed(over plane: some FanControlPlane) -> Graph {
                    HelperComposition(plane: plane)
                }
                let helper = Self.composed(
                    over: ScriptedControlPlane(fans: [:]))
                await helper.bringUp()
                """))
        #expect(
            try !exempt(
                "let helper = HelperComposition.production(\n log: log)\nawait helper.bringUp()"))
        #expect(
            try !exempt(
                "let plane = SMCFanControlPlane(scheduler: s, connection: c)\n"
                    + "try await plane.restoreToAutomatic(.everyFan)"))
        #expect(try !exempt("func f(helper: Graph) async { await helper.bringUp() }"))
        #expect(
            try !exempt(
                """
                private static func realOne() -> Graph { HelperComposition.production() }
                let helper = Self.realOne()
                await helper.bringUp()
                """))
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

    // MARK: - The channel out of reach

    @Test("The forbidden names are found as code and not as prose, strings or longer names")
    func theForbiddenNamesAreReadExactly() throws {
        let present = [
            "let c: any SMCWriteChannel = x",
            "SMCFanControlPlane(scheduler: s, connection: c, channel: c)",
            "SMCFanControlPlane(scheduler: s, connection: c, channel : c)",
            ".production(log: log, writePath: path)",
            ".production(log: log, `writePath`: path)",
        ]
        for source in present {
            let found = try WriteChannelReachTripwireTests.forbidden.filter {
                try RuleZeroScan.count($0.pattern, in: Self.code(source)) > 0
            }
            #expect(!found.isEmpty, "\(source)")
        }
        let absent = [
            "// channel: c, writePath: .connection, SMCWriteChannel",
            "let s = \"channel: c\"",
            "let channelCount: Int = 2; let writePathName = 1",
            "struct S: SMCWriteChannelLike {}",
        ]
        for source in absent {
            let found = try WriteChannelReachTripwireTests.forbidden.filter {
                try RuleZeroScan.count($0.pattern, in: Self.code(source)) > 0
            }
            #expect(found.isEmpty, "\(source)")
        }
    }

    @Test("A function taking a channel is found, with whether another file can call it")
    func channelTakersAreFound() throws {
        let file = RuleZeroScan.File(
            path: "T.swift",
            code: Self.code(
                """
                func open(on channel: isolated any SMCWriteChannel) {}
                private func hidden(_ c: any SMCWriteChannel) {}
                    fileprivate static func alsoHidden<C: SMCWriteChannel>(_ c: C) {}
                @discardableResult static func generic<C: SMCWriteChannel>(
                    _ c: isolated C
                ) -> Int { 0 }
                func unrelated(_ x: Int) {}
                """))
        let takers = try RuleZeroScan.channelTakers(in: file)
        #expect(takers.map(\.name) == ["open", "hidden", "alsoHidden", "generic"])
        #expect(takers.map(\.isPrivate) == [false, true, true, false])
    }

    // MARK: - The daemon's write path

    @Test("The connection as the write path is found however it is spelled")
    func theWritePathIsFoundInEverySpelling() throws {
        func found(_ source: String) throws -> Bool {
            let code = Self.code(source).filter { !$0.isWhitespace }
            return try RuleZeroScan.count(ProductionWritePathTripwireTests.needle, in: code) > 0
        }
        for spelling in [
            ".production(log: log, writePath: .connection)",
            ".production(writePath:.connection)",
            ".production(\n    writePath:\n        .connection)",
            ".production(writePath: ProductionWritePath.connection)",
            ".production(`writePath`: .connection)",
        ] {
            #expect(try found(spelling), "\(spelling)")
        }
        for source in [
            ".production(writePath: .withheld)",
            "// .production(writePath: .connection)",
            "let s = \".production(writePath: .connection)\"",
            ".production(writePath: .connectionless)",
        ] {
            #expect(try !found(source), "\(source)")
        }
    }
}
