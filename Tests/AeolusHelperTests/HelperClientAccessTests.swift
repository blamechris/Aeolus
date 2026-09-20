import Foundation
import Testing

/// D36 on `HelperClient`, asserted rather than described.
///
/// ## Why this suite exists
///
/// [#242](https://github.com/blamechris/Aeolus/issues/242) asked whether
/// `HelperClient.swift` should be split at SwiftLint's 400-line warning, and the answer
/// recorded in that file is no: Swift `private` is file-scoped, so every remaining seam
/// needs a member of the actor reachable from a sibling file, and D36 is that stored state
/// stays `private` and is mutated only from its declaring file.
///
/// That answer was a paragraph, and #128's lesson — the one D36 exists because of — is that
/// a paragraph is not enforcement: the next split has no way to notice it is widening
/// `hasEverHandshaken` rather than adding a file. The two suites that hold the same line
/// elsewhere, `LeaseAuthorityAccessTests` and `HelperConnectionSessionAccessTests`, cover
/// `AeolusHelper` only, and **nothing asserted access anywhere in `AeolusXPCClient` before
/// this suite**. That was measured rather than assumed: with this file held out of the tree
/// and all seven of `HelperClient`'s `private var`s widened to `internal` in one edit, the
/// package ran **1581 tests in 242 suites, passed**. So "do not split it, D36 says so" was a
/// decision nothing could keep. Declining a refactor and leaving its rule unenforced is the
/// weaker half of the two, so the rule is wired up here instead.
///
/// It is not an argument against ever splitting the file. It is what tells a later split
/// what it is spending, at the moment it spends it, rather than after.
///
/// ## Both directions, for the reason `HelperConnectionSessionAccessTests` gives
///
/// `theClientsMutableStateStaysPrivate` fails when a listed property loses its `private`,
/// when it is no longer declared as written, **and** when a second line of the file matches
/// the same spelling — the three ways a named guard stops naming anything.
/// `onlyTheAcknowledgedPropertiesAreNonPrivate` and its method half are what catch the
/// widening nobody listed, and they scan every file the actor is written in, so a member
/// cannot be widened simply by being written in a new one.
///
/// ## What this suite cannot see, stated rather than implied
///
/// It reads access levels, never call sites. The compiler is what actually stops
/// `HelperClientVerbs.swift` assigning to `generation`; this suite's job is to notice the
/// day somebody makes that assignment *possible*. And it is about access alone — the
/// separate question of what the client may **keep** is `HelperClientStateSeamTests`, which
/// forbids a stored snapshot or lease whatever its access level.
@Suite("The XPC client's own state stays private to HelperClient.swift")
struct HelperClientAccessTests {

    /// The file that declares the storage, and so the only one that can write it.
    private static let declaringFile = "HelperClient.swift"

    /// The type these guards are about, and the target it is written in.
    private static let clientType = "HelperClient"
    private static let clientTarget = "AeolusXPCClient"

    /// Both files `HelperClient`'s members are written in, **sorted**, and checked against
    /// the tree by `theScannedFilesAreEveryFileTheClientIsIn` rather than trusted.
    ///
    /// Neither declares a second type at the actor's own member indent, which is the
    /// precondition `MemberAccessScan.members(in:keyword:)` states. `ConnectionGeneration` is
    /// nested inside the actor, so its two `let`s sit at eight spaces and are not read as the
    /// actor's; the other eight files in the target declare types whose names merely begin
    /// with `HelperClient`, and the scan matches a name whole.
    ///
    /// Written out rather than derived at the point of use, for the reason the connection
    /// session's suite gives: a list compared against the tree is a decision a maintainer
    /// makes once, and deriving it silently would make the scan follow a split instead of
    /// reporting it.
    private static let clientFiles = [
        "HelperClient.swift",
        "HelperClientVerbs.swift",
    ]

