import Foundation
import Testing

/// The access levels [#98](https://github.com/blamechris/Aeolus/issues/98) left behind,
/// asserted rather than described.
///
/// ## Why this suite exists
///
/// #98 split `HelperConnectionSession.swift` three ways at swiftlint's 400-line limit, and a
/// Swift `private` member is invisible to an extension in a sibling file — so the split had a
/// price to pay in access, exactly as `LeaseAuthorityAccessTests` records #128 paying it.
///
/// The price was paid on **references and refusals** and refused for **this connection's own
/// state**. `authority` and `log` are widened: one is where a message goes after both gates,
/// the other writes a log line. The four gate functions and the two refusal helpers are
/// widened because the messages call them, and every one of them can produce a refusal and
/// nothing else. `negotiated`, `deliveredMessages` and `hasInvalidated` are **not** widened,
/// because they are the gates' inputs: `hasInvalidated = false` written from anywhere in
/// `AeolusHelper` re-opens a closed teardown gate without touching a gate, and a second
/// `negotiated` does the same to the handshake.
///
/// That distinction is written down in `HelperConnectionSession.swift`, and #128's lesson is
/// that a paragraph is not enforcement — the next split has no way to notice it is widening
/// `hasInvalidated` rather than `log`.
///
/// ## Both directions, for the reason `WriteVerbAllowlistTests` gives
///
/// `theSessionStateStaysPrivate` fails when a listed member loses its `private`, **and** when
/// it is no longer declared as written. A guard naming a member that has been renamed away
/// asserts nothing while still reading like protection.
///
/// `onlyTheAcknowledgedPropertiesAreInternal` and `onlyTheAcknowledgedMethodsAreInternal` are
/// the halves that catch the widening nobody listed. They scan all three files the actor is
/// written in, so a member cannot be widened simply by being written in one of the new ones.
///
/// ## What this suite cannot see, stated rather than implied
///
/// It reads access levels, never call sites. The compiler is what actually stops a sibling
/// file assigning to `hasInvalidated` — `private` is file-scoped and there is no way around
/// it — and this suite's job is to notice the day somebody makes that assignment *possible*.
@Suite("The connection's own state stays private to HelperConnectionSession.swift")
struct HelperConnectionSessionAccessTests {

    /// The file that declares the storage, and so the only one that can write it.
    private static let declaringFile = "HelperConnectionSession.swift"

    /// All three files `HelperConnectionSession`'s members are written in.
    ///
    /// None of them declares a second type — `NegotiatedClient` was moved to
    /// `NegotiatedClient.swift` by #98 for exactly this reason — so everything at member
    /// indent in them is a member of the actor, which is the precondition
    /// `MemberAccessScan.members(in:keyword:)` states.
    private static let sessionFiles = [
        "HelperConnectionSession.swift",
        "HelperConnectionSessionGates.swift",
        "HelperConnectionSessionMessages.swift",
    ]

    /// This connection's state, spelled as declared, and where it has to stay.
    ///
    /// Not the handshake inputs — `helperRange`, `helperBuild` and `capabilities` are
    /// private too, and `onlyTheAcknowledgedPropertiesAreInternal` is what holds them there.
    /// These three are listed separately because widening one is not merely a wider seam: it
    /// is a gate whose answer can be changed from outside the gate.
    private static let mustStayPrivate = [
        "var negotiated: NegotiatedClient?",
        "var deliveredMessages = 0",
        "var hasInvalidated = false",
    ]

    /// Every property of `HelperConnectionSession` that is not `private`, and why.
    ///
    /// `id` pre-dates the split and is what every log line and every `FanAuthority` call
    /// names. `authority` and `log` are #98's two, widened so
    /// `HelperConnectionSessionMessages.swift` can dispatch and
    /// `HelperConnectionSessionGates.swift` can log a refusal; neither is state this actor
    /// owns, and reaching either from elsewhere in `AeolusHelper` reaches the same instances
    /// `HelperComposition` already holds.
    ///
    /// `handshakeState`, `messageCount` and `isInvalidated` are get-only computed views of
    /// the three private stored properties, and are the whole mechanism by which the gates
    /// read state they cannot write. `isInvalidated` is #98's; the other two pre-date it and
    /// are what the tests and the log read. A **stored** property appearing in this list is
    /// the failure to argue about, because that is the shape that hands a caller an
    /// assignment.
    private static let acknowledgedInternalProperties: Set<String> = [
        "id",
        "authority",
        "log",
        "handshakeState",
        "messageCount",
        "isInvalidated",
    ]

