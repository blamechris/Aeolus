import Foundation
import Testing

/// The client's structural claims — the ones with nothing to observe at runtime, asserted
/// against the source tree instead.
///
/// A source tripwire is this repository's last resort, and each one below says why the
/// behavioural test it would rather be does not exist. Every one of them is about
/// **absence** — a second caller, a second conformer, a second way of taking the proxy, a
/// stored snapshot, a stored lease, a retry, a connection built elsewhere. Absence is what
/// no green run can demonstrate, because the thing that would fail is the thing nobody wrote
/// yet.
///
/// The three added for #238 are the row `CLAUDE.md` gives this target, which #237's body
/// called structural and which was not: "the only `NSXPCConnection` outside the helper",
/// "never runs as root", "holds no fan state … never re-acquires a lease". The pinning half
/// of that row had a tripwire from the start; the rest was the current absence of a stored
/// property, and a fifth one compiles beside the four that are there.
@Suite("What the XPC client's sources must and must not contain")
struct HelperClientSeamTests {

    private static let target = "AeolusXPCClient"

    private static func sources() throws -> [(file: String, code: String)] {
        try SeamScanner.swiftFiles(under: target).map {
            (
                file: $0.lastPathComponent,
                code: SeamScanner.strippingComments(try String(contentsOf: $0, encoding: .utf8))
            )
        }
    }