    /// Every mutable property this actor has, spelled as declared, and where it has to stay.
    ///
    /// All seven, because unlike the connection session there is no line to draw here: this
    /// *is* the client's state, and each of the seven is an input to a guard that reads it.
    ///
    /// - `connection`, `negotiatedReply` and `handshake` are what "is there a live,
    ///   handshaken connection" is answered from. A sibling file that could write
    ///   `negotiatedReply` could mark a connection handshaken that negotiated nothing, and
    ///   `withHandshakenProxy` would then send a gated verb onto it.
    /// - `generation` is the parameter every late-handler guard turns on, and the comment on
    ///   it records what happens when it is read from the wrong place: `guard generation ==
    ///   self.generation` becomes `guard x == x`. Writable from a second file, the same guard
    ///   can be satisfied rather than merely defeated.
    /// - `hasEverHandshaken` is the whole of the 4097 classification — `helperRestarted`
    ///   against `helperUnreachable` — and on `Mac16,5` a *refused* connection is reported as
    ///   an interruption too, so it is the only thing separating "the helper restarted under
    ///   me" from "nothing ever answered". Set to `true` from elsewhere, this client invents
    ///   a helper it never spoke to.
    /// - `currentHealth` is what `publish` compares against before yielding, and assigning it
    ///   directly skips both the comparison and the observers: the signal would report a
    ///   state nothing had been told about, which is `CLAUDE.md` rule 6 in the one place this
    ///   target exists to serve it. `observers` is the registry that yield walks.
    ///
    /// **Spelled as declared**, so a respelling has to be re-stated here. That is the
    /// list-rot half: `MemberAccessScan.declaration(of:in:from:)` requires the fragment to
    /// match exactly one line of the file, so a renamed, moved or reformatted property fails
    /// loudly instead of leaving an entry that protects nothing.
    ///
    /// **Mutation:** drop the `private` from `private var hasEverHandshaken = false`. Run: red
    /// on `theClientsMutableStateStaysPrivate` **and** on
    /// `onlyTheAcknowledgedPropertiesAreNonPrivate`, both, which is stated rather than hidden —
    /// the named guard and the exhaustive one are supposed to see the same widening from two
    /// directions. **Mutation:** respell `private var generation: UInt64 = 0` as
    /// `private var generation: UInt64 = .zero`, which still compiles and is still private.
    /// Run: red on `theClientsMutableStateStaysPrivate` **alone**, on zero matches — that is
    /// the list-rot half, and the exhaustive sibling cannot see it, because nothing about the
    /// access level changed.
    private static let mustStayPrivate = [
        "var connection: NSXPCConnection?",
        "var negotiatedReply: HelloReply?",
        "var handshake: Task<HelloReply, Error>?",
        "var hasEverHandshaken = false",
        "var generation: UInt64 = 0",
        "var currentHealth: HelperConnectionHealth = .idle",
        "var observers: [UUID: AsyncStream<HelperConnectionHealth>.Continuation] = [:]",
    ]

    /// Every property of `HelperClient` that is not `private`, and why.
    ///
    /// `public` counts as non-private here, because `MemberAccessScan` reads the modifier run
    /// and `public` is one of the ignorable ones. That is the useful reading rather than a
    /// limitation to work around: on a privilege boundary a new *public* property is at least
    /// as much of an event as a new internal one, so the list pins the whole exported surface
    /// and a widening cannot hide by being a bigger one.
    ///
    /// All three are **get-only computed views** of private storage, which is the property
    /// worth stating: `negotiated` and `health` are the public read API — the second is ADR
    /// 0006's switch for the app — and `currentGeneration` is `internal` for the suite, for
    /// the reason the source gives, that the generation is the parameter every late-handler
    /// guard turns on and a test unable to name it could only assert them by accident. **A
    /// stored property appearing in this list is the failure to argue about**, because that
    /// is the shape that hands a caller an assignment; a computed one can only re-derive what
    /// something in the declaring file still owns.
    ///
    /// **Mutation:** drop the `private` from `private let deadlines: HelperClientDeadlines`, an
    /// injected `let` on no list here. Run: red on
    /// `onlyTheAcknowledgedPropertiesAreNonPrivate` alone, naming it — which is the half that
    /// catches a widening nobody wrote down.
    private static let acknowledgedNonPrivateProperties: Set<String> = [
        "negotiated",
        "health",
        "currentGeneration",
    ]

