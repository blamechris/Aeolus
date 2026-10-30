import Foundation
import Testing

/// D36 on `HelperClient`, asserted rather than described.
///
/// ## Why this suite exists
///
/// [#242](https://github.com/blamechris/Aeolus/issues/242) asked whether
/// `HelperClient.swift` should be split at SwiftLint's 400-line warning, and the answer
/// recorded then was no: Swift `private` is file-scoped, so every remaining seam needs a
/// member of the actor reachable from a sibling file, and D36 is that stored state stays
/// `private` and is mutated only from its declaring file.
///
/// That answer was a paragraph, and #128's lesson — the one D36 exists because of — is that
/// a paragraph is not enforcement: the next split has no way to notice it is widening
/// `hasEverHandshaken` rather than adding a file. The two suites that hold the same line
/// elsewhere cover `AeolusHelper` only, and **nothing asserted access anywhere in
/// `AeolusXPCClient` before this suite**: with this file held out and all seven of
/// `HelperClient`'s `private var`s widened to `internal`, the package ran **1581 tests in 242
/// suites, passed**. Declining a refactor and leaving its rule unenforced is the weaker half
/// of the two, so the rule is wired up here instead.
///
/// It is not an argument against ever splitting the file; it tells a split what it is spending,
/// at the moment it spends it. [#600](https://github.com/blamechris/Aeolus/issues/600) moved
/// `translate(_:on:sentAfter:)` to `HelperClient+Translation.swift` and spent three things:
/// `hasEverHandshaken` and `interruptions` went `private(set)`, `discardConnection` `internal`.
/// All four tests below were red on exactly those before this file was updated.
///
/// ## Both directions, for the reason `HelperConnectionSessionAccessTests` gives
///
/// `theClientsMutableStateStaysPrivate` fails when a listed property loses its `private` (or,
/// for the two that are `private(set)`, its `(set)`), when it is no longer declared as written,
/// **and** when a second line of the file matches the same spelling — the three ways a named
/// guard stops naming anything.
/// `onlyTheAcknowledgedPropertiesAreNonPrivate` and its method half are what catch the
/// widening nobody listed, and they scan every file the actor is written in, so a member
/// cannot be widened simply by being written in a new one, or by being made `public`: they
/// compare each member **as spelled** (#604). An `extension`'s own modifier is on no member's
/// line, and is `HelperClientExtensionAccessTests`'s.
///
/// ## What this suite cannot see, stated rather than implied
///
/// It reads access levels, never call sites. The compiler is what actually stops
/// `HelperClientVerbs.swift` assigning to `generation`; this suite's job is to notice the
/// day somebody makes that assignment *possible*. And it is about access alone — the
/// separate question of what the client may **keep** is `HelperClientStateSeamTests`, which
/// forbids a stored snapshot or lease whatever its access level.
///
/// It reads a member at four spaces, so **a new member in the formatter's two-line spelling**
/// — a modifier alone on a line, the declaration under it at eight — is in no population here
/// ([#605](https://github.com/blamechris/Aeolus/issues/605)): a new `public func` written so
/// passes `swift format --strict` and every client access and seam test.
@Suite("The XPC client's own state stays private to HelperClient.swift")
struct HelperClientAccessTests {

    /// The file that declares the storage, and so the only one that can write it.
    private static let declaringFile = "HelperClient.swift"

    /// The type these guards are about, and the target it is written in.
    private static let clientType = "HelperClient"
    private static let clientTarget = "AeolusXPCClient"

    /// All three files `HelperClient`'s members are written in, **sorted**, and checked
    /// against the tree by `theScannedFilesAreEveryFileTheClientIsIn` rather than trusted.
    ///
    /// None declares a second type at the actor's own member indent, the precondition
    /// `MemberAccessScan.members(in:keyword:)` states: `ConnectionGeneration` is nested, so its
    /// two `let`s sit at eight spaces, and the scan matches a type's name whole.
    ///
    /// Written out rather than derived, as the connection session's suite does: a list compared
    /// against the tree is a decision made once, and deriving it would follow a split silently.
    private static let clientFiles = [
        "HelperClient+Translation.swift",
        "HelperClient.swift",
        "HelperClientVerbs.swift",
    ]

