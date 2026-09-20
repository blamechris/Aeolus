import Foundation
import Testing

/// **What the client's send path may not do** — the third of the client's source-tripwire
/// suites, and the one whose subject is a *derived population* rather than a pattern over the
/// target.
///
/// Split from `HelperClientSeamTests` when it crossed SwiftLint's `type_body_length` error, and
/// along the seam that file already marked. The two next door ask what the client **keeps**
/// (`HelperClientStateSeamTests`) and what its sources and build graphs **contain**; everything
/// here asks what the functions that reach a proxy may not **do**, and answers it from a closure
/// over the call graph that has to be computed before any assertion can be made. The derivation
/// is most of this file, which is why it is the seam: a population that silently shrinks is the
/// failure mode these tests have already had twice, and it belongs next to the tests that rest
/// on it rather than beside tripwires that do not use it.
///
/// `HelperClientSources` holds the one description of "the client's sources", so no suite owns it
/// and there is no second copy of the enumeration these suites exist to police.
@Suite("What the XPC client's send path must not do")
struct HelperClientSendPathSeamTests {

    private static let target = HelperClientSources.target

    private static func sources() throws -> [(file: String, code: String)] {
        try HelperClientSources.all()
    }

    /// The three callees that are on the send path without calling into it.
    ///
    /// The downward half of `sendPath()`'s closure now reaches all three on its own, so this is a
    /// **floor** rather than the derivation it started as: naming them is what makes their absence
    /// a failure instead of a smaller population.
    ///
    /// `liveConnection` looping over a refused pinning is the boot-loop amplifier
    /// `HelperClient`'s own documentation argues against; `translate` looping is the reconnect
    /// ADR 0007 forbids, written at the one point that has a failed message in hand; and
    /// `pinnedConnection` is where the connection is actually built, so a loop there retries
    /// `transport.makeConnection()` against a mach name launchd may be restarting.
    ///
    /// `pinnedConnection` was **not** here, and adding the name alone would have changed
    /// nothing: `functionBody(named:inSource:)` took the first declaration in the file, which is
    /// `HelperConnectionPinning`'s bodiless requirement, so the name resolved to no body and
    /// `sendPath()` dropped it. A three-attempt retry inside `SignedHelperPinning`'s
    /// implementation was green. The scanner takes the first declaration *with a body* now, and
    /// the floor below is what proves the name arrived.
    private static let sendPathCallees = ["liveConnection", "translate", "pinnedConnection"]

    /// The names `sendPath()` must reach, so a rename cannot quietly empty the population.
    ///
    /// Every verb is here as well as the gates. A verb that stopped going through a gate would
    /// drop out of the derivation and fail this — which makes it a second, independent check
    /// on the claim `theUnhandshakenProxyHasExactlyOneCaller` counts.
    ///
    /// It is a **floor and not an allowlist**, which is what keeps it from being the usual
    /// list-that-rots: what gets scanned is the derived population, so shortening this cannot
    /// shrink what the test looks at — only stop it noticing that something vanished.
    ///
    /// `sendPathCallees` is asserted against the population **through this floor**, by the union
    /// the test takes. Without that, a name added to `sendPathCallees` whose body cannot be
    /// found is a silent no-op — which is exactly what `pinnedConnection` was, and the only
    /// reason the other two were not is that they happen to be here as well.
    private static let sendPathFloor: Set<String> = [
        "exchange", "withProxy", "withHandshakenProxy", "handshakenConnection",
        "performHandshake", "liveConnection", "translate", "pinnedConnection",
        "snapshot", "acquireLease", "renewLease", "releaseLease", "apply",
        "restoreAllToAutomatic",
    ]