    /// Every method of `HelperClient` that is not `private`, and what each is.
    ///
    /// Eight are the public API. Six are the verbs, in `HelperClientVerbs.swift`, one per
    /// message the protocol has bar `hello` — which has no wrapper anywhere, because this
    /// actor negotiates it privately inside `performHandshake`. `disconnect()` is the teardown
    /// a caller that is finished asks for, and `healthUpdates()` the `nonisolated` stream.
    ///
    /// The remaining five are `internal`, and they are the seam #242 asked whether more of
    /// this actor could be expressed over:
    ///
    /// - `withHandshakenProxy` and `withProxy` are the two gates, and they are the answer to
    ///   that question — the verbs already work over exactly this interface and reach no
    ///   state through it. `withProxy` is additionally held to one caller by
    ///   `HelperClientSeamTests.theUnhandshakenProxyHasExactlyOneCaller`.
    /// - `translate(_:on:)`, `connectionWasInterrupted` and `connectionWasInvalidated` are
    ///   `internal` so the suite can reach them, and each says so where it is declared: the
    ///   two handlers are libxpc's entry points into this actor and the interleaving
    ///   `generation` exists to survive cannot be provoked on demand over a real connection,
    ///   and one arm of `translate` — `NSXPCConnectionReplyInvalid` — cannot be provoked at
    ///   all. **These three are the ones to argue about**, because unlike the gates each
    ///   mutates the storage above, so a sixth internal method reaching it is a decision
    ///   rather than a convenience.
    ///
    /// **Spelled as signatures, not names**, for the reason #236 established on the
    /// connection session: a bare-name key cannot see a second method that reuses a name, and
    /// `translate(_ error: Error, on generation: UInt64, force: Bool)` written beside this one
    /// would land on the existing entry. The parameter types are in the key because labels
    /// alone cannot see an overload either.
    ///
    /// The two gates' keys carry a closure type, so each is written as two adjacent literals
    /// to stay inside the line limit. They concatenate to the exact key the scan produces;
    /// the test fails naming both sides if they ever do not.
    ///
    /// **Mutation:** drop the `private` from
    /// `private func discardConnection(_ generation: UInt64, as health: HelperConnectionHealth)`
    /// — chosen because it is exactly what moving `translate(_:on:)` to a sibling file would
    /// cost. Run: red on `onlyTheAcknowledgedMethodsAreNonPrivate` alone, naming
    /// `discardConnection(_: UInt64, as: HelperConnectionHealth)`.
    ///
    /// **A limit found by trying it, recorded because it is load-bearing and is not this
    /// suite's doing:** `private func exchange<Answer: Sendable>` cannot be widened at all.
    /// Its `on live: ConnectionGeneration` parameter names a `private` nested type, so the
    /// compiler refuses — *"method must be declared private because its parameter uses a
    /// private type"* — before any test runs. `liveConnection()` and `handshakenConnection()`
    /// return that type and are held the same way. So the three functions that construct and
    /// thread a `ConnectionGeneration` are sealed into this file by the type system rather
    /// than by a list, which is a stronger guarantee than the one here and is worth knowing
    /// before designing a split around them.
    private static let acknowledgedNonPrivateMethods: Set<String> = [
        "snapshot()",
        "acquireLease(_: LeaseRequest)",
        "renewLease(id: UUID)",
        "releaseLease(id: UUID)",
        "apply(_: [FanSetting], leaseID: UUID)",
        "restoreAllToAutomatic()",
        "disconnect()",
        "healthUpdates()",
        "withHandshakenProxy(_: (any AeolusXPCProtocol, @escaping @Sendable "
            + "(Result<Answer, Error>) -> Void) -> Void)",
        "withProxy(_: (any AeolusXPCProtocol, @escaping @Sendable "
            + "(Result<Void, Error>) -> Void) -> Void)",
        "translate(_: Error, on: UInt64)",
        "connectionWasInterrupted(_: UInt64)",
        "connectionWasInvalidated(_: UInt64)",
    ]

