import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// No protocol SMCCore declares carries a `write` requirement (ADR 0014's B1 amendment, "the seam
/// is the helper's").
///
/// `SMCConnection.write(_:to:)` is `@_spi(FanWrite)`, and that opt-in is the whole of the write
/// seam's access control ([ADR 0008](../../docs/ADR/0008-write-authorisation.md), 2026-09-06). A
/// protocol is a second route to a member: a requirement the SPI member witnesses is callable
/// through the existential by anything that can name the protocol. Declared **public** in SMCCore,
/// that is `fanctl` and the app, with a plain `import SMCCore` — the gate would gate nothing. The
/// write channel is therefore declared in the helper, internal to it, and this suite holds SMCCore
/// to declaring no protocol that could carry the write instead.
///
/// The scan normalises before it matches: every comment is removed, trailing ones included, every
/// string literal, and every backtick (`` func `write`( `` declares the same name), and the
/// patterns allow whitespace and newlines wherever Swift does. Its positive controls are the one
/// protocol SMCCore declares today, `SensorProvider`, which it must find, and the helper's own
/// `SMCWriteChannel`, whose `write` requirement it must find — so a scan that has stopped reading
/// protocols, or stopped recognising a requirement, cannot report a clean tree.
@Suite("No SMCCore protocol carries the write")
struct WriteChannelSeamTests {

    /// Every protocol declared under `Sources/SMCCore` today. Found, or the scan is not reading the
    /// module.
    static let knownSMCCoreProtocols: Set<String> = ["SensorProvider"]

    @Test("No protocol declared under Sources/SMCCore has a write requirement")
    func noSMCCoreProtocolDeclaresAWrite() throws {
        var found: Set<String> = []
        for file in try SeamScanner.swiftFiles(under: "SMCCore") {
            let code = Self.normalised(try String(contentsOf: file, encoding: .utf8))
            for (name, body) in try Self.protocolBodies(in: code) {
                found.insert(name)
                #expect(
                    try Self.writeRequirements(in: body) == 0,
                    """
                    Sources/SMCCore/\(file.lastPathComponent) declares protocol \(name) with a \
                    write requirement. SMCConnection's SPI write would witness it, and every \
                    module that can name \(name) could then write through the existential — the \
                    SPI gate would gate nothing (ADR 0008, ADR 0014's B1 amendment). The write \
                    channel is the helper's: Sources/AeolusHelper/SMCWriteChannel.swift.
                    """)
            }
        }

