import Foundation
import Testing

/// The scope half of the parser, tested against fixtures rather than against the tree it
/// scans — the same argument `SeamScannerParsingTests` makes for the declaration half, and
/// the same reason: a scanner exercised only through `Sources` is exercised only for the
/// shapes already written there.
///
/// Every limit `SeamScanner.properties(inSource:file:)` states has a fixture here, and two of
/// them are limits **because** a fixture found them: a string literal was contributing its
/// text to a property's initialiser, and a backtick-escaped name was dropping out of the
/// population without saying so.
@Suite("The seam scanner reads scope the way its stated limits say it does")
struct SeamScannerScopeParsingTests {

    // MARK: - Properties

    private func properties(_ code: String) -> [SeamScanner.Property] {
        SeamScanner.properties(inSource: code, file: "Fixture.swift")
    }

    /// The claim the whole scan rests on. A local and a member are written almost identically,
    /// and `HelperClientVerbs.swift` decodes a `SystemSnapshot` into a local in every verb —
    /// so a scanner that could not tell them apart would have to either forbid the verbs or
    /// permit the stored copy, and both make the tripwire useless.
    @Test("A local inside a function body is not a property")
    func localsAreNotProperties() {
        let found = properties(
            """
            actor Client {
                private var connection: NSXPCConnection?

                func snapshot() async throws -> SystemSnapshot {
                    let data: Data = try await exchange()
                    let snapshot = SystemSnapshot(fans: [], sensors: [])
                    return snapshot
                }
            }
            """)

        #expect(found.map(\.name) == ["connection"])
    }

    /// Which brace is a type's is decided by the **last** keyword before it, not the first
    /// word of the line. The text since the previous brace routinely holds earlier
    /// declarations — `HelperClient` has five properties above its nested
    /// `ConnectionGeneration` — and reading a `var` from one of those would make the nested
    /// type a function body, so everything inside it would be invisible.
    @Test("A property above a nested type does not make it a function body")
    func aPropertyAboveANestedTypeDoesNotHideIt() {
        let found = properties(
            """
            actor Client {
                private var generation: UInt64 = 0

                private struct ConnectionGeneration {
                    let connection: NSXPCConnection
                    let generation: UInt64
                }
            }
            """)

        #expect(found.map(\.name) == ["generation", "connection", "generation"])
    }

    /// A closure's `{` opens no type, so what is declared inside it is a local. `Task { … }`
    /// and `AsyncStream { … }` are both written in the client, and a header naming no keyword
    /// at all must not default to "type".
    @Test("A declaration inside a trailing closure is a local")
    func declarationsInsideClosuresAreLocals() {
        let found = properties(
            """
            actor Client {
                private var observers: [UUID: Continuation] = [:]

                nonisolated func healthUpdates() -> AsyncStream<Health> {
                    AsyncStream { continuation in
                        let token = UUID()
                        let cached = SystemSnapshot(fans: [], sensors: [])
                        Task { await self.observe(continuation, as: token, cached) }
                    }
                }
            }
            """)

        #expect(found.map(\.name) == ["observers"])
    }

    /// Storage is what the tripwires forbid, and a computed property has none: it can only
    /// re-derive what something else holds, and that something is what is forbidden. A
    /// `willSet`/`didSet` observer is the opposite case — the brace is there and the storage
    /// is too — and reading one as computed would be this parser's one silent miss.
    @Test("A computed property is not stored and an observed one is")
    func computedPropertiesAreNotStored() {
        let found = properties(
            """
            actor Client {
                private var negotiatedReply: HelloReply?
                var negotiated: HelloReply? { negotiatedReply }
                var health: Health {
                    get { currentHealth }
                }
                private var currentHealth: Health = .idle {
                    didSet { publish(currentHealth) }
                }
            }
            """)

        #expect(found.filter(\.isStored).map(\.name) == ["negotiatedReply", "currentHealth"])
        #expect(found.filter { !$0.isStored }.map(\.name) == ["negotiated", "health"])
    }