    /// Every function in the client that reaches a proxy, **derived** from the source.
    ///
    /// `exchange` is the one function that hands a message to a proxy, and the population is its
    /// transitive closure **in both directions**, plus `sendPathCallees`. Derived rather than
    /// listed because a list is exactly what a verb added next year is not on: the eighth message
    /// will be written the way the other seven are, through a gate, and will be in this
    /// population the moment it exists.
    ///
    /// **Both directions, and the downward one is why.** The first version grew upward only —
    /// the transitive *callers* of `exchange` — so a helper factored out one level *below* it was
    /// in neither the derivation nor `sendPathCallees`. Factoring the send into `private func
    /// resend<Answer>(to typed: any AeolusXPCProtocol, …)` whose body is `for _ in 0..<3 { … }`,
    /// and calling it from `exchange`, left this test green: `resend`'s body names nothing on the
    /// path. That is #238's scenario one ordinary refactor away, and writing a retry as its own
    /// small function is at least as natural as writing it inline.
    ///
    /// The downward half is **unrestricted**, and exactly one function in this target needs
    /// saying so out loud: `publish`, whose `for continuation in observers.values` is a fan-out
    /// over the health stream's observers and not a retry of anything. It is named in
    /// `sendPathFanOut` and exempted from the loop half alone — it stays in the population for
    /// the recursion and double-send halves, and the test requires it to be *in* the population,
    /// so the exemption cannot quietly become a no-op. A restriction to `async` callees was the
    /// alternative and is worse: it reads as principled (a retry must `await` what it retries)
    /// and it lets the exact mutation above through, because a `resend` that loops without
    /// awaiting anything is not `async` and is still a retry.
    ///
    /// The limits: a name no declaration of which has a body — a protocol requirement with no
    /// conformer in this target — is skipped, and the floor is what stops that being silent for
    /// any name this test depends on. And the reachability test is call-shaped (`name(` or
    /// `name {`) rather than a bare substring, which no longer counts a body merely *mentioning*
    /// a name — a change that could only shrink the population, which is the direction the floor
    /// watches.
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
        reached.formUnion(Self.sendPathCallees)
        var growing = true
        while growing {
            growing = false
            for function in bodies where !reached.contains(function.name) {
                // Upward: this function calls something already on the path. Downward: something
                // already on the path calls this one.
                let onThePath =
                    try reached.contains { try Self.calls($0, in: function.body) }
                    || bodies.contains {
                        try reached.contains($0.name) && Self.calls(function.name, in: $0.body)
                    }
                guard onThePath else { continue }
                reached.insert(function.name)
                growing = true
            }
        }

