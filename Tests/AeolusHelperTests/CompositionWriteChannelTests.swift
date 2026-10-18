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

    /// **Mutation:** drop the `writeChannel:` argument from `main()`'s `production` call. Run: red.
    @Test("The daemon gives the production graph its file-private forwarder")
    func theDaemonGivesTheForwarder() throws {
        let main = Self.unwrapped(try Self.code(of: "AeolusHelperMain.swift"))
        let gives =
            main.contains(
                "HelperComposition.production(log:log,writeChannel:{connectionin")
            && main.contains("returnDaemonWriteChannel(over:connection)})")
        #expect(gives, "AeolusHelperMain no longer gives the graph DaemonWriteChannel")
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
    /// every file in the helper — and, through `@testable`, every helper test.
    ///
    /// **Mutation:** add an internal `static func channel(over:)` to `AeolusHelperMain`. Run: red.
    @Test("main's file declares nothing but the entry point beyond private")
    func mainsFileExposesOnlyTheEntryPoint() throws {
        let code = SeamScanner.strippingAllComments(
            try String(
                contentsOf: SeamScanner.sourcesRoot.appendingPathComponent(
                    "AeolusHelper/AeolusHelperMain.swift"),
                encoding: .utf8))
        var exposed: [String] = []
        let topLevel = try NSRegularExpression(
            pattern: #"(?m)^((?:(?:@\w+|[a-z]+)[ \t]+|@\w+\n)*)"#
                + #"(enum|struct|class|actor|protocol|extension|func|let|var|typealias)\s+(\w+)"#)
        for match in topLevel.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let modifiers = Range(match.range(at: 1), in: code),
                let keyword = Range(match.range(at: 2), in: code),
                let name = Range(match.range(at: 3), in: code)
            else { continue }
            guard !code[modifiers].contains("private") else { continue }
            exposed.append("\(code[keyword]) \(code[name])")
            guard let open = code[name.upperBound...].firstIndex(of: "{") else { continue }
            let body = String(RuleZeroScan.balanced(in: code, from: open))
            for member in MemberAccessScan.members(inSource: body, keyword: .property)
            where !member.isPrivate {
                exposed.append("property \(member.key)")
            }
            for member in MemberAccessScan.members(inSource: body, keyword: .method)
            where !member.isPrivate {
                exposed.append("method \(member.key)")
            }
        }
        #expect(
            exposed.sorted() == ["enum AeolusHelperMain", "method main()", "property build"],
            "AeolusHelperMain.swift exposes \(exposed.sorted()) beyond private")
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