        #expect(
            found.isSuperset(of: Self.knownSMCCoreProtocols),
            """
            The protocols found under Sources/SMCCore are \(found.sorted()), which does not \
            include \(Self.knownSMCCoreProtocols.sorted()). The scan is not reading the module's \
            protocols.
            """)
    }

    /// The other half of the positive control: the detector finds the requirement where it is.
    @Test("The scan finds the write requirement the helper's channel declares")
    func theScanFindsTheChannelsRequirement() throws {
        let url = SeamScanner.sourcesRoot.appendingPathComponent(
            "AeolusHelper/SMCWriteChannel.swift")
        let code = Self.normalised(try String(contentsOf: url, encoding: .utf8))
        let body = try #require(
            try Self.protocolBodies(in: code)["SMCWriteChannel"],
            "SMCWriteChannel.swift declares no protocol SMCWriteChannel that this scan can read")
        #expect(try Self.writeRequirements(in: body) == 1)
    }

    // MARK: - No conformance, and one forwarder

    /// `SMCConnection` is not a write channel, checked by the runtime rather than by reading the
    /// source (ADR 0014's B1 seam amendment). A conformance anywhere the runtime can see it — this
    /// target or a test file, any spelling — makes a real connection a channel that every
    /// `@testable` test can write through, with no SPI opt-in.
    ///
    /// **Mutation:** add `@_spi(FanWrite) import SMCCore` and `extension SMCConnection:
    /// SMCWriteChannel {}` to `SMCWriteChannel.swift`. Run: red.
    @Test("SMCConnection conforms to no write channel; the fake does")
    func smcConnectionConformsToNoChannel() {
        #expect(
            !((SMCConnection.self as Any.Type) is any SMCWriteChannel.Type),
            """
            SMCConnection conforms to SMCWriteChannel. Any @testable test can then write through a \
            real connection, or hand one to a write turn, with no FanWrite opt-in — ADR 0014's B1 \
            seam amendment.
            """)
        #expect(
            (FirmwareSMC.self as Any.Type) is any SMCWriteChannel.Type,
            "the check cannot see a conformance at all: the fake should be one")
    }

    /// The forwarder's text, word for word, whitespace and comments aside.
    ///
    /// No test can run `DaemonWriteChannel`: it is `private`, which is the point. So its text is
    /// pinned here, its mechanism is tested on a stand-in written the same way
    /// (`ExecutorSharingTests`), and it is named exactly twice — its declaration and `main`'s
    /// closure — so nothing else in the file can hold one.
    static let forwarder = """
        private actor DaemonWriteChannel: SMCWriteChannel {
            private let connection: SMCConnection
            init(over connection: SMCConnection) { self.connection = connection }
            nonisolated var unownedExecutor: UnownedSerialExecutor { connection.unownedExecutor }
            var interfaceGeneration: SMCInterfaceGeneration? {
                connection.assumeIsolated { $0.interfaceGeneration }
            }
            func freshKeyInfo(for key: SMCKey) throws -> SMCKeyInfo {
                try connection.assumeIsolated { try $0.freshKeyInfo(for: key) }
            }
            func read(_ key: SMCKey) throws -> SMCValue {
                try connection.assumeIsolated { try $0.read(key) }
            }
            func write(_ bytes: [UInt8], to key: SMCKey) throws {
                try connection.assumeIsolated { try $0.write(bytes, to: key) }
            }
        }
        """

    /// **Mutation:** make `DaemonWriteChannel` internal. Run: red.
    @Test("The daemon's forwarder is private, word for word, and named only twice")
    func theForwarderIsPinned() throws {
        let url = SeamScanner.sourcesRoot.appendingPathComponent(
            "AeolusHelper/AeolusHelperMain.swift")
        let code = SeamScanner.strippingAllComments(try String(contentsOf: url, encoding: .utf8))
        let unwrapped = code.filter { !$0.isWhitespace }

        let declared = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])actor\s+DaemonWriteChannel(?![A-Za-z0-9_])"#
        )
        .numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
        #expect(declared == 1, "DaemonWriteChannel is declared \(declared) times, not once")

        // `fileprivate actor …` contains `private actor …`, so either access passes and nothing
        // wider does.
        let privately = unwrapped.contains(Self.forwarder.filter { !$0.isWhitespace })
        #expect(
            privately,
            """
            AeolusHelperMain.swift's DaemonWriteChannel is not the pinned private forwarder. \
            Widened, any helper file — and any @testable test — could build a real write channel.
            """)

        let named = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])DaemonWriteChannel(?![A-Za-z0-9_])"#
        )
        .numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
        #expect(named == 2, "DaemonWriteChannel is named \(named) times, not 2")
    }

    // MARK: - The scanner

    /// `source` with every comment, every string literal and every backtick removed.
    static func normalised(_ source: String) -> String {
        WriteSeamTestIsolationTests.strippingStringLiterals(
            SeamScanner.strippingAllComments(source)
        )
        .replacingOccurrences(of: "`", with: "")
    }

    /// The text between the braces of every `protocol Name … {` in `code`, by name,
    /// brace-balanced. An inheritance clause, a primary associated type and a `where` clause are
    /// all skipped by reading to the first `{`.
    static func protocolBodies(in code: String) throws -> [String: String] {
        let pattern = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])protocol\s+([A-Za-z_]\w*)"#)
        var bodies: [String: String] = [:]
        let whole = NSRange(code.startIndex..., in: code)
        for match in pattern.matches(in: code, range: whole) {
            guard let matched = Range(match.range, in: code),
                let name = Range(match.range(at: 1), in: code),
                let open = code.range(of: "{", range: matched.upperBound..<code.endIndex)
            else { continue }

            var depth = 1
            var index = open.upperBound
            while index < code.endIndex, depth > 0 {
                if code[index] == "{" { depth += 1 }
                if code[index] == "}" { depth -= 1 }
                index = code.index(after: index)
            }
            let close = depth == 0 ? code.index(before: index) : code.endIndex
            bodies[String(code[name])] = String(code[open.upperBound..<close])
        }
        return bodies
    }

    /// How many `func write` requirements `body` declares, generic or not, `static` or not, across
    /// any whitespace.
    static func writeRequirements(in body: String) throws -> Int {
        try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])func\s+write(?![A-Za-z0-9_])"#)
            .numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body))
    }
}

/// The scanner above, on synthetic sources: a scan that silently stops matching reports a clean
/// tree, so it is tested as a guard.
@Suite("The SMCCore protocol scan")
struct WriteChannelSeamScannerTests {

    private static func requirements(_ source: String) throws -> [String: Int] {
        let code = WriteChannelSeamTests.normalised(source)
        return try WriteChannelSeamTests.protocolBodies(in: code)
            .mapValues(WriteChannelSeamTests.writeRequirements(in:))
    }

    @Test("A write requirement is found however it is spelled")
    func everySpellingOfTheRequirementIsFound() throws {
        let spellings = [
            "public protocol P: Actor { func write(_ bytes: [UInt8], to key: SMCKey) throws }",
            "protocol P { func write (_ bytes: [UInt8], to key: SMCKey) throws }",
            "protocol P {\n    func\n    write(_ b: [UInt8], to k: SMCKey) throws\n}",
            "public protocol P: Sendable where Self: AnyObject { func `write`(_ b: [UInt8]) }",
            "protocol P { static func write<T>(_ value: T) throws }",
            "protocol P<Element> { associatedtype Element\n func write(_ e: Element) }",
            "protocol P { var x: Int { get }\n struct Inner {}\n func write() }",
        ]
        for spelling in spellings {
            #expect(try Self.requirements(spelling) == ["P": 1], "\(spelling)")
        }
    }

    @Test("Prose, a string, another name and a member of another type are not a requirement")
    func lookalikesAreNotARequirement() throws {
        let sources = [
            "protocol P { // func write(_ b: [UInt8]) throws\n func read() }",
            "protocol P { /* func write(_ b: [UInt8]) */ func read() }",
            "protocol P { func read() }\nlet s = \"protocol Q { func write() }\"",
            "protocol P { func overwrite(); func writeCapability() }",
            "protocol P { func read() }\nstruct S { func write() {} }",
        ]
        for source in sources {
            #expect(
                try Self.requirements(source).values.allSatisfy { $0 == 0 }, "\(source)")
        }
    }

    @Test("Every protocol in a file is read, each by its own name")
    func everyProtocolIsRead() throws {
        let source = """
            public protocol A: Sendable { func read() }
            protocol B { func write(_ b: [UInt8]) }
            """
        #expect(try Self.requirements(source) == ["A": 0, "B": 1])
    }
}
