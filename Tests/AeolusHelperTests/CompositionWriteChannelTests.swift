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
    /// That reads where a declaration begins, never what access its members carry, so a second
    /// half reads the words: no `internal`, `public`, `package` or `open` appears anywhere in the
    /// file's code (#441). `private extension HelperComposition … { internal static func … }`
    /// passed the first half, because the extension is `private` and the member is not.
    ///
    /// **Mutations:** add an internal `static func channel(over:)` in an `extension
    /// AeolusHelperMain`; drop `private` from the entry point; add `@inline(never) func f()` at
    /// file scope; add `private extension HelperComposition where Plane == SMCFanControlPlane {
    /// internal static func daemonGraph(log: HelperLog) -> Self { production(log: log) } }`.
    /// Run: red, each — the last at the access-level expectation, which the first half cannot
    /// see.
    @Test("main's file declares nothing beyond private")
    func mainsFileExposesOnlyTheEntryPoint() throws {
        let code = Self.mainCode(
            try String(
                contentsOf: SeamScanner.sourcesRoot.appendingPathComponent(
                    "AeolusHelper/AeolusHelperMain.swift"),
                encoding: .utf8))
        let exposed = Self.exposedLines(in: code)
        #expect(exposed.isEmpty, "AeolusHelperMain.swift exposes \(exposed) beyond private")
        let widened = try Self.widenedAccess(in: code)
        #expect(
            widened.isEmpty,
            """
            AeolusHelperMain.swift names \(widened). A member spelled that way is reachable from \
            every helper file and, through @testable, every helper test, even inside a private \
            extension or a private type.
            """)
        #expect(
            code.contains("private enum AeolusHelperMain"), "the scan is not reading main's file")
    }

    /// Comments, then string literals: what every scan of main's file reads.
    static func mainCode(_ source: String) -> String {
        WriteSeamTestIsolationTests.strippingStringLiterals(
            SeamScanner.strippingAllComments(source))
    }

    /// An explicit access level that can widen a member past `private`. `private`, `fileprivate`
    /// and `private(set)` are the narrowing ones and are not matched; a longer word is not either.
    static let widenedAccessToken =
        #"(?<![A-Za-z0-9_])(?:internal|public|package|open)(?![A-Za-z0-9_])"#

    /// Every widening access word in `code`, in order.
    static func widenedAccess(in code: String) throws -> [String] {
        try NSRegularExpression(pattern: widenedAccessToken)
            .matches(in: code, range: NSRange(code.startIndex..., in: code))
            .compactMap { Range($0.range, in: code).map { String(code[$0]) } }
    }

    /// **Mutation:** in `widenedAccessToken`, drop `internal|`. Run: red here, at the first
    /// fixture.
    @Test("An explicit internal, public, package or open in main's file is found")
    func widenedAccessIsFound() throws {
        let widening = [
            "private extension HelperComposition where Plane == SMCFanControlPlane {\n"
                + "    internal static func daemonGraph(log: HelperLog) -> Self {\n"
                + "        production(log: log)\n    }\n}",
            "private extension E {\n    public func f() {}\n}",
            "private enum E {\n    package static func f() {}\n}",
            "private class E {\n    open func f() {}\n}",
            "fileprivate extension E {\n    internal(set) var x: Int { 0 }\n}",
            "@main private enum E {\n    static func main() {}\n    internal static let x = 1\n}",
        ]
        for source in widening {
            #expect(try Self.widenedAccess(in: Self.mainCode(source)).count == 1, "\(source)")
        }
        let narrowing = [
            "private extension E {\n    private(set) var openCount = 0\n    func f() {}\n}",
            "fileprivate func reopen(internalState: Int, publicKey: Int, packaged: Int) {}",
            "// internal public package open\nprivate enum E {}",
            "private let words = \"internal public package open\"",
            "private enum E {\n    static func main() { opened(); isOpen = false }\n}",
        ]
        for source in narrowing {
            #expect(try Self.widenedAccess(in: Self.mainCode(source)).isEmpty, "\(source)")
        }
    }

    /// Every line of `code` that is not an `import`, a `}`, a blank, or a declaration whose first
    /// word after its attributes is `private` or `fileprivate`, and every one that cannot be read
    /// as one of those because of how it is laid out. A line holding only attributes joins the
    /// line after it, so `@main` over `private enum` is the private declaration it is, and
    /// `@available(macOS 14, *)` over `func f()` is the exposed one it is. Refused:
    /// - anything else at column 0 — `#if`, an attribute split across lines;
    /// - a `}` with anything after it on its line, since `} ; func f() {}` declares one;
    /// - a line that starts with whitespace while no bracket is open, since an indented `func f()`
    ///   after the last `}` is a file-scope declaration the column-0 rule never reads;
    /// - a `;` outside every bracket, since `private let a = 1; func f() {}` declares one too.
    ///
    /// The last two read the file's layout, and can refuse correct code: a file-scope initialiser
    /// that swift-format wraps after its `=` has an indented second line. They err loud, and this
    /// file has none.
    static func exposedLines(in code: String) -> [String] {
        let attributes = #"^(?:@\w+(?:\([^()\n]*\))?\s*)+"#
        var exposed: [String] = []
        var pending = ""
        var depth = 0
        for raw in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let atFileScope = depth == 0
            let separated = Self.advance(&depth, over: line)
            guard let first = line.first, !first.isWhitespace else {
                if atFileScope, line.contains(where: { !$0.isWhitespace }) { exposed.append(line) }
                continue
            }
            let joined = pending + line
            if line.range(of: attributes + "$", options: .regularExpression) != nil {
                pending = joined + " "
                continue
            }
            pending = ""
            let rest = joined.replacingOccurrences(
                of: attributes, with: "", options: .regularExpression)
            let allowed =
                rest.trimmingCharacters(in: .whitespaces) == "}" || rest.hasPrefix("import ")
                || rest.range(of: #"^(?:private|fileprivate)\s"#, options: .regularExpression)
                    != nil
            if !allowed || separated { exposed.append(joined) }
        }
        if !pending.isEmpty { exposed.append(pending) }
        return exposed
    }

    /// Moves `depth` — how many of `{`, `(` and `[` are open — across `line`, and says whether
    /// the line holds a `;` while none was.
    private static func advance(_ depth: inout Int, over line: String) -> Bool {
        var separated = false
        for character in line {
            switch character {
            case "{", "(", "[": depth += 1
            case "}", ")", "]": depth = max(0, depth - 1)
            case ";" where depth == 0: separated = true
            default: break
            }
        }
        return separated
    }

    /// Each rule has a fixture only it refuses: `} func f() {}` is the `}` rule's (Swift rejects
    /// it, and a lexical rule still should), `private let a = 1; func f() {}` the `;` rule's, and
    /// `} ; func f() {}` is both, so neither mutation of those two rules alone turns it green.
    ///
    /// **Mutations:** in `exposedLines`, accept any line that starts with `@`; compare the `}`
    /// line with `hasPrefix("} ")` again; skip the indented-line refusal; drop the `;` refusal.
    /// Run: red here, each — at its own fixture.
    @Test("An attribute-prefixed, unmarked, indented or semicoloned declaration in main's file")
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
            // #441: a declaration on the line of a `}`, behind a `;`.
            "private enum E {\n} ; func f() {}",
            // …or with nothing between, which Swift rejects and a lexical rule still refuses.
            "private enum E {\n} func f() {}",
            // #441: indented at file scope, after the last `}`, with and without a keyword.
            "private enum E {\n}\n    func f() {}",
            "private enum E {\n}\n\tlet x = 1",
            "    @available(macOS 14, *) func f() {}",
            // #441: a `;` outside every bracket, after a line the column-0 rule allows.
            "private let a = 1; func f() {}",
            "import SMCCore; func f() {}",
            "private enum E {}; func f() {}",
        ]
        for line in exposed {
            #expect(Self.exposedLines(in: line).count == 1, "\(line)")
        }
        let allowed = [
            "import SMCCore", "@preconcurrency import Foundation", "@main\nprivate enum E {", "}",
            "@available(macOS 14, *)\nprivate actor A {", "fileprivate func f() {}",
            "private extension E {", "",
            // Indented inside a body is the ordinary case, and a `;` inside one is not file scope.
            "private enum E {\n    func indented() {}\n    func g() { a(); b() }\n}",
            "private let table = [\n    1,\n    2]",
            "private let value = compute(\n    a: 1,\n    b: 2)",
            "private enum E {\n}\n\n",
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
