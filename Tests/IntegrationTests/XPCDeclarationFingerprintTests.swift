import Foundation
import Testing

@testable import AeolusXPC

/// A source-level fingerprint of the privilege boundary's declaration.
///
/// `XPCContractTests.protocolDeclaresExactlyTheAllowedMessages` pins the boundary's message
/// set as the Objective-C runtime sees it, which is the right axis for a message added,
/// removed, renamed, re-parameterised, made optional, or moved to a class method. It is
/// blind to two changes that alter what the boundary *carries* without altering what it is
/// *called* ([#88](https://github.com/blamechris/Aeolus/issues/88)):
///
/// - **A parameter's type.** `applyWithSettings:leaseID:reply:` is byte-identical whether
///   `settings` is `Data` or `[String: String]`, and so is its type encoding — every object
///   type encodes as `@`.
/// - **A reply block's shape.** Widening `apply`'s reply from `(Error?) -> Void` to
///   `(Data?, Error?) -> Void` leaves the selector alone and every runtime assertion green,
///   while silently changing the reply contract.
///
/// Neither is visible at the runtime level at all, so this guard reads the declaration in
/// `Sources/AeolusXPC/AeolusXPCProtocol.swift` and compares a normalised form of it to a
/// pinned set. The normalisation is whitespace-and-punctuation only: a reformat — wrapping a
/// parameter list, re-indenting, adding a doc comment or a blank line — must leave the
/// fingerprint identical, and `formattingDoesNotChangeTheFingerprint` holds that property
/// against fixtures rather than leaving it to a reviewer's memory.
///
/// ## What this cannot see
///
/// Stated rather than discovered later, because a guard trusted past its reach is worse
/// than none:
///
/// - **A typealias.** `settings: Data` where `Data` has been re-aliased elsewhere reads as
///   unchanged text. The fingerprint compares spelling, not resolved types.
/// - **A DTO's `Codable` shape.** Every structured payload crosses as JSON-encoded `Data`,
///   so renaming a field of `HelloReply` or `SystemSnapshot` changes the wire without
///   touching one character of this protocol. That axis belongs to the round-trip tests at
///   the top of `XPCContractTests`, and to `AeolusXPCVersion`'s bump policy.
/// - **A change to the file this points at.** Splitting `AeolusXPCProtocol` into a second
///   file would leave nothing to scan; the extraction fails loudly rather than passing
///   vacuously, which is the behaviour `#require` gives here.
/// - **Semantics.** A parameter that keeps its name and type while meaning something else is
///   a review problem, not a text one.
@Suite("XPC declaration fingerprint")
struct XPCDeclarationFingerprintTests {

    /// The boundary's seven declarations, normalised.
    ///
    /// Labels, parameter types, and the whole reply block — `@escaping`, `@Sendable`, and
    /// the optionality of every reply argument — are all inside the pin, because each of
    /// them is part of what a client must know to talk to the helper and none of them is
    /// legible to a selector.
    ///
    /// **Changing this set means the boundary's shape changed.** Bump `AeolusXPCVersion`,
    /// update this pin and `pinnedProtocolVersion` below in the same pull request, and say
    /// so in the pull request body.
    static let pinnedSignatures: Set<String> = [
        "func hello(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void)",
        "func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)",
        "func acquireLease(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void)",
        "func renewLease(id: String, reply: @escaping @Sendable (Data?, Error?) -> Void)",
        "func releaseLease(id: String, reply: @escaping @Sendable (Error?) -> Void)",
        "func apply(settings: Data, leaseID: String, reply: @escaping @Sendable (Error?) -> Void)",
        "func restoreAllToAutomatic(reply: @escaping @Sendable (Error?) -> Void)",
    ]

    /// The contract version the signatures above describe.
    ///
    /// It sits here, next to them, so the two move together: a pull request that edits
    /// `pinnedSignatures` and leaves this number alone has changed the boundary's shape
    /// without versioning it, which is precisely the missing forcing function #88 records.
    static let pinnedProtocolVersion = 1