    /// Every mutable property this actor has, spelled as declared, and where it has to stay.
    ///
    /// All nine, because unlike the connection session there is no line to draw here: this
    /// *is* the client's state, and each of the nine is an input to a guard that reads it.
    /// Seven are held `private` here and two, `hasEverHandshaken` and `interruptions`, are held
    /// `private(set)` by `mustHaveAPrivateSetter` (#600); the reasons are for all nine. Three
    /// are `let`s whose object is the state: `inFlight` holds every message in flight and starts
    /// and ends their deadlines, and `healthSignal` and `healthStreams` hold the health signal
    /// and its observers (#541).
    ///
    /// - `connection`, `negotiatedReply` and `handshake` are what "is there a live,
    ///   handshaken connection" is answered from. A sibling file that could write
    ///   `negotiatedReply` could mark a connection handshaken that negotiated nothing, and
    ///   `withHandshakenProxy` would then send a gated verb onto it.
    /// - `generation` is the parameter every late-handler guard turns on: read from the wrong
    ///   place, `guard generation == self.generation` becomes `guard x == x`. Writable from a
    ///   second file, the same guard can be satisfied rather than merely defeated.
    /// - `hasEverHandshaken` is the whole of the 4097 classification — `helperRestarted`
    ///   against `helperUnreachable` — and on `Mac16,5` a *refused* connection is reported as
    ///   an interruption too, so it is the only thing separating "the helper restarted under
    ///   me" from "nothing ever answered". Set to `true` from elsewhere, this client invents
    ///   a helper it never spoke to.
    /// - `interruptions` is what `performHandshake` checks before it records a `hello`'s reply
    ///   (#585). Writable from a sibling file, it could be wound back past an interruption, and
    ///   a reply from the process that died recorded: `.handshaken` published for a process
    ///   that is gone, every gated verb after it refused by the replacement.
    /// - `healthSignal` holds the value `health` reports, which `publish` compares against
    ///   before yielding, and the observers it yields to, under a lock of its own (#541). It is
    ///   the only thing that publishes, and its type is not `Sendable`. A sibling file holding
    ///   it could set the value without the comparison, or yield a health nothing had happened
    ///   to: a state nothing had been told about, which is `CLAUDE.md` rule 6 in the one place
    ///   this target exists to serve it. `healthStreams` is its subscribing half, which the
    ///   `nonisolated` `healthUpdates()` reaches; it registers and removes observers only.
    /// - `inFlight` decides when each message's deadline starts, and answers every message
    ///   still in flight when a connection is discarded (#413). A sibling file holding it could
    ///   settle a message the helper has not answered, starting the deadline of the sequenced
    ///   message behind it early: the false cut-off #413 removed, reachable again.
    ///
    /// **Spelled as declared**, so a respelling has to be re-stated here:
    /// `MemberAccessScan.declaration(of:in:from:)` needs the fragment on exactly one line, so a
    /// renamed, moved or reformatted property fails loudly, not as an entry protecting nothing.
    ///
    /// **Mutation:** drop the `private` from `private var negotiatedReply: HelloReply?`. Run: red
    /// on `theClientsMutableStateStaysPrivate` **and** on
    /// `onlyTheAcknowledgedPropertiesAreNonPrivate`: the named guard and the exhaustive one see
    /// the same widening from two directions. **Mutation:** respell `private var generation:
    /// UInt64 = 0` as `= .zero`, still private. Run: red on `theClientsMutableStateStaysPrivate`
    /// **alone**, on zero matches — the list-rot half, which the exhaustive sibling cannot see
    /// because nothing about the access level changed.
    private static let mustStayPrivate = [
        "var connection: NSXPCConnection?",
        "var negotiatedReply: HelloReply?",
        "var handshake: (task: Task<HelloReply, Error>, hasSent: Bool)?",
        "var generation: UInt64 = 0",
        "let healthSignal: HealthSignal",
        "let healthStreams: HealthSignal.Streams",
        "let inFlight: InFlightMessages",
    ]

