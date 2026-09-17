import Foundation
import Testing

/// The client's structural claims — the ones with nothing to observe at runtime, asserted
/// against the source tree instead.
///
/// A source tripwire is this repository's last resort, and each one below says why the
/// behavioural test it would rather be does not exist. Every one of them is about
/// **absence** — a second caller, a second conformer, a second way of taking the proxy, a
/// connection built elsewhere. Absence is what no green run can demonstrate, because
/// the thing that would fail is the thing nobody wrote yet.
///
/// Three suites, one row of `CLAUDE.md`, split at SwiftLint's thresholds and along real seams at
/// the same time. What the client may not **keep** is in `HelperClientStateSeamTests`, answered
/// from a declaration's scope and the DTOs the helper replies with. What the client's **send
/// path** may not do is in `HelperClientSendPathSeamTests`, answered from a population derived
/// over the call graph. What is left here asks what this target's sources and its two build
/// graphs must **contain**, and answers from a pattern over `Sources` and a read of `Package.swift`
/// and `project.yml`.
///
/// The three added for #238 are the row `CLAUDE.md` gives this target, which #237's body
/// called structural and which was not: "the only `NSXPCConnection` outside the helper",
/// "never runs as root", "holds no fan state … never re-acquires a lease". The pinning half
/// of that row had a tripwire from the start; the rest was the current absence of a stored
/// property, and a fifth one compiles beside the four that are there.
@Suite("What the XPC client's sources must and must not contain")
struct HelperClientSeamTests {

    private static let target = HelperClientSources.target

