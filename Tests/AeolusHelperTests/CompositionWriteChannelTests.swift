import Foundation
import Testing

@testable import AeolusHelper

/// The production graph is given a write channel only by the daemon (ADR 0014's B1 seam
/// amendment), and nothing else can give it one.
///
/// The behavioural half is one require: `production()`, as every test that composes the real SMC
/// calls it, holds no channel. The rest are source pins, for `HelperCompositionTests`' reason —
/// `main()` never returns and the factory's locals are private, so nothing at runtime can say which
/// connection the channel is over, or that the daemon gave it. The needles are strings, which
/// every scan here strips from the source it reads.
@Suite("Only the daemon gives the production graph a write channel")
struct CompositionWriteChannelTests {

    private static let silentLog = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Composition")

    /// **Mutation:** default `writeChannel` to a closure that answers a channel. Run: red.
    @Test("The production graph, built as a test builds it, holds no write channel")
    func theDefaultCompositionHoldsNoChannel() throws {
        let helper = HelperComposition.production(log: Self.silentLog)
        try #require(
            !helper.plane.holdsWriteChannel,
            """
            HelperComposition.production() gave the plane a write channel. Every test that \
            composes the real SMC calls it this way, and runs bring-up and teardown over it — so \
            once the plane can write, those tests write to this Mac's SMC.
            """)
        #expect(helper.plane.writeCapability == .notBuilt)
    }

    /// One contiguous needle, the macOS 14 gate inside it: two needles either side of the gate
    /// left every test green with the gate deleted (#436's delta review).
    ///
    /// **Mutations:** drop the `writeChannel:` argument from `main()`'s `production` call; delete
    /// the `guard #available(macOS 14, *)` line. Run: red, each.
    @Test("The daemon gives the production graph its file-private forwarder, from macOS 14 only")
    func theDaemonGivesTheForwarder() throws {
        let main = Self.unwrapped(try Self.code(of: "AeolusHelperMain.swift"))
        #expect(
            main.contains(
                "HelperComposition.production(log:log,writeChannel:{connectionin"
                    + "guard#available(macOS14,*)else{returnnil}"
                    + "returnDaemonWriteChannel(over:connection)})"),
            "AeolusHelperMain no longer gives the graph DaemonWriteChannel behind the macOS 14 gate"
        )
    }

    /// One connection in the factory, and the provider, the plane's recycler and its channel all
    /// built from that local. A channel over a second connection would be a write through a handle
    /// the reads do not use, and the watchdog does not watch.
    ///
    /// **Mutation:** apply `writeChannel` to `SMCConnection()` instead of `connection`. Run: red.
    @Test("The factory builds one connection, and the channel is built over it")
    func theFactoryHandsTheChannelItsOneConnection() throws {
        let file = try Self.code(of: "HelperComposition.swift")
        let body = try #require(
            Self.body(of: "static func production(", in: file),
            "production(…) is no longer declared")

        let built = try NSRegularExpression(pattern: #"SMCConnection\s*(?:\.\s*init\s*)?\("#)
            .numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body))
        #expect(built == 1, "the factory builds \(built) connections, not one")

        let code = Self.unwrapped(body)
        #expect(code.contains("letconnection=SMCConnection()"))
        #expect(code.contains("SMCSensorProvider(connection:connection)"))
        #expect(
            code.contains(
                "connection:SMCConnectionRecycler(connection:connection),"
                    + "channel:writeChannel(connection))"),
            "the plane's channel is not built over the factory's one connection")
        #expect(
            Self.unwrapped(file).contains(
                "writeChannel:(SMCConnection)->(anySMCWriteChannel)?={_innil}"),
            "the factory's write channel is not withheld by default")
    }

    /// `main`'s file opts into the write SPI, so what it declares beyond `private` is reachable by
    /// every file in the helper — and, through `@testable`, every helper test. Since #436's delta
    /// review that includes the entry point itself, which is `private` (`HelperBuild` holds the
    /// build string it used to).
    ///
    /// **It fails closed** (#436's final review, B2). The scan it replaces listed declarations it
    /// recognised, and never recognised one whose line began with a parenthesised attribute: an
    /// extract-function refactor of `main()` into `@inline(never) func daemonGraph(log:)` at file
    /// scope handed every `@testable` test the daemon's graph with the real forwarder. Now every
    /// column-0 code line must be one this file is allowed — `exposedLines` says which.
    ///
    /// **Mutations:** add an internal `static func channel(over:)` in an `extension
    /// AeolusHelperMain`; drop `private` from the entry point; add `@inline(never) func f()` at
    /// file scope. Run: red, each.
    @Test("main's file declares nothing beyond private")
    func mainsFileExposesOnlyTheEntryPoint() throws {
        let code = WriteSeamTestIsolationTests.strippingStringLiterals(
            SeamScanner.strippingAllComments(
                try String(
                    contentsOf: SeamScanner.sourcesRoot.appendingPathComponent(
                        "AeolusHelper/AeolusHelperMain.swift"),
                    encoding: .utf8)))
        let exposed = Self.exposedLines(in: code)
        #expect(exposed.isEmpty, "AeolusHelperMain.swift exposes \(exposed) beyond private")
        #expect(
            code.contains("private enum AeolusHelperMain"), "the scan is not reading main's file")
    }

    /// Every column-0 line of `code` that is not an `import`, a `}`, a blank, or a declaration
    /// whose first word after its attributes is `private` or `fileprivate`. A line holding only
    /// attributes joins the line after it, so `@main` over `private enum` is the private
    /// declaration it is, and `@available(macOS 14, *)` over `func f()` is the exposed one it is.
    /// Anything else at column 0 — `#if`, an attribute split across lines — is refused.
    static func exposedLines(in code: String) -> [String] {
        let attributes = #"^(?:@\w+(?:\([^()\n]*\))?\s*)+"#
        var exposed: [String] = []
        var pending = ""
        for raw in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard let first = line.first, !first.isWhitespace else { continue }
            let joined = pending + line
            if line.range(of: attributes + "$", options: .regularExpression) != nil {
                pending = joined + " "
                continue
            }
            pending = ""
            let rest = joined.replacingOccurrences(
                of: attributes, with: "", options: .regularExpression)
            let allowed =
                rest == "}" || rest.hasPrefix("} ") || rest.hasPrefix("import ")
                || rest.range(of: #"^(?:private|fileprivate)\s"#, options: .regularExpression)
                    != nil
            if !allowed { exposed.append(joined) }
        }
        if !pending.isEmpty { exposed.append(pending) }
        return exposed
    }

    /// **Mutation:** in `exposedLines`, accept any line that starts with `@`. Run: red here.
    @Test("An attribute-prefixed or unmarked declaration in main's file is exposed")
    func exposedLinesAreFound() {
        let exposed = [
            "@available(macOS 14, *) func runDaemon() {}",
            "@inline(never) func daemonGraph(log: HelperLog) -> Graph {",
            "@available(macOS 14, *) extension HelperComposition {",
            "@available(macOS 14, *)\n@MainActor func runDaemon() {}",
            "extension AeolusHelperMain {",
            "func f() {}",
            "let x = 1",
            "#if DEBUG",
            "public actor A {}",
        ]
        for line in exposed {
            #expect(Self.exposedLines(in: line).count == 1, "\(line)")
        }
        let allowed = [
            "import SMCCore", "@preconcurrency import Foundation", "@main\nprivate enum E {", "}",
            "@available(macOS 14, *)\nprivate actor A {", "fileprivate func f() {}",
            "private extension E {", "    func indented() {}", "",
        ]
        for line in allowed {
            #expect(Self.exposedLines(in: line).isEmpty, "\(line)")
        }
    }

    /// The premise of a require made once, at construction: the plane a composition holds cannot be
    /// replaced, and the channel a plane holds cannot be either.
    ///
    /// **Mutation:** make `HelperComposition.plane` a `var`. Run: red.
    @Test("A composition's plane and a plane's channel are both immutable")
    func theRequiresPremiseHolds() throws {
        let composition = try Self.code(of: "HelperComposition.swift")
        #expect(
            try Self.count(#"(?m)^    let\s+plane\s*:"#, in: composition) == 1,
            "HelperComposition.plane is not a let")
        #expect(try Self.count(#"(?<![A-Za-z0-9_])var\s+plane\b"#, in: composition) == 0)

        let plane = try Self.code(of: "SMCFanControlPlane.swift")
        #expect(
            try Self.count(#"(?m)^    private\s+let\s+writeChannel\s*:"#, in: plane) == 1,
            "SMCFanControlPlane.writeChannel is not a private let")
        let members = MemberAccessScan.members(inSource: plane, keyword: .property)
        #expect(members.filter { $0.name == "writeChannel" }.map(\.isPrivate) == [true])
    }

    // MARK: - Reading the source

    private static func code(of file: String) throws -> String {
        let url = try #require(
            try SeamScanner.swiftFiles().first { $0.lastPathComponent == file },
            "\(file) was not found under Sources/")
        return WriteSeamTestIsolationTests.strippingStringLiterals(
            SeamScanner.strippingAllComments(try String(contentsOf: url, encoding: .utf8)))
    }

    private static func unwrapped(_ code: String) -> String {
        code.filter { !$0.isWhitespace }
    }

    private static func count(_ pattern: String, in code: String) throws -> Int {
        try NSRegularExpression(pattern: pattern)
            .numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// The body of the function `marker` declares: past its parameter list, whose defaults may
    /// hold braces of their own, to the brace that closes the body.
    private static func body(of marker: String, in code: String) -> String? {
        guard let start = code.range(of: marker),
            let close = SeamScanner.closingParenthesis(
                in: code, openingAt: code.index(before: start.upperBound)),
            let open = code[close...].firstIndex(of: "{")
        else { return nil }
        return String(RuleZeroScan.balanced(in: code, from: open))
    }
}