    /// The two properties `HelperClient+Translation.swift` reads, whose setters stay `private`.
    ///
    /// `translate(_:on:sentAfter:)` decides on `hasEverHandshaken` and on `interruptions`, so
    /// their getters are readable from a sibling file ([#600](
    /// https://github.com/blamechris/Aeolus/issues/600)), and nothing else about them is: only
    /// `HelperClient.swift` writes them, which is the half of D36 that matters for these two.
    /// `MemberAccessScan` counts `private(set)` as non-private, deliberately, so both are on
    /// `acknowledgedNonPrivateProperties` too, as spelled since #604. This list stays: it judges
    /// the whole declaration, and a widening is argued in two lists, not the one a maintainer is
    /// used to editing.
    ///
    /// **The check is an equality on the whole declaration, not a prefix.** **Mutation:** respell
    /// `private(set) var interruptions: UInt64 = 0` as `var interruptions: UInt64 = 0`. Run: red
    /// on this test **and** on `onlyTheAcknowledgedPropertiesAreNonPrivate`; this one alone
    /// before #604. **Mutation:** `private(set) nonisolated(unsafe) var interruptions: UInt64 =
    /// 0`, which compiles and draws SwiftLint's `modifier_order` and nothing else; and
    /// `private(set) public var interruptions: UInt64 = 0`. Run: each red on the same two. A
    /// prefix check, `hasPrefix("private(set) ")`, passed both with all four tests green, and
    /// the #603 review's probe rewound `interruptions` from a sibling file through an
    /// `as? ReferenceWritableKeyPath` cast.
    ///
    /// **A modifier alone on the line above is part of the declaration** (#604). **Mutation:**
    /// `nonisolated(unsafe)` alone above `private(set) var interruptions`, at four spaces or at
    /// eight, the formatter's own spelling, which `swift format --strict` accepts. Run: red on
    /// the same two each time; at four, the formatter was all that rejected it before.
    ///
    /// **When this fires, keep the declaration bare.** A trailing comment stays in the line
    /// (`SeamScanner.strippingComments` drops whole-line comments only), so `private(set) var
    /// interruptions: UInt64 = 0  // note` is red here, failing closed: put it on the line
    /// above, and leave no modifier-only line over the declaration. Any other respelling is a
    /// widening to review: argue it, then re-state it here and in the acknowledged list.
    private static let mustHaveAPrivateSetter = [
        "var hasEverHandshaken = false",
        "var interruptions: UInt64 = 0",
    ]

    /// Every property of `HelperClient` that is not `private`, **as spelled**, and why.
    ///
    /// An entry is the declaration as `MemberAccessScan` reads it — the modifier run, the
    /// introducer and the name: `public var negotiated`, `var currentGeneration`. On a
    /// privilege boundary a new *public* property is at least as much of an event as a new
    /// internal one, so the list pins how each member is exposed too: `public var
    /// currentGeneration` is a different string and fails like an unlisted property. That
    /// makes "a widening cannot hide by being a bigger one" true, as it was not before #604: the
    /// entries were bare names, so a member acknowledged as `internal` could be made `public`
    /// with the whole suite green. An `internal` written out is a respelling too.
    ///
    /// Four are **get-only computed views** of private storage: `negotiated` and `health` are
    /// the public read API — the second is ADR 0006's switch for the app — and
    /// `currentGeneration` is `internal` for the suite, because the generation is the parameter
    /// every late-handler guard turns on and a test unable to name it could only assert them by
    /// accident. `deadlinesRunning` is `internal` for the suite too (#418's review): a test
    /// moving a hand-wound clock has to know how many deadlines are running before it can know
    /// they have all parked. It reads a count off `inFlight` and can settle nothing. **A stored
    /// property appearing in this list is the failure to argue about**, because that is the
    /// shape that hands a caller an assignment; a computed one can only re-derive what
    /// something in the declaring file still owns.
    ///
    /// The other two are **stored**, and are the argument: `hasEverHandshaken` and
    /// `interruptions` are `private(set)` since [#600](
    /// https://github.com/blamechris/Aeolus/issues/600), because `translate(_:on:sentAfter:)`
    /// decides on both. That hands a caller a read and no assignment, and
    /// `mustHaveAPrivateSetter` holds it to that.
    ///
    /// **Mutation:** drop the `private` from `private let deadlines: HelperClientDeadlines`, an
    /// injected `let` on no list here. Run: red on
    /// `onlyTheAcknowledgedPropertiesAreNonPrivate` alone, naming it — which is the half that
    /// catches a widening nobody wrote down. **Mutation:** respell `var currentGeneration` as
    /// `public var currentGeneration`. Run: red on the same test alone, naming both spellings.
    private static let acknowledgedNonPrivateProperties: Set<String> = [
        "public var negotiated",
        "public var health",
        "var currentGeneration",
        "var deadlinesRunning",
        "private(set) var hasEverHandshaken",
        "private(set) var interruptions",
    ]