    private static func sources() throws -> [(file: String, code: String)] {
        try HelperClientSources.all()
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
    /// Both halves `#require` that they found what they slice, and both carry a **floor** of
    /// the products the daemon does link. Neither is defensive padding — each stands for a
    /// defect the mutation found, and the floor is what the first two had in common:
    ///
    /// - The first version matched the bare `name: "AeolusHelper",`, which found the
    ///   `.executable(…)` **product** declared forty lines above the target. The region it
    ///   sliced contained no dependencies at all, so adding `"AeolusXPCClient"` to the daemon's
    ///   real ones left it **green**. A test that passed and could not fail.
    /// - Anchoring on `.executableTarget(` fixed that and made it fail on the **clean** tree,
    ///   because a target's declaration runs up to the next target and the comment between
    ///   them is `fanctl`'s — which explains at length why *it* links `AeolusXPCClient`.
    /// - The `project.yml` half then sliced from `^    dependencies:$` to the next `^    \S`,
    ///   and `#` is `\S`. This file's own style puts target-level comments at exactly four
    ///   spaces, so one comment line immediately below `dependencies:` collapsed the region to
    ///   nothing and the `product: AeolusXPCClient` below it passed. `ruby -ryaml` confirmed the
    ///   mutated file resolves `AeolusHelper` to `[SMCCore, FanKit, AeolusXPC, AeolusXPCClient]`:
    ///   the graph that builds the shipping helper linked the client, and the half this test's
    ///   own body calls "the one CI never builds" was green. Whole-line comments are stripped
    ///   now, and the floor is what makes an empty region fail rather than pass.
    ///
    /// The `project.yml` half reads the target's **whole region** rather than its dependency
    /// list, and that is the fourth mutation: `- path: Sources/AeolusXPCClient` added to the
    /// same target's `sources:` compiles every line of the client into the root daemon, which is
    /// precisely what the name of this test forbids, and a dependency-list scan cannot see it.
    /// In xcodegen a `sources:` entry is a plausible way for someone to "just include" a file.
    /// Reading the region is only safe because the comments are gone: a region-wide search is
    /// what fired on the clean tree above, and the comment it fired on is the kind that is now
    /// dropped.
    ///
    /// **Mutation:** add `"AeolusXPCClient"` to the `AeolusHelper` target's `dependencies` in
    /// `Package.swift`. Run: red. **Mutation:** add the matching `product: AeolusXPCClient`
    /// entry under `AeolusHelper:` in `project.yml`. Run: red — and green in `Package.swift`,
    /// which is the whole reason both are read. **Mutation:** add `- path:
    /// Sources/AeolusXPCClient` to that target's `sources:`. Run: red, which the dependency-list
    /// version was not. **Mutation:** delete the daemon's `product: FanKit` entry. Run: red on
    /// the floor, which is what a region that shrank to nothing trips.
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

        // Comments first, because everything below reads a whole region rather than one list.
        // A `#` is `\S`, and this file puts its target-level comments at exactly four spaces —
        // which is how one comment line below `dependencies:` collapsed the old region to
        // nothing and let the entry underneath it through.
        let project = Self.strippingWholeLineComments(
            try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8))
        let daemonKey = try #require(
            project.range(of: "\n  AeolusHelper:\n"),
            "project.yml no longer declares an AeolusHelper target")
        // Terminated by the next target key **or by the next top-level key**: `AeolusHelper` is
        // the last target in the file, so a two-space-only terminator runs the region on into
        // `schemes:` and everything after it.
        let nextKey =
            project.range(
                of: #"(?m)^(?:\S|  [A-Za-z])"#, options: .regularExpression,
                range: daemonKey.upperBound..<project.endIndex)?.lowerBound ?? project.endIndex
        let daemonRegion = String(project[daemonKey.upperBound..<nextKey])

        // Both sub-keys, because either one links the client. `dependencies:` is the declared
        // route; `sources:` is the one that compiles the client's files into the daemon directly,
        // and it is the shorter path for someone who only wants to "include" a file.
        for key in ["sources", "dependencies"] {
            _ = try #require(
                daemonRegion.range(of: "(?m)^    \(key):$", options: .regularExpression),
                "the AeolusHelper target in project.yml declares no \(key)")
        }

        #expect(
            !manifestDependencies.contains(Self.target),
            """
            Package.swift links \(Self.target) into the root daemon. Everything in this target \
            then runs as root, including a connection actor whose entire design assumes it does \
            not — and `CLAUDE.md`'s helper row is that the daemon is the only writer, not that \
            it is also a client.
            """)
        #expect(
            !daemonRegion.contains(Self.target),
            """
            project.yml links \(Self.target) into the root daemon, through its `dependencies:` \
            or its `sources:`. That is the graph the shipping helper is built from, and it is \
            the one CI never builds.
            """)

        // The floor. Both halves above assert an **absence** inside a region they sliced, and a
        // region that shrank to nothing satisfies any absence: that is exactly how the first
        // version of the `Package.swift` half and the first version of the `project.yml` half
        // each passed while the daemon really did link the client. What the daemon does link is
        // therefore asserted too, so a slice that lost its content fails instead of passing.
        for product in Self.daemonDependencyFloor {
            #expect(
                manifestDependencies.contains("\"\(product)\""),
                """
                the dependency list this test sliced out of Package.swift does not name \
                \(product), which the root daemon links. The slice is wrong, and an absence \
                asserted over the wrong text is a test that cannot fail.
                """)
            #expect(
                daemonRegion.range(
                    of: "(?m)^\\s*product: \(product)$", options: .regularExpression) != nil,
                """
                the AeolusHelper region this test sliced out of project.yml does not name \
                \(product), which the root daemon links. The slice is wrong, and an absence \
                asserted over the wrong text is a test that cannot fail.
                """)
        }
    }

    /// The products the root daemon links, for the floor above. Three, and none of them is the
    /// client.
    private static let daemonDependencyFloor = ["SMCCore", "FanKit", "AeolusXPC"]

    /// YAML with every whole-line comment removed, lines preserved so the anchored patterns above
    /// still line up.
    ///
    /// Whole-line only, rather than `#`-to-end-of-line: a `#` inside a quoted value is not a
    /// comment, and this is not a YAML parser. The mutation that made it necessary was a
    /// whole-line comment, and this file's own style has no trailing ones.
    private static func strippingWholeLineComments(_ yaml: String) -> String {
        yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? "" : String($0) }
            .joined(separator: "\n")
    }
}
