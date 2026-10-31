import Foundation
import Testing

/// The two rules b2 added to the allowlist's population (C30), over fixtures, before either is
/// trusted over the tree: a function with an `isolated` parameter, and a requirement of a protocol
/// that refines `Actor`. In a file of its own so the suite stays inside `type_body_length`.
extension WriteVerbAllowlistTests {

    /// The functions that hold the write channel itself: every function with an `isolated`
    /// parameter, and every requirement of a protocol that refines `Actor` (b2's C30).
    ///
    /// **Why the population needed them.** A write turn's body is synchronous and, but for the
    /// engagement step and its floor hold, names no permit — it takes an `isolated any
    /// SMCWriteChannel` and the numbers the plane read out of its permit — so neither `async` nor
    /// a permit put it in the population, and a new one that wrote would have been invisible here
    /// however it was named. The two that take the step's permit, for its floor (ADR 0014's P1′
    /// amendment), are on `permitBearingVerbs` instead, since a function is on exactly one list. A function with an `isolated` channel
    /// runs on the channel's executor and can call its write requirement; a requirement of an
    /// `Actor` protocol is `async` at every call site from outside, which is where "a synchronous
    /// function cannot `await`" stops holding.
    ///
    /// These reach the firmware **directly, through the channel**, not through a permit-bearing
    /// verb, so `permitFreeFunctions`' claim does not describe them. What confines them is where
    /// they are called from: every write-turn body is reached only from inside one of
    /// `SMCFanControlPlane`'s write turns — the plane's verbs, on the lists above, are the gate —
    /// and `WritePathAbsenceTests.helperNeverCallsWrite` holds the channel's write to one call, in
    /// `issue`. The reachability probe's one function takes an `isolated SMCConnection` and is
    /// referenced by nothing (`WritePathAbsenceTests.nothingOutsideTheProbeNamesIt`).
    ///
    /// The helper's other two `Actor` protocols — § 5's registration role and its reporting role —
    /// enter the population by the same rule, and their requirements are classified for what they
    /// do: the permit-bearing one on `permitBearingVerbs`, the two that write nothing on
    /// `permitFreeFunctions`.
    static let channelBoundFunctions: Set<String> = [
        "SMCWriteChannel.swift: freshKeyInfo(for: SMCKey)",
        "SMCWriteChannel.swift: read(_: SMCKey)",
        "SMCWriteChannel.swift: write(_: [UInt8], to: SMCKey)",
        "SMCWriteTurns.swift: unlockStep(fanAt: Int, trace: inout StepTrace, "
            + "ledger: PlaneWriteLedger, log: PlaneWriteLog, on: isolated any SMCWriteChannel)",
        "SMCWriteTurns.swift: beforeTheModeWrite(fanAt: Int, firstStep: Bool, "
            + "trace: inout StepTrace, on: isolated any SMCWriteChannel)",
        "SMCWriteTurns.swift: setForceKey(fanAt: Int, ledger: PlaneWriteLedger, "
            + "log: PlaneWriteLog, on: isolated any SMCWriteChannel)",
        "SMCWriteTurns.swift: command(_: TargetCommand, ledger: PlaneWriteLedger, "
            + "log: PlaneWriteLog, on: isolated any SMCWriteChannel)",
        "SMCWriteTurns.swift: writeTarget(_: TargetCommand, log: PlaneWriteLog, "
            + "on: isolated any SMCWriteChannel)",
        "SMCWriteTurns.swift: keystone(_: FanRestoreScope, ledger: PlaneWriteLedger, "
            + "log: PlaneWriteLog, on: isolated any SMCWriteChannel)",
        "SMCWriteTurns+Reads.swift: survey(fans: Set<Int>?, notFound: SMCError?, "
            + "on: isolated any SMCWriteChannel)",
        "SMCWriteTurns.swift: issue(_: [UInt8], to: SMCKey, log: PlaneWriteLog, "
            + "on: isolated any SMCWriteChannel)",
        "SMCWriteTurns+Reads.swift: rawByte(of: SMCKey, on: isolated any SMCWriteChannel)",
        "SMCWriteTurns+Reads.swift: encoded(_: Double, as: SMCKeyInfo, "
            + "on: isolated any SMCWriteChannel)",
        "WriteSeamReachability.swift: namesTheWriteSeam(on: isolated SMCConnection)",
    ]