        return bodies.filter { reached.contains($0.name) }
    }

    /// How often `name` is **called** in `body`: the name followed by a `(` or a `{`.
    ///
    /// The `{` is not optional. Every gated verb in `HelperClientVerbs.swift` is written `try
    /// await withHandshakenProxy { proxy, resolve in … }`, a trailing closure with no parameter
    /// list at all, so a `name\s*\(` pattern reaches none of them.
    private static func callCount(of name: String, in body: String) throws -> Int {
        let call = try NSRegularExpression(pattern: #"\b\#(name)\s*[({]"#)
        return call.numberOfMatches(
            in: body, range: NSRange(body.startIndex..<body.endIndex, in: body))
    }

    /// Whether `body` calls `name` at all. A separate name rather than an overload differing only
    /// in return type: Swift resolves those by context, and a resolution nobody can see at the
    /// call site is how a helper ends up shadowing the one that was meant.
    private static func calls(_ name: String, in body: String) throws -> Bool {
        try callCount(of: name, in: body) > 0
    }

    /// How often `body` calls `name` **on this object**: unqualified, or through `self.`, never
    /// through a receiver.
    ///
    /// `proxy.snapshot { … }` is the protocol message the verb `snapshot()` sends, and the two
    /// share a name by design — the recursion half below already excludes the qualified spelling
    /// for exactly that reason. The two halves that count *callees* need the same exclusion, and
    /// the second of them found out why: with a send factored into `snapshotFirstAttempt()`, that
    /// helper's body names `withHandshakenProxy` and `proxy.snapshot`, and a receiver-blind count
    /// reads two callees in a function making one attempt. A count that fires on a correct
    /// refactor is the crying-wolf failure this file argues about three times over.
    ///
    /// The population derivation above stays on `callCount`, deliberately: excluding a receiver
    /// there could only *shrink* the set a tripwire scans, and a shrinking population is the
    /// failure `sendPathFloor` exists to catch rather than one to introduce.
    private static func localCallCount(of name: String, in body: String) throws -> Int {
        let bare = try NSRegularExpression(pattern: #"(?<![\w.])\#(name)\s*[({]"#)
        let qualified = try NSRegularExpression(pattern: #"self\.\#(name)\s*[({]"#)
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return bare.numberOfMatches(in: body, range: range)
            + qualified.numberOfMatches(in: body, range: range)
    }

    /// Every function on the path that **reaches a send**: a gate, or anything whose body calls
    /// one of these.
    ///
    /// Derived by the same fixpoint `sendPath()` uses, and for the same reason — a list would not
    /// have the function that was factored out this morning on it. This is what lets the
    /// second-attempt half count a send a body makes *through a helper* rather than only one it
    /// spells with a gate's own name.
    ///
    /// It is not a second population: it is a subset of `sendPath()`, so a function that drops out
    /// of the path drops out of here too and the floor is what notices.
    private static func sendReaching(
        in path: [(name: String, file: String, body: String)]
    ) throws -> Set<String> {
        var reaching = Set(Self.sendGates)
        var growing = true
        while growing {
            growing = false
            for function in path where !reaching.contains(function.name) {
                guard try reaching.contains(where: { try Self.calls($0, in: function.body) })
                else { continue }
                reaching.insert(function.name)
                growing = true
            }
        }
        return reaching
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
    /// and the protocol message it sends share a name by design. It shares
    /// `localCallCount(of:in:)` with the two halves below rather than spelling that rule a second
    /// time, which also counts a recursive call written with a trailing closure — `snapshot { … }`
    /// — where the previous pattern required a `(`.
    ///
    /// The third half is a **second send in one body**, and it is the retry an author actually
    /// writes: `do { … } catch { /* second attempt */ … }` around the same gate is neither a loop
    /// nor recursion, so the completeness argument above did not reach it and the two halves were
    /// green with a two-attempt `snapshot()` in the tree. Counting the gate calls per body is the
    /// pattern this file already uses for `withProxy`; here it is per derived body rather than
    /// per file, so a second attempt is caught in whichever verb wrote it.
    ///
    /// The fourth half counts a second attempt made **through a helper**, and it exists because
    /// the third half counts the *gates' own names* and nothing else. One ordinary refactor
    /// escapes all three of the above: lift the send into `private func snapshotOnce() async
    /// throws -> Data` and call it from both arms of a `do`/`catch`. The verb's body then names no
    /// gate at all — zero, not two — the helper's body names one, neither loops, and neither
    /// calls itself. Verified against this tree, not reasoned about: with exactly that written into
    /// `HelperClientVerbs.swift`, all three halves were green. It is the same defect as the third
    /// half one level down, and it is the *more* likely spelling, because a second attempt that
    /// has to be written twice is the one an author factors out.
    ///
    /// So the population's send-reaching functions are derived — `sendReaching(in:)` — and **no
    /// body may call the same one twice.** Per callee rather than summed, because a sum is wrong
    /// here: `withHandshakenProxy` legitimately calls `handshakenConnection` and `exchange`, which
    /// is a handshake and a message, two sends by design. A function excludes itself, since
    /// calling itself at all is the recursion half.
    ///
    /// The fifth half is **two different helpers**, and it exists because the fourth counts one
    /// callee twice and nothing else. The same refactor, written the way a `do`/`catch` invites —
    /// one helper per arm, `snapshotFirstAttempt()` in the `do` and `snapshotSecondAttempt()` in
    /// the `catch` — calls each of them exactly once, so the fourth half reads one and one. That
    /// was verified against this tree rather than reasoned about: with exactly that written into
    /// `HelperClientVerbs.swift`, **all four** halves above were green on a real two-attempt
    /// `snapshot()`. The previous version of this paragraph said mutual recursion was "the
    /// remaining hole", which was a completeness claim and was false — two distinct helpers need
    /// no recursion at all, and writing the second attempt as its own function is the *more*
    /// natural spelling once the first exists.
    ///
    /// So a body may reach at most **one** send-reaching function, counted distinctly. Exactly
    /// one body in this target legitimately reaches two — `withHandshakenProxy`, whose
    /// `handshakenConnection` and `exchange` are a handshake and a message — and it is named in
    /// `sendPathHandshakeGate` rather than inferred, on the same terms as `sendPathFanOut`: it is
    /// on `sendPathFloor`, so a rename reddens the floor rather than emptying the exemption, and
    /// it is still scanned by all four halves above, so a *repeated* call inside it is still a
    /// retry. Mutual recursion between two functions on the path remains the stated hole — a pair
    /// that call each other, each once — and it is the last shape here that is stated rather than
    /// closed.
    ///
    /// **Mutation:** wrap `exchange`'s body in `for attempt in 0..<3 { … }`. Run: red, naming
    /// `exchange`. **Mutation:** write the same loop with a typed binding, `for attempt: Int in
    /// 0..<3 { … }`. Run: red — which it was **not** while the loop pattern carried a `(?!\s*\w+
    /// \s*:)` lookahead meant for a parameter label. **Mutation:** make `snapshot()` retry itself
    /// — `if data.isEmpty { return try await snapshot() }`. Run: red on the recursion half, which
    /// the loop half cannot see. **Mutation:** give `snapshot()` a second
    /// `withHandshakenProxy { … }` in a `catch`. Run: red on the count, which neither other half
    /// sees. **Mutation:** factor that second attempt into `private func snapshotOnce() async
    /// throws -> Data` and call it from both arms of the `do`/`catch`. Run: red on the fourth
    /// half, which is the **only** one that sees it — the other three were green with it in the
    /// tree. **Mutation:** write that second attempt as a *second* helper instead —
    /// `snapshotFirstAttempt()` in the `do` and `snapshotSecondAttempt()` in the `catch`. Run: red
    /// on the fifth half, which is the only one that sees it; the other four were green with a
    /// real two-attempt `snapshot()` in the tree. **Mutation:** rename `exchange`. Run: red on the
    /// floor, which is what stops a rename from emptying the population silently.
    @Test("Nothing on the send path loops or calls itself")
    func nothingOnTheSendPathRetries() throws {
        let path = try Self.sendPath()
        let reaching = try Self.sendReaching(in: path)
        let found = try Self.retries(on: path, reaching: reaching)

        #expect(
            Self.sendPathFloor.union(Self.sendPathCallees).subtracting(path.map(\.name)).isEmpty,
            """
            the send path derived from the source is \(path.map(\.name).sorted()), which does \
            not reach \
            \(Self.sendPathFloor.union(Self.sendPathCallees).subtracting(path.map(\.name)).sorted()). \
            Either a verb no longer goes through a gate, or something on the path was renamed, or \
            a name this test asks for resolved to no body — and a population that no longer \
            contains a function is a guard that no longer watches it, silently.
            """)
        #expect(
            found.looping.isEmpty,
            """
            \(found.looping.sorted()) loops. A client-side retry is invisible to its caller and \
            amplifies a helper launchd is already restarting; every one of the four situations \
            `HelperClient` gives up a connection in is a teardown, and the caller asks again at \
            its own cadence or does not.
            """)
        #expect(
            found.recursive.isEmpty,
            """
            \(found.recursive.sorted()) calls itself. Recursion is the one retry that is not a loop, \
            and it is the same defect: a second attempt this client decided to make, reported \
            to nobody.
            """)
        #expect(
            found.sendingTwice.isEmpty,
            """
            \(found.sendingTwice.sorted()) reaches a gate more than once. That is the retry an author \
            writes without a loop and without recursion — a second attempt in a `catch` — and it \
            is the same defect for the same reason: the caller cannot tell a verb that succeeded \
            first time from one that succeeded on the second try.
            """)
        #expect(
            !reaching.subtracting(Self.sendGates).isEmpty,
            """
            the send-reaching set derived from the source is exactly the gates \
            \(Self.sendGates.sorted()), so the half below can only see a body that names a gate \
            twice — which is what the half above already does. The fixpoint reached no helper, \
            and a check fed by a set that reached no helper cannot see a retry factored into one.
            """)
        #expect(
            found.attemptingTwice.isEmpty,
            """
            \(found.attemptingTwice.sorted()) calls the same send-reaching function twice. A second \
            attempt factored into its own helper and called from two branches names no gate in \
            the body that retries, so the gate count above reads zero for it — and it is the \
            spelling an author reaches for, because a second attempt that has to be written \
            twice is the one that gets lifted out. It is still a retry this client decided to \
            make and reported to nobody.
            """)
        #expect(
            found.branchingTwice.isEmpty,
            """
            \(found.branchingTwice.sorted()) reaches two different send-reaching functions. A second \
            attempt written as its own helper per branch — one in the `do`, one in the `catch` — \
            calls each of them exactly once, so every count above reads one and the retry is \
            invisible to all of them. Only `withHandshakenProxy` may reach two, because a \
            handshake and a message are two sends by design; anything else is a client deciding \
            to try again and telling nobody.
            """)
    }

    /// The one body that legitimately reaches **two** send-reaching functions.
    ///
    /// `withHandshakenProxy` calls `handshakenConnection` and then `exchange`: a handshake and a
    /// message, which is the gate's whole job rather than a second attempt at the first. Every
    /// other body on the path reaches at most one.
    ///
    /// Named rather than inferred, on the same terms as `sendPathFanOut` — and guarded the same
    /// way, by two things that already exist rather than by a third test. It is on
    /// `sendPathFloor`, so a rename reddens the floor instead of leaving an exemption that covers
    /// nothing; and it is still scanned by all four halves above, so a version of it that called
    /// either callee **twice** is still caught. What the exemption buys is the one shape a count
    /// cannot distinguish from a retry, and nothing more.
    private static let sendPathHandshakeGate = ["withHandshakenProxy"]

    /// One pass over the population, classifying each body into the five halves above.
    ///
    /// Extracted from the test rather than written inline, because the test crossed SwiftLint's
    /// `function_body_length` error when the fifth half arrived. The seam is the honest one: this
    /// derives the findings and the test asserts on them, so the five `#expect`s each name what
    /// they rule out instead of sharing one loop with them.
    private struct Retries {
        var looping: [String] = []
        var recursive: [String] = []
        var sendingTwice: [String] = []
        var attemptingTwice: [String] = []
        var branchingTwice: [String] = []
    }

    private static func retries(
        on path: [(name: String, file: String, body: String)], reaching: Set<String>
    ) throws -> Retries {
        let loop = try NSRegularExpression(pattern: Self.loopPattern)
        var found = Retries()

        for function in path {
            // A leading space, so a loop written as the body's first token is still preceded by
            // something the lookbehind accepts.
            let body = " " + function.body
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            if loop.numberOfMatches(in: body, range: range) > 0,
                !Self.sendPathFanOut.contains(function.name)
            {
                found.looping.append("\(function.file): \(function.name)")
            }

            if try Self.localCallCount(of: function.name, in: body) > 0 {
                found.recursive.append("\(function.file): \(function.name)")
            }

            let sends = try Self.sendGates.reduce(0) {
                $0 + (try Self.callCount(of: $1, in: function.body))
            }
            if sends > 1 { found.sendingTwice.append("\(function.file): \(function.name)") }

            let called =
                try reaching
                .subtracting([function.name])
                .filter { try Self.localCallCount(of: $0, in: function.body) > 0 }
                .sorted()
            let repeated = try called.filter {
                try Self.localCallCount(of: $0, in: function.body) > 1
            }
            if !repeated.isEmpty {
                found.attemptingTwice.append(
                    "\(function.file): \(function.name) calls \(repeated)")
            }
            if called.count > 1, !Self.sendPathHandshakeGate.contains(function.name) {
                found.branchingTwice.append("\(function.file): \(function.name) calls \(called)")
            }
        }
        return found
    }

    /// The gates a body may call at most once. `exchange` is the send itself; the two `withProxy`
    /// spellings are the only ways to reach it.
    private static let sendGates = ["exchange", "withProxy", "withHandshakenProxy"]

    /// The one function on the path whose loop is a **fan-out** rather than a retry.
    ///
    /// `publish`'s `for continuation in observers.values` yields one health value to every
    /// observer of the stream; it retries nothing and sends nothing. It is on the path because
    /// `liveConnection`, `performHandshake` and `discardConnection` all call it, which is the
    /// price of closing the path downward — and paying that price out loud, for one named
    /// function, is better than the `async`-only restriction that would have hidden it along with
    /// a `resend` that loops.
    ///
    /// Exempted from the **loop half only**. It is still scanned for recursion and for a second
    /// send, and `theSendPathFanOutIsOnThePath` requires it to be in the population — so a rename
    /// turns this into a red test rather than into a silently empty exemption.
    private static let sendPathFanOut = ["publish"]

    /// The fan-out exemption names a function that is really there, and really has nothing to
    /// send.
    ///
    /// An exemption list is where the next retry gets written, so this is the guard on the guard:
    /// a name here that has left the population is an exemption covering nothing, and a name here
    /// that reaches a gate is a send site exempted from the loop rule.
    ///
    /// **Mutation:** rename `publish`. Run: red here. **Mutation:** add `try await
    /// withHandshakenProxy { … }` to `publish`'s body. Run: red here.
    @Test("The fan-out exemption names a function on the path that sends nothing")
    func theSendPathFanOutIsOnThePath() throws {
        let path = try Self.sendPath()

        for name in Self.sendPathFanOut {
            let function = try #require(
                path.first { $0.name == name },
                """
                \(name) is exempted from the loop rule and is not on the send path. An exemption \
                covering nothing is an exemption that has stopped saying what it meant, and the \
                loop it was written for is now either gone or unwatched.
                """)
            let sends = try Self.sendGates.reduce(0) {
                $0 + (try Self.callCount(of: $1, in: function.body))
            }
            #expect(
                sends == 0,
                """
                \(name) reaches a gate and is exempted from the loop rule. It is on this list \
                because it fans a health value out to observers and sends nothing; a version of \
                it that sends is a retry loop with a written permission slip.
                """)
        }
    }

    /// What counts as a loop, extracted so `theLoopPatternReadsLoopsAndNotLabels` can pin it.
    ///
    /// `while` and `repeat` are taken bare: both are Swift keywords, so neither can be an
    /// argument label without backticks, and the lookahead the first version applied to all three
    /// bought nothing on those two.
    ///
    /// `for` needs its `in`, and that is the fix rather than a refinement. The first version was
    /// `(for|while|repeat)\b(?!\s*\w+\s*:)`, whose lookahead was there to skip an argument label
    /// — `func send(for name: String)` — and which also skipped a loop binding written with a
    /// type: `for attempt: Int in 0..<3 { … }` inside `exchange` left this test **green**, one
    /// word away from the mutation the body cites as red. Requiring the `in` separates the two
    /// without a lookahead. The scan stops at a `{`, `}` or `;` so it cannot run out of a header
    /// into a body.
    ///
    /// **The `in` must not be a label either**, which is the half the previous version of this
    /// comment got wrong. It claimed "a label is `for name:` and never reaches [an `in`]", and
    /// that is only true of a declaration carrying **one** label. `func send(to sink: Sink, for
    /// name: String, in scope: Scope)` reaches one, and so does the call `reset(index, for: fan,
    /// in: container)`. Both read as loops, in the direction that fires on a correct tree — which
    /// is how a tripwire earns a reputation for crying wolf and then gets deleted, and this file
    /// makes that argument about three other patterns.
    ///
    /// What separates them is what may **follow** the `in`. A parameter's is followed by a name
    /// and a colon — `in scope: Scope` in a declaration, `in:` in a call — and a loop's is
    /// followed by the expression it iterates, whose first token is never an identifier ending in
    /// a colon: `in 0..<3`, `in pairs`, `in observers.values`, `in [key: value]`, `in f(a: 1)`.
    /// So `\bin\b(?!\s*\w*\s*:)` refuses both label shapes with the `\w*` collapsing to nothing
    /// for the call form, and keeps every loop spelling in the fixtures below. A bare `(?!\s*:)`
    /// is **not** enough and was the first attempt: it reads the call correctly and the
    /// declaration not at all, because a declaration's colon sits after the internal name.
    static let loopPattern =
        #"(?<=[\s{};])(?:while|repeat)\b|(?<=[\s{};])for\b[^{};]*?\bin\b(?!\s*\w*\s*:)"#

    /// The loop pattern reads loops and not argument labels — **fixtures, because nothing else
    /// pins it.**
    ///
    /// Every other claim in this file is asserted against `Sources`, which is exactly why this
    /// pattern went wrong: the tree contains no typed loop binding, so the tree could not say the
    /// pattern missed one. `SeamScannerScopeParsingTests` covers the parser's own shapes and
    /// never this regex.
    ///
    /// **Mutation:** restore the `(?!\s*\w+\s*:)` lookahead. Run: red on the typed binding.
    /// **Mutation:** drop the `\bin\b` requirement. Run: red on the argument label.
    /// **Mutation:** drop the `(?!\s*\w*\s*:)` after it. Run: red on the two-label declaration and
    /// the two-label call, which the `\bin\b` requirement alone reads as loops. **Mutation:**
    /// narrow it to `(?!\s*:)`. Run: red on the declaration alone, which is the half a colon after
    /// the internal name hides.
    @Test("The loop pattern reads loops and not argument labels")
    func theLoopPatternReadsLoopsAndNotLabels() throws {
        let loop = try NSRegularExpression(pattern: Self.loopPattern)
        func matches(_ code: String) -> Bool {
            let body = " " + code
            return loop.numberOfMatches(
                in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)) > 0
        }

        for retry in [
            "for attempt in 0..<3 { _ = attempt }",
            "for attempt: Int in 0..<3 { _ = attempt }",
            "for (index, value) in pairs { _ = value }",
            "while !done { done = true }",
            "repeat { done = true } while !done",
            "{ for _ in 0..<3 { send() } }",
        ] {
            #expect(matches(retry), "\(retry) is a loop and this pattern does not read it")
        }

        // A `for` the lookbehind actually reaches: preceded by a space rather than by the `(` of
        // a call, which is the shape the old lookahead was written for. A negative fixture whose
        // `for` sits immediately after `(` proves nothing — the lookbehind refuses it before any
        // of this is consulted, and two of the first drafts here were exactly that.
        for notALoop in [
            "func send(to sink: Sink, for name: String) { }",
            "func reset(index: Int, for fan: Fan) async throws -> Fan { fan }",
            "reset(index, for: fan) { error in resolve(error) }",
            "let deadline = deadlines.forVerb",
            // A second label named `in`, which is what the `\bin\b` requirement alone reads as a
            // loop. Both spellings are ordinary — the declaration is how a verb takes a scope,
            // the call is how one is passed — and both fire on a correct tree.
            "func send(to sink: Sink, for name: String, in scope: Scope) { }",
            "reset(index, for: fan, in: container)",
        ] {
            #expect(!matches(notALoop), "\(notALoop) is not a loop and this pattern reads one")
        }
    }
}