    /// The observer half of the rule above, with **no initialiser** — which is the only shape
    /// that actually reaches `observesStorage`.
    ///
    /// `currentHealth` in the fixture above carries `= .idle`, so the parser takes its `=`
    /// branch and records storage without ever consulting the accessor block. The branch the
    /// fixture named was therefore executed by nothing: mutating `observesStorage` to
    /// `return false` left the whole parsing suite green, and with that regression applied
    /// `private var lastSnapshot: SystemSnapshot? { didSet { publish() } }` — a legal stored
    /// optional with an observer and no initialiser — read as computed and walked straight
    /// through `theClientStoresNoFanState`. The parser was right; only its test was inert.
    ///
    /// **Mutation:** `return word == "willSet" || word == "didSet"` → `return false`. Run: red
    /// here, and green across the rest of this suite, which is why this fixture exists
    /// separately rather than as another line in the one above.
    @Test("An observed property with no initialiser is stored")
    func observedPropertiesWithoutInitialisersAreStored() {
        let found = properties(
            """
            actor Client {
                private var lastSnapshot: SystemSnapshot? {
                    didSet { publish() }
                }
                private var lastLease: Lease? {
                    willSet { publish() }
                }
                var derived: SystemSnapshot? {
                    lastSnapshot
                }
            }
            """)

        #expect(found.filter(\.isStored).map(\.name) == ["lastSnapshot", "lastLease"])
        #expect(found.filter { !$0.isStored }.map(\.name) == ["derived"])
    }

    /// A protocol requirement is a `{ get }`, which is not storage either — and a protocol
    /// that named a forbidden type in a requirement would be describing a conformer's
    /// storage, not declaring any.
    @Test("A protocol requirement is not stored")
    func protocolRequirementsAreNotStored() {
        let found = properties(
            """
            protocol Holding {
                var lastSnapshot: SystemSnapshot? { get }
            }
            """)

        #expect(found.map(\.isStored) == [false])
    }

    /// A type left to inference is the one spelling a type-position scan cannot see at all,
    /// and it is the spelling an author reaches for without thinking: `let cached =
    /// SystemSnapshot(…)` names the type only in its initialiser. `names` reads both, which is
    /// why the initialiser is recorded rather than discarded.
    @Test("An inferred type is recorded as an initialiser and reported by names")
    func inferredTypesAreRecorded() {
        let found = properties(
            """
            actor Client {
                private let cached = SystemSnapshot(fans: [], sensors: [])
            }
            """)

        #expect(found.first?.type == "")
        #expect(found.first?.names.contains("SystemSnapshot") == true)
    }