    /// The declaration source, located from this file rather than from the working
    /// directory — `swift test` and Xcode disagree about the latter.
    ///
    /// `SeamScanner.sourcesRoot` walks up from `#filePath` the same way; this target cannot
    /// import it (it lives in `AeolusHelperTests`), so the walk is repeated rather than
    /// shared.
    static var protocolSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/IntegrationTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources/AeolusXPC/AeolusXPCProtocol.swift")
    }

    static func fingerprintOfSource() throws -> Set<String> {
        let source = try String(contentsOf: protocolSourceURL, encoding: .utf8)
        let body = try #require(
            XPCDeclarationNormaliser.protocolBody(named: "AeolusXPCProtocol", in: source),
            "`protocol AeolusXPCProtocol { … }` was not found in \(protocolSourceURL.path)"
        )
        return Set(XPCDeclarationNormaliser.normalisedDeclarations(inProtocolBody: body))
    }

    /// **This is the guard.** Set equality against the declaration as written.
    @Test("The boundary's declared signatures are exactly the pinned ones")
    func declarationFingerprintMatchesThePin() throws {
        let found = try Self.fingerprintOfSource()
        #expect(
            found == Self.pinnedSignatures,
            """
            the boundary's shape changed — a parameter type, a reply block, or a label is \
            not what it was, and no selector-based guard can see that. \
            Added \(found.subtracting(Self.pinnedSignatures).sorted()); \
            removed \(Self.pinnedSignatures.subtracting(found).sorted()). \
            If the change is intended: bump AeolusXPCVersion, update `pinnedSignatures` and \
            `pinnedProtocolVersion` in this file in the same pull request, and say so in the \
            pull request body.
            """
        )
    }

    /// The two guards must describe the same boundary, or one of them is lying about the
    /// other.
    ///
    /// The selectors are *derived* from the pinned signatures and compared to the set
    /// `XPCContractTests` pins independently, so neither pin can be edited alone: a
    /// signature added here without its selector there fails, and so does the reverse.
    ///
    /// The derivation is Swift's `@objc` inference in its plain form — base name, `With`,
    /// the first label capitalised, then every remaining label — which is exactly what this
    /// protocol's seven methods use. A method whose inferred selector differs (a base name
    /// Swift splits differently, or an explicit `@objc(custom:)` rename) would fail here
    /// rather than pass, and the deriver is what gets fixed.
    @Test("The selectors derived from the pinned signatures are the pinned selectors")
    func derivedSelectorsMatchTheRuntimeGuard() throws {
        var derived: Set<String> = []
        for signature in Self.pinnedSignatures {
            derived.insert(
                try #require(
                    XPCDeclarationNormaliser.selector(forNormalisedSignature: signature),
                    "`\(signature)` could not be read as a method declaration"
                )
            )
        }
        #expect(
            derived == XPCContractTests.allowedSelectors,
            """
            the source fingerprint and the runtime selector guard disagree about the \
            boundary: only in the fingerprint \
            \(derived.subtracting(XPCContractTests.allowedSelectors).sorted()), only in the \
            selector pin \(XPCContractTests.allowedSelectors.subtracting(derived).sorted())
            """
        )
    }

    @Test("The pinned version is the version the contract advertises")
    func pinnedVersionMatchesTheContract() {
        #expect(
            AeolusXPCVersion.current == Self.pinnedProtocolVersion,
            """
            AeolusXPCVersion.current moved to \(AeolusXPCVersion.current) while the pinned \
            signatures above still describe v\(Self.pinnedProtocolVersion): update both \
            together or the fingerprint documents a contract nobody is speaking
            """
        )
    }

    /// The property that makes the pin usable: reformatting is not a contract change.
    ///
    /// Held against fixtures rather than against the real file, so it keeps holding once
    /// `AeolusXPCProtocol.swift` is formatted the one way `swift format` writes it. The
    /// second fixture differs from the first by every formatting move available — a wrapped
    /// parameter list, a different indent, a blank line, a doc comment, a trailing comment,
    /// a block comment, and a trailing comma — and must fingerprint identically.
    @Test("Reformatting the declaration does not change the fingerprint")
    func formattingDoesNotChangeTheFingerprint() {
        let compact = """
            @objc public protocol Fixture {
                func apply(settings: Data, id: String, reply: @escaping @Sendable (Error?) -> Void)
                func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)
            }
            """
        let reformatted = """
            /// A doc comment that was not here before, mentioning func snapshotWithReply:.
            @objc public protocol Fixture {

                /* a block comment, and a stray ) brace to be dropped with it */
                func apply(
                    settings: Data,
                    id: String,

                    reply: @escaping @Sendable (Error?) -> Void,
                )

                func snapshot(  // trailing comment
                    reply: @escaping @Sendable (Data?, Error?) -> Void)
            }
            """
        let expected: Set<String> = [
            "func apply(settings: Data, id: String, reply: @escaping @Sendable (Error?) -> Void)",
            "func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)",
        ]

        #expect(Self.fingerprint(ofFixture: compact) == expected)
        #expect(Self.fingerprint(ofFixture: reformatted) == expected)
    }

    private static func fingerprint(ofFixture source: String) -> Set<String> {
        guard let body = XPCDeclarationNormaliser.protocolBody(named: "Fixture", in: source)
        else { return [] }
        return Set(XPCDeclarationNormaliser.normalisedDeclarations(inProtocolBody: body))
    }
}
