import Foundation
import Testing

@testable import AeolusXPC

/// A source-level fingerprint of the privilege boundary's declaration.
///
/// `XPCContractTests` pins the boundary's message set as the Objective-C runtime sees it,
/// which is the right axis for a message added, removed, renamed, re-parameterised, made
/// optional, or moved to a class method. Two of its tests split that work and neither
/// covers the other's half: `protocolDeclaresExactlyTheAllowedMessages` holds the message
/// *set*, and `protocolUsesOnlyTheRequiredInstanceQuadrant` is the only thing that sees the
/// optional/class-method axis — the exact-set test unions all four quadrants, so a message
/// moved between them leaves its set byte-identical.
///
/// Both are blind to two changes that alter what the boundary *carries* without altering
/// what it is *called* ([#88](https://github.com/blamechris/Aeolus/issues/88)):
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
/// pinned set. The normalisation is whitespace-and-punctuation only; that it survives a
/// reformat is held by `XPCDeclarationNormaliserTests` against fixtures rather than left to
/// a reviewer's memory.
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
/// - **Which declaration a stray modifier belongs to.** A modifier or attribute on the line
///   *above* a `func` is fingerprinted with the declaration above it, so the change goes red
///   but the failure message names the wrong method. Anything above the *first* declaration
///   — including a property requirement — is emitted as its own entry and fails the pin on
///   its own text.
/// - **Semantics.** A parameter that keeps its name and type while meaning something else is
///   a review problem, not a text one.
@Suite("XPC declaration fingerprint")
struct XPCDeclarationFingerprintTests {

    /// The boundary's shape at every contract version.
    ///
    /// An entry records what one version of the contract declares: labels, parameter types,
    /// and the whole reply block — `@escaping`, `@Sendable`, and the optionality of every
    /// reply argument — because each of them is part of what a client must know to talk to
    /// the helper and none of them is legible to a selector.
    ///
    /// **A boundary change adds an entry; it does not edit one.** That is the forcing
    /// function #88 records as missing, and it is mechanical rather than advisory: a shape
    /// change with no new entry fails `declarationFingerprintMatchesThePin` (the current
    /// version's record no longer describes the source), and a new entry with
    /// `AeolusXPCVersion.current` left behind fails `pinnedVersionIsTheNewestEntry`. The
    /// only green way through a shape change is a new `(version, signatures)` pair *and* a
    /// bump — and say so in the pull request body.
    ///
    /// The residual, stated because a guard trusted past its reach is worse than none: an
    /// author can still rewrite the newest entry in place and leave the version alone. That
    /// is a version's shipped record being edited after the fact — a deliberate, legible act
    /// in the diff — rather than the silent omission this table closes, and it stays a
    /// review obligation.
    static let pinHistory: [Int: Set<String>] = [
        1: v1Signatures
    ]

    /// The shape v1 declares. A version's entry is a `let` of its own so that adding the
    /// next one is an addition rather than a re-indent of the whole table.
    private static let v1Signatures: Set<String> = [
        "func hello(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void)",
        "func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)",
        "func acquireLease(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void)",
        "func renewLease(id: String, reply: @escaping @Sendable (Data?, Error?) -> Void)",
        "func releaseLease(id: String, reply: @escaping @Sendable (Error?) -> Void)",
        "func apply(settings: Data, leaseID: String, reply: @escaping @Sendable (Error?) -> Void)",
        "func restoreAllToAutomatic(reply: @escaping @Sendable (Error?) -> Void)",
    ]

    /// The record for the version the contract currently advertises.
    static func pinnedSignatures() throws -> Set<String> {
        try #require(
            pinHistory[AeolusXPCVersion.current],
            """
            AeolusXPCVersion.current is \(AeolusXPCVersion.current) and `pinHistory` has no \
            entry for it: add `\(AeolusXPCVersion.current): [ … ]` recording the shape this \
            version declares
            """
        )
    }

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
    @Test("The boundary's declared signatures are exactly the current version's pin")
    func declarationFingerprintMatchesThePin() throws {
        let found = try Self.fingerprintOfSource()
        let pinned = try Self.pinnedSignatures()
        #expect(
            found == pinned,
            """
            the boundary's shape changed — a parameter type, a reply block, or a label is \
            not what it was, and no selector-based guard can see that. \
            Added \(found.subtracting(pinned).sorted()); \
            removed \(pinned.subtracting(found).sorted()). \
            If the change is intended it is a new contract version: add a \
            `\(AeolusXPCVersion.current + 1): [ … ]` entry to `pinHistory` carrying the \
            declarations above, bump AeolusXPCVersion.current to match, and say so in the \
            pull request body. Editing the v\(AeolusXPCVersion.current) entry instead \
            rewrites a shipped version's record.
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
        for signature in try Self.pinnedSignatures() {
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

    /// The other half of the forcing function: an entry added without the bump that makes
    /// it the contract.
    @Test("The advertised version is the newest entry in the pin history")
    func pinnedVersionIsTheNewestEntry() throws {
        let newest = try #require(Self.pinHistory.keys.max(), "`pinHistory` is empty")
        #expect(
            AeolusXPCVersion.current == newest,
            """
            `pinHistory` records v\(newest) as the boundary's newest shape while \
            AeolusXPCVersion.current still advertises \(AeolusXPCVersion.current): bump \
            `current` to \(newest), or drop the entry if the shape change was not intended
            """
        )
    }
}