    /// `Lease` is a prefix of `LeaseRequest`. A forbidden-name list checked against the raw
    /// text is therefore a list of prefixes — it fires on `LeaseRequest` when it means
    /// `Lease`, and a tripwire that cries wolf is a tripwire somebody deletes. The split is
    /// what keeps the comparison on whole names.
    @Test("names reports whole identifiers, so a prefix is not a match")
    func namesReportsWholeIdentifiers() {
        let found = properties(
            """
            struct Held {
                let request: LeaseRequest
                let leases: [UUID: Lease]
                let handle: Task<Lease, Error>?
            }
            """)

        #expect(
            found.map(\.names) == [
                ["LeaseRequest"], ["UUID", "Lease"], ["Task", "Lease", "Error"],
            ])
    }

    /// A wrapped declaration still has a type. The formatter puts one on the next line when the
    /// line is long, and a parser that stopped at the first newline would record the type as
    /// empty — so a forbidden type would be reported as an unannotated `let`.
    @Test("A type wrapped onto the next line is still read")
    func wrappedTypesAreRead() {
        let found = properties(
            """
            actor Client {
                private var pendingRequest:
                    LeaseRequest?
            }
            """)

        #expect(found.first?.type == "LeaseRequest?")
    }

    /// **A multi-line closure initialiser is read to its closing brace**, so the type named only
    /// inside it is reported.
    ///
    /// This is the spelling that walked past `theClientStoresNoFanState`, and the reason it is a
    /// defect rather than a curiosity is `.swift-format`: `lineLength` is 100 and CI runs `swift
    /// format lint --strict`, so an initialiser of any substance **must** be broken across lines
    /// to merge at all — while the one-line `= { nil as SystemSnapshot? }()` this parser did
    /// catch is the form the formatter would reflow. The guard fired only on a spelling nobody can
    /// commit, which is a guard evaded by the house style rather than by an author.
    ///
    /// Proven on a scratch `actor` in `Sources/AeolusXPCClient`, not by reading: `private var
    /// lastSnapshot = {` with `let remembered: SystemSnapshot? = nil` on the line below left the
    /// whole of `HelperClientStateSeamTests` green, and the one-line form of the same property was
    /// red. The initialiser stopped at the first newline, so it was the single character `{`.
    ///
    /// **Mutation:** drop the `braces` accounting from `fragment(in:from:stoppingAt:)` — the
    /// one-line change that restores a line-bounded initialiser. Run: red here, and green across
    /// every other fixture in this suite, which is the point.
    @Test("A multi-line closure initialiser is read past its first line")
    func multiLineClosureInitialisersAreRead() {
        let found = properties(
            """
            actor Client {
                private var lastSnapshot = {
                    let remembered: SystemSnapshot? = nil
                    return remembered
                }()
            }
            """)

        #expect(found.map(\.name) == ["lastSnapshot"])
        #expect(found.first?.isStored == true)
        #expect(found.first?.names.contains("SystemSnapshot") == true)
    }

    /// A closure initialiser **ends at its own closing brace**, and a comparison inside it does
    /// not carry it into the next declaration.
    ///
    /// `fragment` guesses that `<` and `>` bracket a generic argument list. That is right in a
    /// type position and wrong in a closure body, and the direction it fails in is the dangerous
    /// one: one `if attempts < 3` leaves the bracket depth unbalanced, so the newline that should
    /// end the initialiser arrives at depth one and the scan runs on — through the closing brace
    /// of the type and into whatever is declared below. The initialiser then reports types from
    /// other declarations, which is a tripwire naming the wrong property in its failure message
    /// and firing on a tree that is correct. So the bracket accounting is switched off while a
    /// brace is open: inside a closure body there is nothing to balance, because the brace depth
    /// is already what decides where the initialiser ends.
    ///
    /// **Mutation:** count `(`/`[`/`<` regardless of brace depth — `} else if braces == 0 {` →
    /// `} else {`. Run: red here, green on the fixture above, which is why the two are separate.
    @Test("A closure initialiser ends at its own brace, not at the next declaration")
    func closureInitialisersDoNotRunOn() {
        let found = properties(
            """
            actor Client {
                private var lastSnapshot = {
                    let attempts = 2
                    if attempts < 3 { return nil as SystemSnapshot? }
                    return nil
                }()

                private var pending: LeaseRequest?
            }
            """)

        #expect(found.map(\.name) == ["lastSnapshot", "pending"])
        #expect(found.first?.names.contains("SystemSnapshot") == true)
        #expect(found.first?.names.contains("LeaseRequest") == false)
    }

    /// The widening above is the **initialiser** half alone: a computed property's accessor block
    /// still terminates the type.
    ///
    /// `var health: HelperConnectionHealth { currentHealth }` is written in the client, and a type
    /// parse that counted that `{` as an opening depth would run on through the accessor block and
    /// past the end of the declaration — so `isStored` would never be consulted and a computed
    /// property would read as storage. The `{` is a terminator for the type and a depth for the
    /// initialiser, and both directions have to hold at once.
    ///
    /// **Mutation:** count `{` as a depth even when the caller named it a terminator. Run: red
    /// here.
    @Test("A closure depth does not swallow a computed property's accessor block")
    func closureDepthDoesNotSwallowAccessorBlocks() {
        let found = properties(
            """
            actor Client {
                private var currentHealth: Health = .idle
                var health: Health {
                    currentHealth
                }
                private var pending: LeaseRequest?
            }
            """)

        #expect(found.map(\.name) == ["currentHealth", "health", "pending"])
        #expect(found.filter(\.isStored).map(\.name) == ["currentHealth", "pending"])
        #expect(found.last?.type == "LeaseRequest?")
    }

    /// A string literal contributes nothing to a header and hides nothing inside itself. A
    /// `struct` written in a literal must not flip the next brace to a type scope, and a `var`
    /// written in one is not a declaration — the tripwires' own failure messages quote the
    /// declarations they forbid, and this suite's fixtures spell them out in full.
    @Test("A string literal opens no scope and declares nothing")
    func stringLiteralsDeclareNothing() {
        let found = properties(
            """
            actor Client {
                private var detail = "private var lastSnapshot: SystemSnapshot? in a struct"

                func explain() -> String {
                    let note = "struct Held {"
                    return note
                }
            }
            """)

        #expect(found.map(\.name) == ["detail"])
        #expect(found.first?.names.contains("SystemSnapshot") == false)
    }

    /// A backtick-escaped name is a name. `HelperClientDeadlines.default` is written that way,
    /// and until the parser stepped over the backtick it was simply absent from the population
    /// — a shorter scan that said nothing about being shorter.
    @Test("A backtick-escaped name is read as a declaration")
    func backtickEscapedNamesAreRead() {
        let found = properties(
            """
            struct Deadlines {
                public static let `default` = Deadlines(gatedVerb: .seconds(5))
            }
            """)

        #expect(found.map(\.name) == ["default"])
    }

    /// The same safe direction as everywhere else here: prose describing a forbidden
    /// declaration is not one, and a tripwire that fired on the sentence explaining the rule
    /// would be a tripwire nobody keeps.
    @Test("A property written in a comment is not a property")
    func commentedPropertiesAreNotProperties() {
        let found = properties(
            """
            actor Client {
                // private var lastSnapshot: SystemSnapshot?
                /* private var heldLease: Lease? */
                private var connection: NSXPCConnection?
            }
            """)

        #expect(found.map(\.name) == ["connection"])
    }

    // MARK: - Function bodies

    /// The body is brace-matched, so a nested closure's braces do not end it early. Ending
    /// early is the dangerous direction: everything after the first inner `}` would leave the
    /// population, and a retry written there would be invisible to a scan that reported
    /// success.
    @Test("A body includes its nested closures and ends at its own brace")
    func bodiesAreBraceMatched() throws {
        let body = try SeamScanner.functionBody(
            named: "exchange",
            inSource: """
                func exchange<Answer: Sendable>(
                    on live: ConnectionGeneration,
                    _ send: (any Protocol, @escaping (Result<Answer, Error>) -> Void) -> Void
                ) async throws -> Answer {
                    let proxy = live.connection.remoteObjectProxyWithErrorHandler { error in
                        for attempt in 0..<3 { pending.deliver(.failure(error)) }
                    }
                    return try await pending.answer()
                }

                func translate(_ error: Error) -> Error { error }
                """)

        #expect(body?.contains("for attempt in 0..<3") == true)
        #expect(body?.contains("func translate") == false)
    }

    /// A `}` inside a string literal closes nothing. Reading one as the end of the body would
    /// truncate the text a tripwire scans, and the failure would be silent.
    @Test("A brace inside a string literal does not end a body")
    func bracesInStringLiteralsDoNotEndBodies() throws {
        let body = try SeamScanner.functionBody(
            named: "explain",
            inSource: """
                func explain() -> String {
                    let opening = "}"
                    while true { return opening }
                }
                """)

        #expect(body?.contains("while true") == true)
    }

    /// A declaration with no body of its own answers `nil` rather than running on to the next
    /// function's. A caller asserting the absence of something inside a body must treat that
    /// as a failure, not as an empty scan — which is why `sendPath()` requires every name on
    /// its floor to have been found.
    @Test("A declaration with no body answers nil")
    func declarationsWithoutBodiesAnswerNil() throws {
        let body = try SeamScanner.functionBody(
            named: "pinnedConnection",
            inSource: """
                protocol HelperConnectionPinning {
                    func pinnedConnection(over transport: Transport) throws -> NSXPCConnection
                }

                func other() { while true {} }
                """)

        #expect(body == nil)
    }

    /// A bodiless declaration above a real one is **skipped**, not answered with.
    ///
    /// This is exactly how `HelperConnectionPinning.swift` is written — the protocol
    /// requirement first, `SignedHelperPinning`'s implementation below it — and a first-match
    /// scan answered `nil` for the one function in this target that builds a connection.
    /// `sendPath()` then dropped `pinnedConnection` from its population silently, and a
    /// three-attempt retry of `transport.makeConnection()` inside it was green.
    ///
    /// **Mutation:** take the first match rather than the first match with a body. Run: red
    /// here, and red on `nothingOnTheSendPathRetries`' floor, which is the half that says the
    /// name was reached at all.
    @Test("A bodiless declaration does not hide the implementation below it")
    func bodilessDeclarationsDoNotHideImplementations() throws {
        let body = try SeamScanner.functionBody(
            named: "pinnedConnection",
            inSource: """
                protocol HelperConnectionPinning {
                    func pinnedConnection(over transport: Transport) throws -> NSXPCConnection
                }

                struct SignedHelperPinning: HelperConnectionPinning {
                    func pinnedConnection(over transport: Transport) throws -> NSXPCConnection {
                        for attempt in 0..<3 { _ = attempt }
                        return transport.makeConnection()
                    }
                }
                """)

        #expect(body?.contains("for attempt in 0..<3") == true)
    }
}