    /// The file set is a claim about the tree, so it is read off the tree.
    ///
    /// #236's first mutation against the connection session was a fourth file —
    /// `extension HelperConnectionSession { … }` in a file listed nowhere and scanned by
    /// nothing, green across two suites. The same move is available here, and is in fact the
    /// likely shape of a later split of `HelperClient.swift`: adding
    /// `HelperClientConnection.swift` is how the refactor #242 declined would arrive. This is
    /// what fails when it does, and what makes the widening it needs visible in the same run.
    ///
    /// The declaring file is checked the same way, because `theClientsMutableStateStaysPrivate`
    /// opens that one file by name: if the `actor` declaration moved and `declaringFile` did
    /// not, that test would assert about a file the storage had left.
    ///
    /// **Mutation:** add `Sources/AeolusXPCClient/HelperClientConnection.swift` holding
    /// `extension HelperClient { func currentHealthForSiblingFile() -> HelperConnectionHealth
    /// { health } }` — a third file for the actor with an internal member in it. Run: red
    /// here, naming the file, and across the whole package **red nowhere else** — 1 issue in
    /// 1585 tests. That second half is the measurement worth keeping: it is what says this
    /// test is the only thing in the tree that notices.
    @Test("Every file the XPC client is written in is one this suite scans")
    func theScannedFilesAreEveryFileTheClientIsIn() throws {
        let sites = try MemberAccessScan.filesDeclaring(
            Self.clientType, inTarget: Self.clientTarget)

        #expect(
            sites.members == Self.clientFiles.sorted(),
            """
            the files \(Self.clientType) is written in changed: the tree writes it in \
            \(sites.members), this suite scans \(Self.clientFiles.sorted()). A file this \
            suite does not scan can widen any member of the actor — including a synchronous \
            internal method with `generation` and `hasEverHandshaken` in scope — and every \
            assertion here stays green. Add it to `clientFiles` and say what it is allowed \
            to widen.
            """
        )
        #expect(
            sites.declarations == [Self.declaringFile],
            """
            \(Self.clientType)'s own declaration is in \(sites.declarations), and \
            `declaringFile` names \(Self.declaringFile). That name is what \
            `theClientsMutableStateStaysPrivate` opens, so a declaration that has moved \
            leaves it asserting about a file the stored state no longer lives in.
            """
        )
    }

    @Test("Every property this client's guards read is private to the file that writes it")
    func theClientsMutableStateStaysPrivate() throws {
        let code = try MemberAccessScan.strippedSource(of: Self.declaringFile)

        for member in Self.mustStayPrivate {
            let declaration = try MemberAccessScan.declaration(
                of: member, in: code, from: Self.declaringFile)
            #expect(
                declaration.hasPrefix("private "),
                """
                `\(declaration)` is no longer private. Every guard in this client turns on \
                one of these seven, and one that is writable from every file in \
                AeolusXPCClient can be satisfied from outside the code that decides it — see \
                HelperClient.swift's own account of why the split #242 asked for was \
                declined, which is the same rule read forwards.
                """
            )
        }
    }

    @Test("Only the acknowledged properties of the XPC client are non-private")
    func onlyTheAcknowledgedPropertiesAreNonPrivate() throws {
        let found = Set(
            try MemberAccessScan.members(in: Self.clientFiles, keyword: .property)
                .filter { !$0.isPrivate }
                .map(\.key))

        #expect(
            found == Self.acknowledgedNonPrivateProperties,
            """
            the non-private properties of HelperClient changed: found \(found.sorted()), \
            acknowledged \(Self.acknowledgedNonPrivateProperties.sorted()). Widening one is \
            a decision about what the rest of AeolusXPCClient may read — or, if it is \
            stored, write — on the client half of the privilege boundary. Say why here, in \
            the suite that records why the acknowledged ones were acceptable.
            """
        )
    }

    @Test("Only the acknowledged methods of the XPC client are non-private")
    func onlyTheAcknowledgedMethodsAreNonPrivate() throws {
        let found = Set(
            try MemberAccessScan.members(in: Self.clientFiles, keyword: .method)
                .filter { !$0.isPrivate }
                .map(\.key))

        #expect(
            found == Self.acknowledgedNonPrivateMethods,
            """
            the non-private methods of HelperClient changed: found \(found.sorted()), \
            acknowledged \(Self.acknowledgedNonPrivateMethods.sorted()). A method of this \
            actor that is not private is callable from every file in AeolusXPCClient, and \
            inside it `connection`, `generation`, `hasEverHandshaken` and the rest are all \
            in scope — say why here.
            """
        )
    }
}