    /// `restoreAllToAutomatic` is the only verb that reaches a proxy without a handshake,
    /// and the count is what keeps it so.
    ///
    /// Two occurrences of the name: the declaration, and the one call. A behavioural test
    /// can show that *today's* verbs handshake — `helloRunsOncePerConnection` and
    /// `thePanicPathNeedsNoHandshake` between them do — but it cannot fail for a verb added
    /// next year, and the whole point of the gate is that exempting yourself from it is not
    /// a decision an author gets to take quietly.
    ///
    /// The bare name rather than the name with its opening parenthesis, because the one
    /// call site passes a trailing closure and so is not followed by one at all — a detail
    /// that made the first version of this tripwire fire on a correct tree.
    /// `withHandshakenProxy` does not contain this name, so the two gates cannot be
    /// confused for one another.
    ///
    /// **Mutations, one per direction.** Route `restoreAllToAutomatic` through
    /// `withHandshakenProxy` instead: red at one. Route `releaseLease` — a gated verb —
    /// through the unhandshaken gate: red at three. The second is the one no behavioural
    /// test in this suite catches, because every test that calls `releaseLease` has already
    /// handshaken on that connection for an earlier verb; a verb added next year that is
    /// *only* ever called first would not even have that.
    @Test("The unhandshaken proxy has exactly one caller")
    func theUnhandshakenProxyHasExactlyOneCaller() throws {
        var found: [String] = []
        for source in try Self.sources() {
            let occurrences = source.code.components(separatedBy: "withProxy").count - 1
            found.append(contentsOf: Array(repeating: source.file, count: occurrences))
        }

        #expect(
            found.count == 2,
            """
            the unhandshaken gate is named \(found.count) times in Sources/\(Self.target) \
            (\(found.sorted())). Exactly two are correct: the declaration, and \
            `restoreAllToAutomatic`'s single call. Anything else is a verb exempting itself \
            from the handshake gate on the client's side of a boundary whose design is that \
            gates are not optional.
            """)
    }

    /// Exactly one thing in `Sources` can acquire a connection's code-signing requirement,
    /// and it is the one that pins the helper.
    ///
    /// The suite drives the client through a policy that applies no requirement at all,
    /// declared in the test target where production code cannot name it. That arrangement is
    /// only worth anything while `Sources` has no equivalent: a "no requirement" conformer
    /// living beside the real one would be one mis-wired initialiser away from a client that
    /// talks to whoever answered, and every test here would stay green.
    ///
    /// This is the client-side mirror of `ConnectionAdmission`'s own rule, and it is checked
    /// rather than documented because #72's review found the documented version of the same
    /// claim in three files while the diff did not stand behind it.
    ///
    /// **Mutation:** add `struct UnpinnedConnection: HelperConnectionPinning { … }` anywhere
    /// under `Sources`. Run: red.
    @Test("Exactly one connection-pinning policy ships in Sources")
    func exactlyOnePinningPolicyShipsInSources() throws {
        let conformers = try SeamScanner.declarations(
            matching: #"(?:struct|final class|class|actor|enum|extension)\s+\w+\s*:"#
                + #"[^{\n]*\bHelperConnectionPinning\b"#)

        #expect(
            conformers.map(\.text) == ["struct SignedHelperPinning: HelperConnectionPinning"],
            """
            Sources declares \(conformers.map(\.text)). Exactly one conformer may ship, and \
            it is the one that derives, compiles and applies the requirement. A conformer \
            that skipped it would leave every test in this target green while the client \
            trusted whoever answered the mach name.
            """)
    }

    /// The proxy is never taken without an error handler.
    ///
    /// `AeolusXPCProtocol` is explicit that a dropped reply block is the failure case that
    /// matters most: when the connection fails, the block passed with the message is simply
    /// dropped and only the error handler runs. A client that took a bare
    /// `remoteObjectProxy` would have no failure path for exactly that case, and its symptom
    /// is a caller that waits rather than a caller that is told.
    ///
    /// Counted rather than pattern-matched for absence, because
    /// `remoteObjectProxyWithErrorHandler` *contains* the forbidden spelling: the assertion
    /// is that the two counts are equal, so every occurrence of the shorter name is part of
    /// a longer one.
    ///
    /// **Mutation:** change one `remoteObjectProxyWithErrorHandler` to `remoteObjectProxy`.
    /// Run: red — and `aMessageInFlightWhenTheHelperDiesIsARestart` goes red with it, which
    /// is the behavioural half.
    @Test("Every proxy in the client carries an error handler")
    func everyProxyCarriesAnErrorHandler() throws {
        var bare = 0
        var handled = 0
        for source in try Self.sources() {
            bare += source.code.components(separatedBy: "remoteObjectProxy").count - 1
            handled +=
                source.code.components(separatedBy: "remoteObjectProxyWithErrorHandler").count - 1
        }

        #expect(handled > 0, "the client takes no proxy at all")
        #expect(
            bare == handled,
            """
            \(bare - handled) bare `remoteObjectProxy` use(s) in Sources/\(Self.target). When \
            the connection fails, the reply block is dropped and only the error handler runs \
            — a client without one has no failure path for the case that matters most.
            """)
    }

    // MARK: - What the client may not keep

    /// The types a helper's answer **about the fans** arrives in.
    ///
    /// The first two are every `public struct` in `AeolusXPC/AeolusXPCPayload.swift` bar the
    /// lease pair below, and that file is the seam: the payload file is fan state, the
    /// handshake file beside it is not. The distinction is load-bearing rather than tidy —
    /// `negotiatedReply: HelloReply?` is a stored DTO this client is *supposed* to hold, so a
    /// list that forbade "every DTO" would need an exemption by name, and an exemption list is
    /// where the next stored snapshot would have been written.
    ///
    /// The rest are the FanKit types those two embed. `theFanStateListNamesEveryTypeASnapshot`
    /// `Carries` is what keeps that hand-written half honest: it reads `SystemSnapshot`'s own
    /// stored properties and fails if one names a type this list does not.
    static let fanStateTypes = [
        "SystemSnapshot", "SensorSample",
        "Fan", "FanState", "FanReading", "FanSetting",
    ]

    /// The types manual control arrives in. Separate from the list above because the rule they
    /// break is a different one: a stored snapshot is rule 6 (claiming control you do not
    /// have), a stored lease is ADR 0007 (manual control is never silently re-asserted).
    static let leaseTypes = ["Lease", "LeaseRequest"]

    /// The scalars a DTO may carry without being fan state itself.
    ///
    /// Written out so that a DTO growing a field of a *new* type fails
    /// `theFanStateListNamesEveryTypeASnapshotCarries` rather than passing it. Padding this to
    /// silence that failure is a decision an author has to make in the open, which is the
    /// point.
    private static let scalars = [
        "Int", "Double", "Bool", "String", "Date", "TimeInterval", "UUID", "Data",
    ]

    /// **The client keeps no copy of what the helper said about the fans.**
    ///
    /// `CLAUDE.md`'s row for this target says it "holds no fan state", and #237's body called
    /// that structural. It was not: it was the current absence of a stored property, and a
    /// fifth one compiles beside the four that are there. The failure that absence prevents is
    /// rule 6 exactly — `private var lastSnapshot: SystemSnapshot?` added to smooth a UI
    /// flicker, served when `snapshot()` throws `helperNeverAnswered`, and the app renders a
    /// fan speed nothing is honouring. Every test in this package stays green, because nothing
    /// in it can tell a fresh snapshot from a remembered one: both decode.
    ///
    /// Scoped to **stored** declarations outside every function body, which is the whole of
    /// the point. Each verb in `HelperClientVerbs.swift` decodes a `SystemSnapshot` into a
    /// local and returns it, and must go on doing so; the same type on the actor is the defect.
    /// A computed property is not storage either — it can only re-derive what something else
    /// holds, and what it would have to hold is what this forbids.
    ///
    /// **Mutation:** add `private var lastSnapshot: SystemSnapshot?` to `HelperClient`. Run:
    /// red, naming the declaration. **Mutation:** add `private let cached = SystemSnapshot(…)`,
    /// whose type is written nowhere — red too, because `Property.names` reads the initialiser
    /// as well as the type position.
    @Test("The client stores no fan state")
    func theClientStoresNoFanState() throws {
        let stored = try SeamScanner.properties(in: Self.target).filter(\.isStored)
        #expect(!stored.isEmpty, "no stored property was found in Sources/\(Self.target) at all")

        let holding = stored.filter { !$0.names.filter(Self.fanStateTypes.contains).isEmpty }

        #expect(
            holding.isEmpty,
            """
            \(holding.map { "\($0.file): \($0.text)" }.sorted()) stores what the helper said \
            about the fans. A client that can serve a remembered answer will serve one when \
            the fresh one fails, and `CLAUDE.md` rule 6 is that a reported target nothing is \
            honouring is worse than an error, because the user acts on it. The verbs decode \
            these into locals and return them; nothing in this target may keep one.
            """)
    }

    /// **The client stores no lease and no lease identifier**, so there is nothing to renew or
    /// replay with.
    ///
    /// `docs/SAFETY.md` § 4 and ADR 0007 both rule that manual control is not silently
    /// re-asserted, and `HelperClientVerbs` says renewal is the caller's job "because a lease
    /// renewed by the transport layer is a lease nobody is proving they still want". A stored
    /// `LeaseRequest` replayed on `.interrupted` would be exactly that: the fans handed back
    /// to a client that has stopped asking, by the one layer whose whole design is that it
    /// does not decide anything.
    ///
    /// Two halves, because the identifier has no type of its own: `renewLease(id:)` takes a
    /// `UUID`, which is indistinguishable from any other stored `UUID` — the observer tokens
    /// in `observers` are `UUID`s too. So the type half forbids `Lease` and `LeaseRequest`,
    /// and the name half forbids a stored property with `lease` as a **word** in its name.
    ///
    /// A word rather than a substring, split on the camel humps: `wasReleased` contains
    /// "lease" and is not a lease identifier, and a tripwire that fired on it would be
    /// deleted by the third person it inconvenienced. `heldLease`, `leaseID` and
    /// `pendingLeaseRequest` all split to a `lease` word.
    ///
    /// **Mutation:** add `private var heldLease: Lease?` — red on the type half. **Mutation:**
    /// add `private var leaseID: UUID?`, whose type says nothing — red on the name half, which
    /// is the one the type half cannot cover.
    @Test("The client stores no lease and no lease identifier")
    func theClientStoresNoLease() throws {
        let stored = try SeamScanner.properties(in: Self.target).filter(\.isStored)
        #expect(!stored.isEmpty, "no stored property was found in Sources/\(Self.target) at all")

        let byType = stored.filter { !$0.names.filter(Self.leaseTypes.contains).isEmpty }
        let byName = stored.filter { Self.words(of: $0.name).contains("lease") }
        // A set, because the two halves overlap on the declaration that is caught by both —
        // `heldLease: Lease?` is one defect and reads as two in a concatenated list.
        let holding = Set((byType + byName).map { "\($0.file): \($0.text)" }).sorted()

        #expect(
            holding.isEmpty,
            """
            \(holding) stores a lease or \
            the identifier of one. Whatever holds either can replay it after an interruption, \
            and ADR 0007 is that manual control is re-acquired by the caller that still wants \
            it, never re-asserted by the transport. `renewLease(id:)` takes the identifier as \
            an argument for this reason.
            """)
    }

    /// `heldLease` → `["held", "lease"]`. The camel humps, lowercased.
    private static func words(of name: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in name {
            if character.isUppercase, !current.isEmpty {
                words.append(current.lowercased())
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    /// The hand-written half of `fanStateTypes` is complete, judged against the DTO itself.
    ///
    /// The list's first two entries come from a file; the FanKit types they embed are typed
    /// out, and a list typed out by hand is a list that goes stale on the day a DTO grows a
    /// field. So this reads `SystemSnapshot`'s own stored properties and requires every type
    /// they name to be accounted for — on one of the two forbidden lists, or on `scalars`.
    ///
    /// This is the tripwire's **own** mutation, and it is the reason it exists: a
    /// source-scanning guard whose list is short is a guard that always finds nothing, which
    /// is a decoration rather than a guard. Deleting `FanState` from `fanStateTypes` leaves
    /// `theClientStoresNoFanState` green — that is silent. It fails *here*, loudly, whatever
    /// the client currently contains.
    ///
    /// **Mutation:** delete `"FanState"` from `fanStateTypes`. Run: red here, green there.
    @Test("The fan-state list names every type a snapshot carries")
    func theFanStateListNamesEveryTypeASnapshotCarries() throws {
        let body = try SeamScanner.structBody(of: "SystemSnapshot", in: "AeolusXPCPayload.swift")
        let carried =
            SeamScanner
            .properties(inSource: body, file: "AeolusXPCPayload.swift")
            .filter(\.isStored)
            .flatMap(\.names)
        #expect(!carried.isEmpty, "SystemSnapshot's stored properties were not found")

        let accounted = Self.fanStateTypes + Self.leaseTypes + Self.scalars
        let unaccounted = Set(carried).subtracting(accounted).sorted()

        #expect(
            unaccounted.isEmpty,
            """
            `SystemSnapshot` carries \(unaccounted), which neither forbidden list names and \
            `scalars` does not either. A snapshot field of an unlisted type is a snapshot the \
            client may store one field of, so the list grows or `scalars` does — visibly, in \
            this file.
            """)
    }

    // MARK: - What the send path may not do

    /// The two callees that are on the send path without calling into it.
    ///
    /// `sendPath()` derives its population from the callers of `exchange`, which is the right
    /// direction for a verb added next year and the wrong one for these two: both are *called
    /// by* the path and neither names it. They are named because a loop in either is the same
    /// defect — `liveConnection` looping over a refused pinning is the boot-loop amplifier
    /// `HelperClient`'s own documentation argues against, and `translate` looping is the
    /// reconnect ADR 0007 forbids, written at the one point that has a failed message in hand.
    private static let sendPathCallees = ["liveConnection", "translate"]

    /// The names `sendPath()` must reach, so a rename cannot quietly empty the population.
    ///
    /// Every verb is here as well as the gates. A verb that stopped going through a gate would
    /// drop out of the derivation and fail this — which makes it a second, independent check
    /// on the claim `theUnhandshakenProxyHasExactlyOneCaller` counts.
    ///
    /// It is a **floor and not an allowlist**, which is what keeps it from being the usual
    /// list-that-rots: what gets scanned is the derived population, so shortening this cannot
    /// shrink what the test looks at — only stop it noticing that something vanished.
    private static let sendPathFloor: Set<String> = [
        "exchange", "withProxy", "withHandshakenProxy", "handshakenConnection",
        "performHandshake", "liveConnection", "translate",
        "snapshot", "acquireLease", "renewLease", "releaseLease", "apply",
        "restoreAllToAutomatic",
    ]

    /// Every function in the client that reaches a proxy, **derived** from the source.
    ///
    /// The transitive callers of `exchange`, which is the one function that hands a message to
    /// a proxy, plus `sendPathCallees`. Derived rather than listed because a list is exactly
    /// what a verb added next year is not on: the eighth message will be written the way the
    /// other seven are, through a gate, and will be in this population the moment it exists.
    ///
    /// The limits: a function whose **first** declaration in its file has no body — a protocol
    /// requirement — is skipped, because `functionBody(named:inSource:)` takes the first match;
    /// `HelperConnectionPinning`'s requirement is the one in this target, and it is not on the
    /// send path. And the reachability test is a substring one, so it errs **wide**: a body
    /// merely mentioning a name is counted as calling it, which adds a function to the
    /// population rather than dropping one from it.
    private static func sendPath() throws -> [(name: String, file: String, body: String)] {
        let sources = try Dictionary(
            uniqueKeysWithValues: Self.sources().map { ($0.file, $0.code) })
        var bodies: [(name: String, file: String, body: String)] = []
        var seen: Set<String> = []

        for function in try SeamScanner.functions(in: Self.target) {
            guard !seen.contains("\(function.file): \(function.name)"),
                let source = sources[function.file],
                let body = try SeamScanner.functionBody(named: function.name, inSource: source)
            else { continue }
            seen.insert("\(function.file): \(function.name)")
            bodies.append((name: function.name, file: function.file, body: body))
        }

        var reached: Set<String> = ["exchange"]
        var growing = true
        while growing {
            growing = false
            for function in bodies where !reached.contains(function.name) {
                guard reached.contains(where: { function.body.contains($0) }) else { continue }
                reached.insert(function.name)
                growing = true
            }
        }
        reached.formUnion(Self.sendPathCallees)

        return bodies.filter { reached.contains($0.name) }
    }

    /// **Nothing on the send path loops, and nothing on it calls itself.**
    ///
    /// The claim #237's body makes is "no internal retry loop anywhere", and the argument
    /// behind it is not a style preference: a client that retries into a mach name launchd is
    /// restarting a daemon behind is a boot-loop amplifier, and the retry would be invisible to
    /// every caller — a verb that eventually succeeded after three attempts reports exactly
    /// what one that succeeded first time does. There is nothing to observe at runtime, which
    /// is what makes this a source tripwire rather than a test.
    ///
    /// `for`, `while` and `repeat` are the whole of it, and that is a completeness claim rather
    /// than a list of the ones worth catching: every function in this population is `async`,
    /// and a retry has to `await` the thing it is retrying. `forEach` and the other sequence
    /// verbs take a non-`async` closure, so a retried `await` cannot be written with one. What
    /// does escape is **recursion**, so the second half of this test forbids a function on the
    /// path from calling itself — bare or through `self.`, not through `proxy.`, since a verb
    /// and the protocol message it sends share a name by design. Mutual recursion between two
    /// of them is the remaining hole, and it is stated rather than closed.
    ///
    /// **Mutation:** wrap `exchange`'s body in `for attempt in 0..<3 { … }`. Run: red, naming
    /// `exchange`. **Mutation:** make `snapshot()` retry itself —
    /// `if data.isEmpty { return try await snapshot() }`. Run: red on the recursion half, which
    /// the loop half cannot see. **Mutation:** rename `exchange`. Run: red on the floor, which
    /// is what stops a rename from emptying the population silently.
    @Test("Nothing on the send path loops or calls itself")
    func nothingOnTheSendPathRetries() throws {
        let path = try Self.sendPath()
        let loop = try NSRegularExpression(
            pattern: #"(?<=[\s{};])(for|while|repeat)\b(?!\s*\w+\s*:)"#)
        var looping: [String] = []
        var recursive: [String] = []

        for function in path {
            // A leading space, so a loop written as the body's first token is still preceded by
            // something the lookbehind accepts.
            let body = " " + function.body
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            if loop.numberOfMatches(in: body, range: range) > 0 {
                looping.append("\(function.file): \(function.name)")
            }

            let bare = try NSRegularExpression(pattern: #"(?<![\w.])\#(function.name)\s*\("#)
            let qualified = try NSRegularExpression(pattern: #"self\.\#(function.name)\s*\("#)
            let calls =
                bare.numberOfMatches(in: body, range: range)
                + qualified.numberOfMatches(in: body, range: range)
            if calls > 0 { recursive.append("\(function.file): \(function.name)") }
        }

        #expect(
            Self.sendPathFloor.subtracting(path.map(\.name)).isEmpty,
            """
            the send path derived from the source is \(path.map(\.name).sorted()), which does \
            not reach \(Self.sendPathFloor.subtracting(path.map(\.name)).sorted()). Either a \
            verb no longer goes through a gate, or something on the path was renamed — and a \
            population that no longer contains a function is a guard that no longer watches it, \
            silently.
            """)
        #expect(
            looping.isEmpty,
            """
            \(looping.sorted()) loops. A client-side retry is invisible to its caller and \
            amplifies a helper launchd is already restarting; every one of the four situations \
            `HelperClient` gives up a connection in is a teardown, and the caller asks again at \
            its own cadence or does not.
            """)
        #expect(
            recursive.isEmpty,
            """
            \(recursive.sorted()) calls itself. Recursion is the one retry that is not a loop, \
            and it is the same defect: a second attempt this client decided to make, reported \
            to nobody.
            """)
    }

    // MARK: - What the rest of the tree may not do

    /// **This target owns every `NSXPCConnection` outside the helper, and constructs every one
    /// in the tree.**
    ///
    /// `CLAUDE.md`'s row is "the only `NSXPCConnection` outside the helper", and the reason is
    /// the pinning policy two tests above: a connection built anywhere else is a connection
    /// that did not go through `pinnedConnection(over:)`, so it talks to whoever answered the
    /// mach name. A SwiftUI view model that built its own — the shortest path to a preview that
    /// does not need the helper — would compile, would pass, and would be a client of an
    /// unverified peer.
    ///
    /// Two halves. The naming half is the architectural claim: outside `AeolusHelper`, which
    /// receives connections it never builds, only this target may name the type. The
    /// construction half is sharper and is where the risk actually is — exactly one file in
    /// `Sources` calls the initialiser, and it is the transport whose result
    /// `SignedHelperPinning` applies a requirement to.
    ///
    /// Comments are stripped first, which matters here more than usual: `AeolusXPC` discusses
    /// `NSXPCConnection` at length in prose and touches it in none of its code.
    ///
    /// **Mutation:** add `_ = NSXPCConnection(machServiceName: "x")` to a file under
    /// `Sources/AeolusUI`. Run: red on both halves. **Mutation:** add the same line to
    /// `Sources/AeolusHelper` — red on the construction half only, which is the half that says
    /// where a connection may be born.
    @Test("The client target owns every NSXPCConnection in Sources")
    func theClientTargetOwnsEveryConnection() throws {
        let construction = try NSRegularExpression(pattern: #"(?<![\w.])NSXPCConnection\s*\("#)
        var naming: Set<String> = []
        var constructing: Set<String> = []

        for file in try SeamScanner.swiftFiles() {
            let code = SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8))
            guard code.contains("NSXPCConnection") else { continue }
            naming.insert(Self.owningTarget(of: file))
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            if construction.numberOfMatches(in: code, range: range) > 0 {
                constructing.insert(file.lastPathComponent)
            }
        }

        #expect(
            naming.contains(Self.target), "nothing in Sources/\(Self.target) names a connection")
        #expect(
            naming.subtracting(["AeolusHelper", Self.target]).isEmpty,
            """
            \(naming.sorted()) name an `NSXPCConnection`. Only this target may, outside the \
            helper that receives them: a connection reached anywhere else is one that did not \
            go through `pinnedConnection(over:)`, and being able to connect is not \
            authorisation.
            """)
        #expect(
            constructing == ["HelperClientTransport.swift"],
            """
            \(constructing.sorted()) construct an `NSXPCConnection`. Exactly one file may, and \
            it is the transport `SignedHelperPinning` applies the code-signing requirement to — \
            a second construction site is a client of whoever answered the mach name.
            """)
    }

    /// Which target directory under `Sources` a file belongs to.
    private static func owningTarget(of file: URL) -> String {
        file.pathComponents.drop(while: { $0 != "Sources" }).dropFirst().first
            ?? file.lastPathComponent
    }

    /// **No build graph links this target into the root daemon.**
    ///
    /// `CLAUDE.md`'s row says the client "never runs as root", and nothing in the language
    /// enforces that: `HelperClient` compiles perfectly well inside a root daemon, and the
    /// shortest route to one is a helper that wants to talk to *itself* for a reconciliation
    /// pass. What keeps the claim true is that no build graph puts this code in that process,
    /// which is a property of two files rather than of any Swift declaration — so it is checked
    /// at those two files.
    ///
    /// **Both** of them, because they are not redundant: `Package.swift` is what CI builds and
    /// `project.yml` is what generates the Xcode project that produces the shipping helper.
    /// The one previous defect of this exact shape — an access level that compiled under
    /// SwiftPM and broke in the Xcode build — was invisible to CI for the same reason, and the
    /// fix there was to check the thing CI does not run.
    ///
    /// Both halves read the **dependency list** and not the target's declaration, and both
    /// `#require` that they found one. Neither is defensive padding — each stands for a defect
    /// the mutation found in this test's first version, one in each direction:
    ///
    /// - It matched the bare `name: "AeolusHelper",`, which found the `.executable(…)`
    ///   **product** declared forty lines above the target. The region it sliced contained no
    ///   dependencies at all, so adding `"AeolusXPCClient"` to the daemon's real ones left it
    ///   **green**. A test that passed and could not fail.
    /// - Anchoring on `.executableTarget(` fixed that and made it fail on the **clean** tree,
    ///   because a target's declaration runs up to the next target and the comment between
    ///   them is `fanctl`'s — which explains at length why *it* links `AeolusXPCClient`.
    ///
    /// Both were invisible to reading and took one mutation each to find.
    ///
    /// **Mutation:** add `"AeolusXPCClient"` to the `AeolusHelper` target's `dependencies` in
    /// `Package.swift`. Run: red. **Mutation:** add the matching `product: AeolusXPCClient`
    /// entry under `AeolusHelper:` in `project.yml`. Run: red — and green in `Package.swift`,
    /// which is the whole reason both are read.
    @Test("No build graph links the client into the root daemon")
    func theRootDaemonDoesNotLinkTheClient() throws {
        let root = SeamScanner.sourcesRoot.deletingLastPathComponent()

        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        // The `.executableTarget(` prefix is what makes this the **target** rather than the
        // `.executable(` product of the same name declared forty lines above it. The first
        // version of this test matched the bare `name: "AeolusHelper",`, found the product,
        // and sliced a region that could not contain a dependency at all: adding
        // `"AeolusXPCClient"` to the daemon's real `dependencies` left it green. It was a test
        // that passed and could not fail, and the mutation is the only reason it is not still
        // one.
        let daemon = try #require(
            manifest.range(
                of: #"\.executableTarget\(\s*name: "AeolusHelper","#, options: .regularExpression),
            "Package.swift no longer declares an executable target named AeolusHelper")
        let nextTarget =
            manifest.range(
                of: #"\.(?:executableTarget|target|testTarget)\("#, options: .regularExpression,
                range: daemon.upperBound..<manifest.endIndex)?.lowerBound ?? manifest.endIndex
        // The **dependency list**, not the target's whole declaration. The declaration runs up
        // to the next target, and what sits between the two is the comment introducing that
        // one — which, for `fanctl`, explains at length why it links `AeolusXPCClient`. A
        // region-wide search therefore fired on the clean tree, which is the mirror image of
        // the defect above and was found the same way.
        let list = try #require(
            manifest.range(
                of: #"dependencies: \[[^\]]*\]"#, options: .regularExpression,
                range: daemon.upperBound..<nextTarget),
            "the AeolusHelper target in Package.swift declares no dependency list")
        let manifestDependencies = String(manifest[list])

        let project = try String(
            contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let daemonKey = try #require(
            project.range(of: "\n  AeolusHelper:\n"),
            "project.yml no longer declares an AeolusHelper target")
        let nextKey =
            project.range(
                of: #"(?m)^  [A-Za-z]"#, options: .regularExpression,
                range: daemonKey.upperBound..<project.endIndex)?.lowerBound ?? project.endIndex
        let yamlList = try #require(
            project.range(
                of: #"(?m)^    dependencies:$"#, options: .regularExpression,
                range: daemonKey.upperBound..<nextKey),
            "the AeolusHelper target in project.yml declares no dependencies")
        let yamlListEnd =
            project.range(
                of: #"(?m)^    \S"#, options: .regularExpression,
                range: yamlList.upperBound..<nextKey)?.lowerBound ?? nextKey
        let projectDependencies = String(project[yamlList.upperBound..<yamlListEnd])

        #expect(
            !manifestDependencies.contains(Self.target),
            """
            Package.swift links \(Self.target) into the root daemon. Everything in this target \
            then runs as root, including a connection actor whose entire design assumes it does \
            not — and `CLAUDE.md`'s helper row is that the daemon is the only writer, not that \
            it is also a client.
            """)
        #expect(
            !projectDependencies.contains(Self.target),
            """
            project.yml links \(Self.target) into the root daemon. That is the graph the \
            shipping helper is built from, and it is the one CI never builds.
            """)
    }
}