    /// Every method of `HelperConnectionSession` that is not `private`, and what each is.
    ///
    /// The eight messages and `invalidate()` are the boundary's own seam and pre-date the
    /// split — `HelperXPCService` calls them. The six that #98 widened are the four gates and
    /// the two refusal helpers, `internal` only because a Swift extension in a sibling file
    /// cannot see a `private` member; each of them returns a refusal or `nil` and can express
    /// nothing else.
    ///
    /// `countDeliveredMessage()` is the one widening that mutates, and it is here rather than
    /// as a widened `var` deliberately: it increments by one and does nothing else, where
    /// `var deliveredMessages` would have handed the same callers an assignment. A **second**
    /// mutating method appearing in this list is the thing to argue about.
    private static let acknowledgedInternalMethods: Set<String> = [
        "hello",
        "invalidate",
        "countDeliveredMessage",
        "snapshot",
        "acquireLease",
        "renewLease",
        "releaseLease",
        "apply",
        "restoreAllToAutomatic",
        "handshakeRefusal",
        "invalidationRefusal",
        "handshakeAcknowledgementRefusal",
        "invalidationAcknowledgementRefusal",
        "refuse",
        "acknowledgeRefusal",
    ]

    @Test("Every property a gate reads is private to the file that writes it")
    func theSessionStateStaysPrivate() throws {
        let code = try MemberAccessScan.strippedSource(of: Self.declaringFile)

        for member in Self.mustStayPrivate {
            let line =
                code
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first { $0.contains(member) }
            let declaration = try #require(
                line,
                """
                \(member) is no longer declared in \(Self.declaringFile). This guard names \
                the gates' inputs; one that has been renamed, moved to a sibling file or \
                respelled has to be re-stated here, or the entry is protecting nothing.
                """
            )
            #expect(
                declaration.trimmingCharacters(in: .whitespaces).hasPrefix("private "),
                """
                `\(declaration.trimmingCharacters(in: .whitespaces))` is no longer private. \
                A gate whose input is writable from every file in AeolusHelper is no longer \
                a gate — see HelperConnectionSession.swift for the widenings that were \
                taken on purpose and why this one is not among them.
                """
            )
        }
    }

    @Test("Only the acknowledged properties of the connection session are internal")
    func onlyTheAcknowledgedPropertiesAreInternal() throws {
        let internalProperties = Set(
            try MemberAccessScan.members(in: Self.sessionFiles, keyword: .property)
                .filter { !$0.isPrivate }
                .map(\.name))

        #expect(
            internalProperties == Self.acknowledgedInternalProperties,
            """
            the internal properties of HelperConnectionSession changed: found \
            \(internalProperties.sorted()), acknowledged \
            \(Self.acknowledgedInternalProperties.sorted()). Widening one is a decision \
            about what the rest of AeolusHelper may read — or, if it is stored, write — on \
            the privilege boundary's per-connection state. Say why here, in the suite that \
            records why the acknowledged ones were acceptable.
            """
        )
    }

    @Test("Only the acknowledged methods of the connection session are internal")
    func onlyTheAcknowledgedMethodsAreInternal() throws {
        let internalMethods = Set(
            try MemberAccessScan.members(in: Self.sessionFiles, keyword: .method)
                .filter { !$0.isPrivate }
                .map(\.name))

        #expect(
            internalMethods == Self.acknowledgedInternalMethods,
            """
            the internal methods of HelperConnectionSession changed: found \
            \(internalMethods.sorted()), acknowledged \
            \(Self.acknowledgedInternalMethods.sorted()). A method of this actor that is \
            not private is callable from every file in AeolusHelper, and inside it \
            `negotiated`, `deliveredMessages` and `hasInvalidated` are all in scope — say \
            why here.
            """
        )
    }
}