    /// Every method of `HelperClient` that is not `private`, and what each is.
    ///
    /// Eight are the public API: six verbs in `HelperClientVerbs.swift`, one per message the
    /// protocol has bar `hello` (negotiated privately inside `performHandshake`), the teardown
    /// `disconnect()`, and `healthUpdates()`, the `nonisolated` stream.
    ///
    /// The remaining six are `internal`, and they are the seam #242 asked whether more of
    /// this actor could be expressed over:
    ///
    /// - `withHandshakenProxy` and `withProxy` are the two gates, and they are the answer to
    ///   that question — the verbs already work over exactly this interface and reach no
    ///   state through it. `withProxy` is additionally held to one caller by
    ///   `HelperClientSeamTests.theUnhandshakenProxyHasExactlyOneCaller`.
    /// - `translate(_:on:sentAfter:)`, `connectionWasInterrupted` and `connectionWasInvalidated`
    ///   are `internal` so the suite can reach them, and each says so where it is declared: the
    ///   two handlers are libxpc's entry points into this actor, the interleaving `generation`
    ///   exists to survive cannot be provoked on demand over a real connection, and one arm of
    ///   `translate` — `NSXPCConnectionReplyInvalid` — cannot be provoked at all.
    /// - `discardConnection(_:as:answering:)` is `internal` for `translate`, which moved out in
    ///   [#600](https://github.com/blamechris/Aeolus/issues/600) and calls it for the three arms
    ///   that cost the connection. It is the one function that invalidates the connection and
    ///   moves the generation, so it is the widest of the six.
    ///
    /// **These four are the ones to argue about**: unlike the gates each mutates the storage
    /// above, so a fifth internal method reaching it is a decision, not a convenience.
    ///
    /// **Spelled as declarations, with signatures**, for the reason #236 established on the
    /// connection session: a bare-name key cannot see a second method that reuses a name, and
    /// `translate(_ error: Error, on generation: UInt64, force: Bool)` written beside this one
    /// would land on the existing entry. The parameter types are in the key because labels
    /// alone cannot see an overload either, and the modifier run is in front of it because the
    /// key cannot see an access level (#604). The longest keys are written as adjacent literals
    /// to stay inside the line limit; they concatenate to the exact spelling, and the test fails
    /// naming both sides if they ever do not.
    ///
    /// **Mutation:** drop the `private` from `private func publish(_ health:
    /// HelperConnectionHealth)`, the one way the health changes. Run: red on
    /// `onlyTheAcknowledgedMethodsAreNonPrivate` alone, naming
    /// `func publish(_: HelperConnectionHealth)`. **Mutation:** `public func
    /// discardConnection(` (AMY), or `public func connectionWasInvalidated(` (AMW), the #604
    /// review's two. Run: red on the same test alone, naming both spellings. Each was green on
    /// the 14 tests of the client access and seam suites before.
    ///
    /// **A limit found by trying it, recorded because it is load-bearing and is not this
    /// suite's doing:** `private func exchange<Answer: Sendable>` cannot be widened at all.
    /// Its `on live: ConnectionGeneration` parameter names a `private` nested type, so the
    /// compiler refuses — *"method must be declared private because its parameter uses a
    /// private type"* — before any test runs. `liveConnection()` and `handshakenConnection()`
    /// return that type and are held the same way: the three functions that thread a
    /// `ConnectionGeneration` are sealed into this file by the type system rather than by a
    /// list, which is worth knowing before designing a split around them.
    private static let acknowledgedNonPrivateMethods: Set<String> = [
        "public func snapshot()",
        "public func acquireLease(_: LeaseRequest)",
        "public func renewLease(id: UUID)",
        "public func releaseLease(id: UUID)",
        "public func apply(_: [FanSetting], leaseID: UUID)",
        "public func restoreAllToAutomatic()",
        "public func disconnect()",
        "nonisolated public func healthUpdates()",
        "func withHandshakenProxy(_: HelperMessage, within: (HelperClientDeadlines) -> Duration, "
            + "_: (any AeolusXPCProtocol, @escaping @Sendable "
            + "(Result<Answer, Error>) -> Void) -> Void)",
        "func withProxy(_: HelperMessage, _: (any AeolusXPCProtocol, @escaping @Sendable "
            + "(Result<Void, Error>) -> Void) -> Void)",
        "func translate(_: Error, on: UInt64, sentAfter: UInt64)",
        "func connectionWasInterrupted(_: UInt64)",
        "func connectionWasInvalidated(_: UInt64)",
        "func discardConnection(_: UInt64, as: HelperConnectionHealth, "
            + "answering: HelperClientError)",
    ]

