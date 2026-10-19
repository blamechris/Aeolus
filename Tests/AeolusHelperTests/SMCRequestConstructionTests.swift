import Foundation
import Testing

@testable import SMCCore

/// `SMCConnection.Request` is built by its four factories and by nothing else (#433, #452).
///
/// **Outside `SMCConnectionRequest.swift`, the compiler holds this.** The initialiser is
/// `private` and written in the struct's body, so Swift synthesises no memberwise one. Each field
/// is stored as a `private let` and read through a get-only accessor. Code anywhere else in
/// SMCCore, `SMCConnection.swift` included, that writes
/// `Request(key:selector:data32:dataSize:payload:)` or `.init(…)` does not compile. Nor does an
/// initialiser in an extension that assigns a field, however the extension names the type:
/// `extension (SMCConnection.Request)` and an extension of an alias fail with "'key' is a get-only
/// property", as `extension SMCConnection.Request` does, and the stored names are inaccessible.
/// So no request built there can carry a selector no factory sends, or a payload that
/// `write(_:to:)`'s size guard never saw. `WritePathAbsenceTests`' selector pin reads declared
/// constants only, and a literal `selector: 6` in such a call would pass it.
///
/// **What the compiler does not see, two run-time checks ask.** A key path to a property with a
/// setter is a `WritableKeyPath` at run time even where the setter is out of reach (SR-5218), which
/// is why the fields are not `private(set) var`: `noKeyPathIntoTheRequestIsWritable` holds every
/// accessor, and `bytes`, to a key path no cast can write through. A protocol can have Swift
/// synthesise an initialiser no member list shows: `Decodable`'s `init(from:)` builds a request
/// with any selector from a JSON object (#447's review, S2). The source pin reads the names
/// `Request` lists, and `theRequestIsNotCodable` asks what the type conforms to. Both questions
/// are asked in `StandardLibraryQuery.swift`, which imports nothing, so no name SMCCore declares
/// can change them (#456's review, B2).
///
/// **Inside that file, the source pin is the second layer.** `private` reaches an extension in
/// the same file, so there the compiler refuses nothing. The pin holds the file to its one
/// declaration and `Request` to its members, none with an attribute. It catches the init being
/// widened, deleted (which brings the internal memberwise one back) or joined by a second, a
/// stored field written `var`, the factories joined by a fifth, and an extension written beside
/// the type, however its name is spelled. It reads source, so a widening a macro expanded is not
/// seen; SMCCore uses none.
@Suite("SMCConnection.Request is built by its factories alone")
struct SMCRequestConstructionTests {

    static let requestFile = "SMCConnectionRequest.swift"

