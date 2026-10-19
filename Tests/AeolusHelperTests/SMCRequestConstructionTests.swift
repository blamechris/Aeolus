import Foundation
import Testing

/// `SMCConnection.Request` is built by its four factories and by nothing else (#433).
///
/// Its initialiser is `private` and written in the struct's body, so Swift synthesises no
/// memberwise one. **That is the control.** Code anywhere else in SMCCore, `SMCConnection.swift`
/// included, that writes `Request(key:selector:data32:dataSize:payload:)` or `.init(…)` does not
/// compile, so no request can carry a selector no factory sends, or a payload that
/// `write(_:to:)`'s size guard never saw. `WritePathAbsenceTests`' selector pin reads declared
/// constants only, and a literal `selector: 6` in such a call would pass it.
///
/// What this suite holds is that the control stays. It catches the init being widened, deleted
/// (which brings the internal memberwise one back), joined by a second, or the factories joined
/// by a fifth. It catches a conformance beyond `Sendable` and `Equatable`, because a protocol can
/// have Swift synthesise an initialiser no member list shows: `Decodable`'s `init(from:)` builds a
/// request with any selector from a JSON object (#447's review, S2). It also catches an extension
/// of `Request`, the one other place an initialiser or a conformance can be written, and an alias,
/// the one way to extend it without its name. It reads source, so a widening a macro expanded is
/// not seen; SMCCore uses none.
@Suite("SMCConnection.Request is built by its factories alone")
struct SMCRequestConstructionTests {

    static let requestFile = "SMCConnectionRequest.swift"

    /// `Request`'s members, in order: the five fields, the one initialiser, the four factories
    /// and the wire bytes.
    static let members = [
        "let key", "let selector", "let data32", "let dataSize", "let payload", "private init",
        "static func readKeyInfo", "static func readIndex", "static func readBytes",
        "static func writeBytes", "var bytes",
    ]

    /// What a declaration is, for the member list: its modifiers, its introducer and its name.
    private static func spelled(_ declaration: DeclarationCensus.Declaration) -> String {
        (declaration.modifiers + [declaration.introducer, declaration.name])
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What `Request` conforms to. Neither synthesises an initialiser.
    static let conformances = ["Sendable", "Equatable"]

    /// **Mutations:** widen the init to internal and build a `Request` directly in
    /// `SMCConnection.swift`. Run: red here. Kept `private`, the same build does not compile. Add
    /// `Decodable` to the conformances and decode a request with selector 6 in
    /// `SMCConnection.swift` (R3). Run: red here, at the conformance check.
    @Test("Request has one initialiser, private, and its factories are the four")
    func theInitialiserIsPrivateAndTheFactoriesAreFour() throws {
        let url = try #require(
            try SeamScanner.swiftFiles(under: "SMCCore").first {
                $0.lastPathComponent == Self.requestFile
            })
        let file = DeclarationCensus.outermost(
            inSource: try String(contentsOf: url, encoding: .utf8))
        #expect(file.unreadable.isEmpty, "\(file.unreadable)")

        // The file declares one thing, `extension SMCConnection`, which declares `Request` alone.
        #expect(file.declarations.map(Self.spelled) == ["extension SMCConnection"])
        let holder = DeclarationCensus.outermost(
            inCode: try #require(file.declarations.first?.body))
        #expect(holder.declarations.map(Self.spelled) == ["struct Request"])
        #expect(
            holder.declarations.first?.conformances == Self.conformances,
            """
            SMCConnection.Request conforms to \(holder.declarations.first?.conformances ?? []), \
            not \(Self.conformances). A conformance can have Swift synthesise an initialiser the \
            member list does not show, as Decodable's init(from:) does.
            """)
        let request = DeclarationCensus.outermost(
            inCode: try #require(holder.declarations.first?.body))
        #expect(request.unreadable.isEmpty, "\(request.unreadable)")

        #expect(
            request.declarations.map(Self.spelled) == Self.members,
            """
            SMCConnection.Request declares \(request.declarations.map(Self.spelled)), not \
            \(Self.members). Its one initialiser must stay private and its factories four: \
            anything else that builds a request can send a selector or a payload size that \
            write(_:to:) never checked.
            """)
        let initialisers = request.declarations.filter { $0.introducer == "init" }
        #expect(initialisers.count == 1)
        #expect(initialisers.allSatisfy { $0.isPrivate }, "\(initialisers.map(Self.spelled))")
    }

    /// `extension SMCConnection.Request`, however it is spaced or prefixed.
    static let extendingRequest =
        #"(?<![A-Za-z0-9_])extension\s+(?:[A-Za-z_]\w*\s*\.\s*)*Request(?![A-Za-z0-9_])"#

    /// `typealias X = SMCConnection.Request`, which an extension of `X` would extend.
    static let aliasingRequest =
        #"(?<![A-Za-z0-9_])typealias\s+\w+\s*(?:<[^=]*>)?\s*=\s*(?:[A-Za-z_]\w*\s*\.\s*)*"#
        + #"Request(?![A-Za-z0-9_])"#

    /// An initialiser in an extension of a struct in the same module may assign its fields
    /// directly, so an extension would be a second way in that the `private` init does not bound.
    ///
    /// **Mutation:** `extension SMCConnection.Request {}` in `SMCConnection.swift`. Run: red here.
    @Test("No file in SMCCore extends Request, or aliases it")
    func nothingElseExtendsTheRequest() throws {
        let files = try SeamScanner.swiftFiles(under: "SMCCore")
        #expect(files.count > 5, "the scan read \(files.count) files, which is not SMCCore")
        for file in files {
            let code = RuleZeroScan.code(of: try String(contentsOf: file, encoding: .utf8))
            for pattern in [Self.extendingRequest, Self.aliasingRequest] {
                #expect(
                    try RuleZeroScan.count(pattern, in: code) == 0,
                    """
                    \(file.lastPathComponent) extends or aliases SMCConnection.Request. An \
                    initialiser there could build a request past the factories.
                    """)
            }
        }
    }

    @Test("The extension and alias patterns find every spelling, and nothing else")
    func thePatternsFindTheirSpellings() throws {
        for source in [
            "extension SMCConnection.Request {}", "extension SMCCore . SMCConnection.Request {",
            "extension Request {}",
        ] {
            #expect(try RuleZeroScan.count(Self.extendingRequest, in: source) == 1, "\(source)")
        }
        for source in ["typealias R = SMCConnection.Request", "typealias R = Request"] {
            #expect(try RuleZeroScan.count(Self.aliasingRequest, in: source) == 1, "\(source)")
        }
        for source in [
            "extension SMCConnection {}", "extension RequestLog {}", "typealias R = Requests",
            "private func call(_ request: Request)",
        ] {
            #expect(try RuleZeroScan.count(Self.extendingRequest, in: source) == 0, "\(source)")
            #expect(try RuleZeroScan.count(Self.aliasingRequest, in: source) == 0, "\(source)")
        }
    }
}