    /// Whether one of `function`'s own parameters is `isolated` — not a closure type that takes
    /// an `isolated` argument, which is a parameter of the closure.
    static func hasIsolatedParameter(_ function: SeamScanner.Function) -> Bool {
        function.parameterTypes.contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("isolated ")
        }
    }

    /// The keys of every requirement declared inside a protocol whose inheritance clause names
    /// `Actor`, across the target's files.
    static func actorProtocolRequirements(in target: String) throws -> Set<String> {
        var keys: Set<String> = []
        for file in try SeamScanner.swiftFiles(under: target) {
            keys.formUnion(
                try actorProtocolRequirements(
                    inSource: try String(contentsOf: file, encoding: .utf8),
                    file: file.lastPathComponent))
        }
        return keys
    }

    /// `actorProtocolRequirements(in:)` over one file's text.
    static func actorProtocolRequirements(
        inSource source: String, file: String
    ) throws -> Set<
        String
    > {
        let code = SeamScanner.strippingComments(source)
        let head = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])protocol\s+[A-Za-z_]\w*\s*:([^{]*)\{"#)
        let actor = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])Actor(?![A-Za-z0-9_])"#)
        var keys: Set<String> = []
        for match in head.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let inherits = Range(match.range(at: 1), in: code),
                let whole = Range(match.range, in: code),
                actor.firstMatch(
                    in: code, range: NSRange(inherits, in: code)) != nil
            else { continue }
            let body = RuleZeroScan.balanced(in: code, from: code.index(before: whole.upperBound))
            keys.formUnion(
                try SeamScanner.functions(inSource: String(body), file: file).map(\.key))
        }
        return keys
    }

    private static func functions(_ source: String) throws -> [SeamScanner.Function] {
        try SeamScanner.functions(inSource: source, file: "Fixture.swift")
    }

    /// An `isolated` parameter is found however the declaration is wrapped, and a closure type
    /// that takes an `isolated` argument is not the function's own isolation.
    ///
    /// **Mutation:** make `hasIsolatedParameter(_:)` test `contains("isolated")` on every type.
    /// Run: red here, at the closure-typed parameter.
    @Test("A function with an isolated parameter is in the population, a closure taking one is not")
    func anIsolatedParameterIsFound() throws {
        let holding = try Self.functions(
            """
            static func job(on channel: isolated any SMCWriteChannel) throws {}
            private static func wrapped(
                _ bytes: [UInt8],
                on channel:
                    isolated any SMCWriteChannel
            ) -> Int { 0 }
            static func probe(on connection: isolated SMCConnection) -> Bool { true }
            """)
        #expect(holding.map(Self.hasIsolatedParameter) == [true, true, true])

        let notHolding = try Self.functions(
            """
            func hand(_ job: @Sendable (isolated any SMCWriteChannel) throws -> Int) {}
            func plain(_ key: SMCKey) -> Int { 0 }
            nonisolated func report(_ event: SchedulerEvent) {}
            """)
        #expect(notHolding.map(Self.hasIsolatedParameter) == [false, false, false])
    }

    /// Every requirement of an `Actor` protocol is found, whatever else the protocol refines and
    /// however its clause is written; a protocol that does not refine `Actor`, or names a type
    /// that merely contains the word, contributes nothing.
    ///
    /// **Mutation:** drop the `Actor` check in `actorProtocolRequirements(inSource:file:)`, so
    /// every protocol's requirements count. Run: red here, at the `Sendable` protocol.
    @Test("A requirement of an Actor protocol is in the population, and no other protocol's")
    func anActorProtocolsRequirementsAreFound() throws {
        let found = try Self.actorProtocolRequirements(
            inSource: """
                protocol Channel: Actor {
                    var generation: Int? { get }
                    func read(_ key: SMCKey) throws -> SMCValue
                    func write(_ bytes: [UInt8], to key: SMCKey) throws
                }
                protocol Wider: Sendable, Actor, Hashable { func f() }
                protocol Plain: Sendable { func g() throws }
                protocol Lookalike: ActorRole { func h() }
                // protocol Commented: Actor { func i() }
                """,
            file: "Fixture.swift")
        #expect(
            found == [
                "Fixture.swift: read(_: SMCKey)", "Fixture.swift: write(_: [UInt8], to: SMCKey)",
                "Fixture.swift: f()",
            ])
    }

    /// The tree half: the write channel's requirements and every write-turn body are in the
    /// population, so `everyVerbIsAcknowledged` judges them. A scan that stopped reading either
    /// rule would leave the new list rotting rather than failing; this fails first.
    ///
    /// **Mutation:** add `static func sneak(on channel: isolated any SMCWriteChannel)` to
    /// `SMCWriteTurns`, writing through `issue`. Run: red at `everyVerbIsAcknowledged`, unlisted.
    @Test("The channel's requirements and the write-turn bodies are in the population")
    func theChannelBoundFunctionsAreInThePopulation() throws {
        let requirements = try Self.actorProtocolRequirements(in: "AeolusHelper")
        #expect(
            requirements.isSuperset(of: [
                "SMCWriteChannel.swift: freshKeyInfo(for: SMCKey)",
                "SMCWriteChannel.swift: read(_: SMCKey)",
                "SMCWriteChannel.swift: write(_: [UInt8], to: SMCKey)",
            ]), "\(requirements.sorted())")
        let isolated = try SeamScanner.functions(in: "AeolusHelper")
            .filter(Self.hasIsolatedParameter).map(\.file)
        #expect(isolated.filter { $0.hasPrefix("SMCWriteTurns") }.count >= 10, "\(isolated)")
    }
}
