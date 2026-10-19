import Foundation
import Testing

@testable import SMCCore

/// `SMCConnection.Request` is built by its four factories and by nothing else (#433, #452).
///
/// **Outside `SMCConnectionRequest.swift`, the compiler holds this.** The initialiser is
/// `private` and written in the struct's body, so Swift synthesises no memberwise one, and every
/// field is `private(set)`. Code anywhere else in SMCCore, `SMCConnection.swift` included, that
/// writes `Request(key:selector:data32:dataSize:payload:)` or `.init(…)` does not compile. Nor
/// does an initialiser in an extension that assigns a field, however the extension names the type:
/// `extension (SMCConnection.Request)` and an extension of an alias fail with "setter is
/// inaccessible", as `extension SMCConnection.Request` does. So no request built there can carry
/// a selector no factory sends, or a payload that `write(_:to:)`'s size guard never saw.
/// `WritePathAbsenceTests`' selector pin reads declared constants only, and a literal
/// `selector: 6` in such a call would pass it.
///
/// **Inside that file, this suite is the second layer.** `private` reaches an extension in the
/// same file, so there the compiler refuses nothing. The source pin holds the file to its one
/// declaration and `Request` to its members. It catches the init being widened, deleted (which
/// brings the internal memberwise one back) or joined by a second, a field losing `private(set)`,
/// the factories joined by a fifth, and an extension written beside the type, however its name is
/// spelled. It reads source, so a widening a macro expanded is not seen; SMCCore uses none.
///
/// Conformances are checked twice, because a protocol can have Swift synthesise an initialiser no
/// member list shows: `Decodable`'s `init(from:)` builds a request with any selector from a JSON
/// object (#447's review, S2). The source pin reads the names `Request` lists. The run-time check
/// reads what the type conforms to, so it also sees a `Decodable` that a shadowing typealias
/// hides behind one of those names, or that an extension adds.
@Suite("SMCConnection.Request is built by its factories alone")
struct SMCRequestConstructionTests {

    static let requestFile = "SMCConnectionRequest.swift"

    /// `Request`'s members, in order: the five fields, the one initialiser, the four factories
    /// and the wire bytes. A field written `let` again could be assigned by an initialiser in an
    /// extension in any SMCCore file, which is #452's P1.
    static let members = [
        "private(set) var key", "private(set) var selector", "private(set) var data32",
        "private(set) var dataSize", "private(set) var payload", "private init",
        "static func readKeyInfo", "static func readIndex", "static func readBytes",
        "static func writeBytes", "var bytes",
    ]

    /// What a declaration is, for the member list: its modifiers, its introducer and its name.
    private static func spelled(_ declaration: DeclarationCensus.Declaration) -> String {
        (declaration.modifiers + [declaration.introducer, declaration.name])
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What `Request` conforms to, by the names it lists. Neither synthesises an initialiser. A
    /// name is not what it resolves to, so `theRequestIsNotCodable` checks the type itself.
    static let conformances = ["Sendable", "Equatable"]

    /// **Mutations:** widen the init to internal and build a `Request` directly in
    /// `SMCConnection.swift`. Run: red here. Kept `private`, the same build does not compile. Add
    /// `Decodable` to the conformances (R3). Run: red here, at the conformance check, and at
    /// `theRequestIsNotCodable`. Write the fields `let` again. Run: red here, at the member list.
    /// Append #452's P1, `extension (SMCConnection.Request) { init(rawSelector:) … }`, to
    /// `SMCConnectionRequest.swift` itself, where it compiles. Run: red here, at the file's one
    /// declaration.
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

    /// A struct whose `Decodable` conformance is synthesised, so the check below is seen to answer
    /// yes for one.
    private struct SynthesisedDecodable: Decodable {
        let selector: UInt8
    }

    /// What `Request` conforms to, asked of the type at run time rather than read off its source.
    ///
    /// `Decodable` is the protocol here that synthesises an initialiser, so it has a check of its
    /// own: `Codable` is `Decodable & Encodable`, and a type that is only `Decodable` is not
    /// `Codable`. `Encodable` builds nothing, and is refused because a request is bytes this file
    /// builds and `call(_:)` sends; nothing has a reason to serialise one.
    ///
    /// **Mutations:** in `SMCConnection.swift`, `extension SMCConnection { typealias Equatable =
    /// Swift.Equatable & Swift.Decodable }`, which leaves `Request`'s list reading `Sendable,
    /// Equatable` (#452's P2). Run: red here, at `Decodable`, and nowhere else. Add `Decodable` to
    /// the list (R3). Run: red here, at `Decodable`, and at the conformance check above.
    @Test("Request is not Decodable, Encodable or Codable, whatever its list's names resolve to")
    func theRequestIsNotCodable() {
        let request = SMCConnection.Request.self as Any.Type
        #expect(
            !(request is any Decodable.Type),
            "SMCConnection.Request is Decodable, so init(from:) builds one with any selector.")
        #expect(!(request is any Encodable.Type), "SMCConnection.Request is Encodable.")
        #expect(!(request is any Codable.Type), "SMCConnection.Request is Codable.")

        // The premise: the check answers yes for a type whose conformance is synthesised.
        #expect((SynthesisedDecodable.self as Any.Type) is any Decodable.Type)
    }

    /// `extension SMCConnection.Request`, spaced or prefixed with module and type names. A
    /// parenthesised name, `extension (SMCConnection.Request)`, is not matched, and neither is
    /// every other spelling a lexer would have to know. This scan claims only the plain spellings
    /// an extension is written with by accident. In another file the compiler refuses an
    /// initialiser that assigns a field, whatever the spelling, and in `SMCConnectionRequest.swift`
    /// the file's one-declaration pin above sees any extension.
    static let extendingRequest =
        #"(?<![A-Za-z0-9_])extension\s+(?:[A-Za-z_]\w*\s*\.\s*)*Request(?![A-Za-z0-9_])"#

    /// `typealias X = SMCConnection.Request`, which an extension of `X` would extend.
    static let aliasingRequest =
        #"(?<![A-Za-z0-9_])typealias\s+\w+\s*(?:<[^=]*>)?\s*=\s*(?:[A-Za-z_]\w*\s*\.\s*)*"#
        + #"Request(?![A-Za-z0-9_])"#

    /// `Request`'s members are pinned where it is declared, and an extension in another file adds
    /// members that pin cannot see. Such an extension's initialiser can no longer assign a field,
    /// because the fields are `private(set)` (#452), so the compiler, not this scan, is what keeps
    /// it from building a request no factory built. The scan stays as a cheap check on the plain
    /// spellings.
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
                    \(file.lastPathComponent) extends or aliases SMCConnection.Request. Its \
                    members are pinned in SMCConnectionRequest.swift, and an extension adds \
                    members that pin cannot see.
                    """)
            }
        }
    }

    @Test("The extension and alias patterns find their plain spellings, and nothing else")
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
