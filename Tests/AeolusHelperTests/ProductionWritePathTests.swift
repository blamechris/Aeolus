import Foundation
import Testing

@testable import AeolusHelper

/// The production graph withholds the write path unless the daemon asks for it (ADR 0014's B1
/// amendment, "write capability is what the plane holds").
///
/// The behavioural half is one line: `production()`, as every test that composes the real SMC
/// calls it, holds no channel. The other two halves are source pins, for `HelperCompositionTests`'
/// reason — `main()` never returns and the factory's locals are private, so nothing at runtime can
/// say which connection the channel is, or that the daemon asked.
///
/// This file builds the production graph, so it may name neither the channel's protocol nor the
/// write-path argument in code; the needles below are strings, which every scan here strips.
@Suite("Production withholds the write path unless the daemon asks")
struct ProductionWritePathTests {

    private static let silentLog = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Composition")

    /// **Mutation:** default `writePath` to `.connection`. Run: red.
    @Test("The production graph, built as a test builds it, holds no write channel")
    func theDefaultCompositionHoldsNoChannel() {
        let helper = HelperComposition.production(log: Self.silentLog)
        #expect(
            !helper.plane.holdsWriteChannel,
            """
            HelperComposition.production() gave the plane a write channel. Every test that \
            composes the real SMC calls it this way, and runs bring-up and teardown over it — so \
            once the plane can write, those tests write to this Mac's SMC.
            """)
        #expect(helper.plane.writeCapability == .notBuilt)
    }

    /// **Mutation:** drop the write-path argument from `main()`'s `production` call. Run: red.
    @Test("The daemon is the caller that asks for the write path")
    func theDaemonAsksForTheConnection() throws {
        let main = Self.unwrapped(try Self.code(of: "AeolusHelperMain.swift"))
        let asks = main.contains("HelperComposition.production(log:log," + "writePath:.connection)")
        #expect(asks, "AeolusHelperMain no longer passes the connection as the write path")
    }

    /// One `SMCConnection()` in the factory, and the provider, the plane's recycler and its channel
    /// all built from that local. A channel over a second connection would be a write through a
    /// handle the reads do not use, and the watchdog does not watch.
    ///
    /// **Mutation:** give the channel `SMCConnection()` instead of `connection`. Run: red on the
    /// count and on the channel.
    @Test("The factory builds one connection, and the channel is that local")
    func theFactoryHandsTheChannelItsOneConnection() throws {
        let body = try #require(
            Self.body(
                of: "static func production(", in: try Self.code(of: "HelperComposition.swift")),
            "production(…) is no longer declared")
        let code = Self.unwrapped(body)

        #expect(
            code.components(separatedBy: "SMCConnection(").count == 2,
            "the factory does not build exactly one connection")
        #expect(code.contains("letconnection=SMCConnection()"))
        #expect(code.contains("SMCSensorProvider(connection:connection)"))
        let channelIsTheLocal = code.contains(
            "connection:connection," + "channel:" + "writePath.channel(over:connection))")
        #expect(channelIsTheLocal, "the plane's channel is not the factory's one connection")

        let signature = Self.unwrapped(try Self.code(of: "HelperComposition.swift"))
        #expect(
            signature.contains("writePath:" + "ProductionWritePath=.withheld"),
            "the factory's write path is not withheld by default")
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

    /// The text from `marker` to the brace that closes the body after it.
    private static func body(of marker: String, in code: String) -> String? {
        guard let start = code.range(of: marker),
            let open = code.range(of: "{", range: start.upperBound..<code.endIndex)
        else { return nil }
        var depth = 1
        var index = open.upperBound
        while index < code.endIndex, depth > 0 {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" { depth -= 1 }
            index = code.index(after: index)
        }
        return depth == 0 ? String(code[start.lowerBound..<index]) : nil
    }
}