    /// `Request`'s members, in order: the five stored fields, their five accessors, the one
    /// initialiser, the four factories and the wire bytes. A stored field written `var` could be
    /// handed out as a writable key path by this file; an accessor's writability is
    /// `noKeyPathIntoTheRequestIsWritable`'s to check, because `var key` reads the same here
    /// whether or not it has a setter.
    static let members = [
        "private let storedKey", "private let storedSelector", "private let storedData32",
        "private let storedDataSize", "private let storedPayload", "var key", "var selector",
        "var data32", "var dataSize", "var payload", "private init", "static func readKeyInfo",
        "static func readIndex", "static func readBytes", "static func writeBytes", "var bytes",
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
    /// `theRequestIsNotCodable`. Append to `SMCConnectionRequest.swift` itself an extension of
    /// `(SMCConnection.Request)` whose initialiser assigns the stored fields, which compiles
    /// there. Run: red here, at the file's one declaration. Mark the `key` accessor
    /// `@usableFromInline`. Run: red here, at the attributes.
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

        // No attribute on `Request` or a member: a property wrapper or a macro can add storage,
        // a setter or an initialiser that the spellings above do not show (#456's review, S1).
        #expect(holder.declarations.first?.attributes == [])
        #expect(
            request.declarations.allSatisfy { $0.attributes.isEmpty },
            "\(request.declarations.filter { !$0.attributes.isEmpty }.map(\.attributes))")
    }

    /// A struct whose `Codable` conformance is synthesised, so each check below is seen to
    /// answer yes for one.
    private struct SynthesisedCodable: Codable {
        let selector: UInt8
    }

    /// What `Request` conforms to, asked of the type at run time rather than read off its source,
    /// and asked in `StandardLibraryQuery.swift`, which imports nothing. Asked in this file,
    /// which imports SMCCore, `any Decodable.Type` means whatever SMCCore declares `Decodable` to
    /// be.
    ///
    /// `Decodable` is the protocol here that synthesises an initialiser, so it has a check of its
    /// own: `Codable` is `Decodable & Encodable`, and a type that is only `Decodable` is not
    /// `Codable`. The `Encodable` and `Codable` checks are policy, not construction: `Encodable`
    /// builds nothing, and a request is bytes that `SMCConnectionRequest.swift` builds and
    /// `call(_:)` sends, which nothing has a reason to serialise.
    ///
    /// **Mutations:** in `SMCConnection.swift`, `extension SMCConnection { typealias Equatable =
    /// Swift.Equatable & Swift.Decodable }`, which leaves `Request`'s list reading `Sendable,
    /// Equatable` (#452's P2). Run: red here, at `Decodable`, and nowhere else. The same, with a
    /// top-level `typealias Decodable = Swift.Decodable & Swift.Hashable` beside it (P3), or with
    /// an internal `enum Swift { typealias Decodable = Hashable }` and P2 written without
    /// `Swift.` (P4). Run: red here, at `Decodable`, for each. Add `Decodable` to the list (R3).
    /// Run: red here, at `Decodable`, and at the conformance check above.
    @Test("Request is not Decodable, Encodable or Codable, whatever its list's names resolve to")
    func theRequestIsNotCodable() {
        let request = SMCConnection.Request.self
        #expect(
            !StandardLibraryQuery.isDecodable(request),
            "SMCConnection.Request is Decodable, so init(from:) builds one with any selector.")
        #expect(!StandardLibraryQuery.isEncodable(request), "SMCConnection.Request is Encodable.")
        #expect(!StandardLibraryQuery.isCodable(request), "SMCConnection.Request is Codable.")

        // The premise: each question answers yes for a type whose conformance is synthesised.
        #expect(StandardLibraryQuery.isDecodable(SynthesisedCodable.self))
        #expect(StandardLibraryQuery.isEncodable(SynthesisedCodable.self))
        #expect(StandardLibraryQuery.isCodable(SynthesisedCodable.self))
    }

    /// No key path into `Request` can be written through, by a dynamic cast or otherwise.
    ///
    /// A `private(set)` field's key path is a `KeyPath` to the compiler outside the file, and a
    /// `WritableKeyPath` to `as?` (SR-5218). With the fields `private(set) var`,
    /// `(\Request.selector as AnyKeyPath) as? WritableKeyPath<Request, UInt8>` in
    /// `SMCConnection.swift` wrote selector 6 into a request a factory built, with the whole suite
    /// green (#456's review, K1). `bytes` is here too: a stored `bytes` with a setter would be a
    /// way to send any 80 bytes.
    ///
    /// **Mutations:** the fields back to `private(set) var`, as at `d730054`. Run: red here, at
    /// each of the five fields, and at the member list. #456's K1 in `SMCConnection.swift`, with
    /// the fields as they are. Run: green, and K1's cast returns `nil`; with the fields
    /// `private(set) var`, the same K1 writes selector 6, data size 40 and a 32-byte payload.
    @Test("No key path into Request is writable, even by a dynamic cast")
    func noKeyPathIntoTheRequestIsWritable() {
        // Spelled in full: an alias of a seam type is refused outside SMCCore
        // (`WriteSeamSpellingTests`).
        #expect(!StandardLibraryQuery.isWritable(\SMCConnection.Request.key), "key")
        #expect(!StandardLibraryQuery.isWritable(\SMCConnection.Request.selector), "selector")
        #expect(!StandardLibraryQuery.isWritable(\SMCConnection.Request.data32), "data32")
        #expect(!StandardLibraryQuery.isWritable(\SMCConnection.Request.dataSize), "dataSize")
        #expect(!StandardLibraryQuery.isWritable(\SMCConnection.Request.payload), "payload")
        #expect(!StandardLibraryQuery.isWritable(\SMCConnection.Request.bytes), "bytes")

        // The premise: the query answers yes for a `private(set)` property declared in another
        // file, which is SR-5218's shape and #456's K1.
        #expect(StandardLibraryQuery.isWritable(\PrivateSetterTwin.selector))
    }

    static let queryFile = "StandardLibraryQuery.swift"

    /// `StandardLibraryQuery.swift` imports nothing, so no SMCCore name can stand in for the
    /// standard library's there.
    ///
    /// **Mutation:** `@testable import SMCCore` in that file, with P3. Run: red here, and at
    /// `theRequestIsNotCodable`'s premise, since `SynthesisedCodable` is not `Hashable`. The check
    /// on `Request` itself passes, because `Decodable` in that file now means SMCCore's.
    @Test("The file the run-time questions are asked in imports nothing")
    func theQueryFileImportsNothing() throws {
        let url = try #require(
            try SeamScanner.swiftFiles(underTests: "AeolusHelperTests").first {
                $0.lastPathComponent == Self.queryFile
            })
        let code = WriteSeamTestIsolationTests.strippingStringLiterals(
            SeamScanner.strippingAllComments(try String(contentsOf: url, encoding: .utf8)))
        let read = DeclarationCensus.tokens(in: code)
        #expect(read.unreadable.isEmpty, "\(read.unreadable)")
        #expect(!read.tokens.isEmpty, "the scan read nothing in \(Self.queryFile)")
        #expect(
            !read.tokens.contains(.word("import")),
            """
            \(Self.queryFile) imports something. A module it imports can declare Decodable, Swift \
            or WritableKeyPath, and the questions asked there would then be that module's.
            """)
    }

    /// `extension SMCConnection.Request`, spaced or prefixed with module and type names. A
    /// parenthesised name, `extension (SMCConnection.Request)`, is not matched, and neither is
    /// every other spelling a lexer would have to know. This scan claims only the plain spellings
    /// an extension is written with by accident. In another file the compiler refuses an
    /// initialiser that assigns an accessor or names a stored field, whatever the spelling, and in
    /// `SMCConnectionRequest.swift` the file's one-declaration pin above sees any extension.
    static let extendingRequest =
        #"(?<![A-Za-z0-9_])extension\s+(?:[A-Za-z_]\w*\s*\.\s*)*Request(?![A-Za-z0-9_])"#

    /// `typealias X = SMCConnection.Request`, which an extension of `X` would extend.
    static let aliasingRequest =
        #"(?<![A-Za-z0-9_])typealias\s+\w+\s*(?:<[^=]*>)?\s*=\s*(?:[A-Za-z_]\w*\s*\.\s*)*"#
        + #"Request(?![A-Za-z0-9_])"#

    /// `Request`'s members are pinned where it is declared, and an extension in another file adds
    /// members that pin cannot see. Such an extension's initialiser can neither assign a get-only
    /// accessor nor name a `private` stored field (#452), so the compiler, not this scan, is what
    /// keeps it from building a request no factory built. The scan stays as a cheap check on the
    /// plain spellings.
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
