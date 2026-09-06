import Foundation
import Testing

/// The parser behind `XPCDeclarationFingerprintTests`, held against fixtures.
///
/// The pin itself is asserted against the real `AeolusXPCProtocol.swift`, which exercises
/// exactly one shape: seven required instance methods, no attributes, no comments inside
/// the body, no string literals. Everything the normaliser claims *beyond* that shape —
/// comment stripping, nested block comments, string literals, attributes, a stray
/// declaration, an anchored protocol name — has nothing in the real file to kill it, so it
/// is driven from fixtures here instead. Each fixture below exists because a specific
/// branch of the normaliser survived its own mutation without one.
@Suite("XPC declaration normaliser")
struct XPCDeclarationNormaliserTests {

    private static let twoMethods: Set<String> = [
        "func apply(settings: Data, id: String, reply: @escaping @Sendable (Error?) -> Void)",
        "func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)",
    ]

    private static func fingerprint(ofFixture source: String) -> Set<String> {
        guard let body = XPCDeclarationNormaliser.protocolBody(named: "Fixture", in: source)
        else { return [] }
        return Set(XPCDeclarationNormaliser.normalisedDeclarations(inProtocolBody: body))
    }

    /// The property that makes the pin usable: reformatting is not a contract change.
    ///
    /// Held against fixtures rather than against the real file, so it keeps holding once
    /// `AeolusXPCProtocol.swift` is formatted the one way `swift format` writes it. The
    /// second fixture differs from the first by every formatting move available — a wrapped
    /// parameter list, a different indent, a blank line, a doc comment, a trailing comment,
    /// a block comment, and a trailing comma — and must fingerprint identically.
    ///
    /// The block comment sits *between* the two requirements, not above the first, because
    /// above the first it is discarded by the declaration split before the stripper's block
    /// branch matters and that branch then survives being deleted outright. It is hostile on
    /// purpose: a nested `/* … */` kills the "first `*/` wins" simplification, `func
    /// writeKey(` becomes an eighth declaration if the comment survives, and the `}` closes
    /// the protocol body early — which is the case `closingBrace` depends on the stripper for.
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

                func apply(
                    settings: Data,
                    id: String,

                    reply: @escaping @Sendable (Error?) -> Void,
                )

                /* a block comment /* nested */ mentioning func writeKey( and a } brace */
                func snapshot(  // trailing comment
                    reply: @escaping @Sendable (Data?, Error?) -> Void)
            }
            """

        #expect(Self.fingerprint(ofFixture: compact) == Self.twoMethods)
        #expect(Self.fingerprint(ofFixture: reformatted) == Self.twoMethods)
    }

    /// A `/*` inside a string literal opens nothing.
    ///
    /// The real protocol carries no string literal inside anything the scan reaches, so the
    /// literal branch has nothing to kill it there. Here it does: without the branch the
    /// unterminated `/*` in the marker opens a block comment that swallows the protocol, the
    /// body extraction returns nil, and the fingerprint is empty.
    @Test("A comment token inside a string literal opens no comment")
    func stringLiteralsAreNotCommentOpeners() {
        let source = """
            enum FixtureNames {
                static let marker = "/* and // are text here, not comment openers"
            }
            @objc public protocol Fixture {
                func apply(settings: Data, id: String, reply: @escaping @Sendable (Error?) -> Void)
                func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)
            }
            """

        #expect(Self.fingerprint(ofFixture: source) == Self.twoMethods)
    }

    /// An attribute on the declaration's own line is part of the declaration.
    ///
    /// `@objc optional` on the *first* requirement was invisible to the fingerprint while
    /// declarations were sliced from one `func` keyword to the next: everything before the
    /// first keyword was in no slice at all. On a privilege boundary an optional message
    /// means a client cannot know whether the helper implements it, so the fingerprint
    /// carrying it is not a nicety.
    @Test("An attribute on the first declaration's line is inside the fingerprint")
    func attributesOnTheDeclarationLineAreFingerprinted() {
        let plain = """
            @objc public protocol Fixture {
                func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)
            }
            """
        let optional = """
            @objc public protocol Fixture {
                @objc optional func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)
            }
            """

        #expect(
            Self.fingerprint(ofFixture: plain) == [
                "func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)"
            ])
        #expect(
            Self.fingerprint(ofFixture: optional) == [
                "@objc optional func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)"
            ])
    }

    /// A requirement that is not a method is surfaced, not dropped.
    ///
    /// A property requirement declared above the first `func` used to vanish from the
    /// fingerprint entirely. It is emitted as its own entry now, so it fails the pin on its
    /// own text rather than being caught only by the runtime guard's getter/setter
    /// enumeration downstream.
    @Test("A declaration before the first method is fingerprinted, not discarded")
    func declarationsBeforeTheFirstMethodAreNotDropped() {
        let source = """
            @objc public protocol Fixture {
                var forceOverride: Bool { get set }
                func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)
            }
            """

        #expect(
            Self.fingerprint(ofFixture: source) == [
                "var forceOverride: Bool { get set }",
                "func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)",
            ])
    }

    /// The protocol name must end where the search says it does.
    ///
    /// An unanchored prefix match takes the first occurrence, so a longer name declared
    /// above the real one is fingerprinted in its place — a loud failure, but one that lists
    /// the wrong protocol's methods and sends the reader after a change that did not happen.
    @Test("A longer protocol name sharing the prefix is not matched")
    func aLongerProtocolNameSharingThePrefixIsNotMatched() {
        let source = """
            @objc public protocol FixturePrivileged {
                func writeKey(name: String, reply: @escaping @Sendable (Error?) -> Void)
            }
            @objc public protocol Fixture {
                func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)
            }
            """

        #expect(
            Self.fingerprint(ofFixture: source) == [
                "func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void)"
            ])
    }

    /// The `>` of a return arrow closes nothing.
    ///
    /// `topLevelComponents` guards its `>` case with `previous != "-"`, and every signature
    /// the boundary declares agrees with the unguarded form — the arrow's `>` there always
    /// arrives at depth zero, where the `max(0, …)` floor absorbs it. This is the shape that
    /// tells them apart: a function type inside a generic, with a comma after the arrow that
    /// is still inside the bracket. Without the guard the parameter list splits at that
    /// comma and the derived selector grows a `Data>:` argument.
    @Test("A function type inside a generic does not split the parameter list")
    func selectorSurvivesAFunctionTypeInsideAGeneric() {
        let signature =
            "func apply(pair: Pair<() -> Void, Data>, reply: @escaping @Sendable (Error?) -> Void)"

        #expect(
            XPCDeclarationNormaliser.selector(forNormalisedSignature: signature)
                == "applyWithPair:reply:"
        )
    }
}