    /// The file set is a claim about the tree, so it is read off the tree.
    ///
    /// #236's first mutation against the connection session was a fourth file —
    /// `extension HelperConnectionSession { … }` in a file listed nowhere and scanned by
    /// nothing, green across two suites. The same move is the likely shape of a further split
    /// of `HelperClient.swift`: `HelperClientConnection.swift` is how the connection's
    /// lifecycle would leave it. This is what fails when it does. The declaring file is checked
    /// the same way, because `theClientsMutableStateStaysPrivate` opens that one file by name.
    ///
    /// **Mutation:** add `Sources/AeolusXPCClient/HelperClientConnection.swift` holding
    /// `extension HelperClient { func currentHealthForSiblingFile() -> HelperConnectionHealth
    /// { health } }`. Run: red here, naming the file, and across the whole package red nowhere
    /// else but `HelperClientExtensionAccessTests`, which pins the extension headers and has not
    /// been told of this one: two issues, one per test, every other test green. That is the
    /// measurement worth keeping: these are the only two things in the tree that notice.
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
                one of these nine, and one that is reachable from every file in \
                AeolusXPCClient can be satisfied from outside the code that decides it — see \
                HelperClient.swift's own account of where its split stops, which is the same \
                rule read forwards.
                """
            )
        }
        for member in Self.mustHaveAPrivateSetter {
            let declaration = try MemberAccessScan.declaration(
                of: member, in: code, from: Self.declaringFile)
            #expect(
                declaration == "private(set) \(member)",
                """
                `\(declaration)` is not exactly `private(set) \(member)`. A sibling file may read \
                it, as `translate(_:on:sentAfter:)` does, and may not write it: a writable \
                `hasEverHandshaken` invents a helper this client never spoke to, and a \
                writable `interruptions` can be wound back past a death. It is an equality, not \
                a prefix, because a modifier beside `private(set)`, or alone on the line above, \
                can widen it. Keep the declaration bare: no trailing comment (put it on the line \
                above), no modifier line over it. A real respelling is a widening to review, \
                re-stated here and in the acknowledged list.
                """
            )
        }
    }

    @Test("Only the acknowledged properties of the XPC client are non-private")
    func onlyTheAcknowledgedPropertiesAreNonPrivate() throws {
        let found = try MemberAccessScan.nonPrivateSpellings(
            in: Self.clientFiles, keyword: .property)

        #expect(
            found == Self.acknowledgedNonPrivateProperties,
            """
            the non-private properties of HelperClient changed, as spelled: \
            \(MemberAccessScan.difference(found, Self.acknowledgedNonPrivateProperties)). \
            Widening one, or respelling it, is a decision about what the rest of \
            AeolusXPCClient may read — or, if it is stored, write — on the client half of the \
            privilege boundary. Argue it here, and re-state the entry as it is now written.
            """
        )
    }

    @Test("Only the acknowledged methods of the XPC client are non-private")
    func onlyTheAcknowledgedMethodsAreNonPrivate() throws {
        let found = try MemberAccessScan.nonPrivateSpellings(
            in: Self.clientFiles, keyword: .method)

        #expect(
            found == Self.acknowledgedNonPrivateMethods,
            """
            the non-private methods of HelperClient changed, as spelled: \
            \(MemberAccessScan.difference(found, Self.acknowledgedNonPrivateMethods)). A method \
            of this actor that is not private is callable from every file in AeolusXPCClient, \
            and one that is `public` from the app and `fanctl`; inside it `connection`, \
            `generation`, `hasEverHandshaken` and the rest are all in scope. Say why here, and \
            re-state the entry as it is now written.
            """
        )
    }
}
