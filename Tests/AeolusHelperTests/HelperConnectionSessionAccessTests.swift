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
/// `theSessionStateStaysPrivate` fails when a listed member loses its `private`, when it is no
/// longer declared as written, **and** when a second line of the file matches the same
/// spelling. A guard naming a member that has been renamed away asserts nothing while still
/// reading like protection — and one that had two lines to choose from was judging whichever
/// came first, which #236 turned into a green suite over an internal `hasInvalidated`.
///
/// `onlyTheAcknowledgedPropertiesAreInternal` and `onlyTheAcknowledgedMethodsAreInternal` are
/// the halves that catch the widening nobody listed. They scan every file the actor is written
/// in, so a member cannot be widened simply by being written in one of the new ones — and
/// `sessionFiles` is checked against the tree by `theScannedFilesAreEveryFileTheActorIsIn`,
/// because until [#236](https://github.com/blamechris/Aeolus/issues/236) that list was
/// hand-written and a *fourth* file was scanned by nothing.
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

    /// The type whose members these guards are about, and the target it is written in.
    private static let sessionType = "HelperConnectionSession"
    private static let helperTarget = "AeolusHelper"

    /// All three files `HelperConnectionSession`'s members are written in, **sorted**, and
    /// checked against the tree rather than trusted.
    ///
    /// None of them declares a second type — `NegotiatedClient` was moved to
    /// `NegotiatedClient.swift` by #98 for exactly this reason — so everything at member
    /// indent in them is a member of the actor, which is the precondition
    /// `MemberAccessScan.members(in:keyword:)` states.
    ///
    /// It stays written out rather than being derived at the point of use, because a list this
    /// suite compares against the tree is a *decision* a maintainer makes once: adding a
    /// fourth file to the actor means saying so here, in the file that records what each of
    /// them is allowed to widen. Deriving it silently would make the scan follow the split
    /// instead of reporting it.
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
    ///
    /// **Spelled as signatures, not names**, since #236: `invalidate()` is acknowledged and
    /// `invalidate(reopening: Bool)` — which sets `hasInvalidated = false` and clears
    /// `negotiated`, reopening both gates — collapsed onto it under a bare-name key and left
    /// 38 tests in 4 suites green. A parameter's *type* is in the key for the reason
    /// `SeamScanner.Function.key` records: labels alone cannot see an overload.
    private static let acknowledgedInternalMethods: Set<String> = [
        "hello(payload: Data)",
        "invalidate()",
        "countDeliveredMessage()",
        "snapshot()",
        "acquireLease(payload: Data)",
        "renewLease(id: String)",
        "releaseLease(id: String)",
        "apply(settings: Data, leaseID: String)",
        "restoreAllToAutomatic()",
        "handshakeRefusal(message: String)",
        "invalidationRefusal(message: String)",
        "handshakeAcknowledgementRefusal(message: String)",
        "invalidationAcknowledgementRefusal(message: String)",
        "refuse(_: AeolusXPCFault, message: String)",
        "acknowledgeRefusal(_: AeolusXPCFault, message: String)",
    ]

    /// The file set is a claim about the tree, so it is read off the tree.
    ///
    /// #236's first mutation: `Sources/AeolusHelper/HelperConnectionSessionExtra.swift`
    /// declaring `extension HelperConnectionSession { func reopenTheGateSideways(…) }` — a
    /// fourth file, listed nowhere, scanned by nothing, and green across 8 tests in 2 suites.
    /// `private` keeps the *storage* out of its reach and `WriteVerbAllowlistTests` catches an
    /// `async` member dispatching onto the authority, so what survived was precisely a
    /// synchronous internal member; this is what fails when the next one arrives.
    ///
    /// The declaring file is checked the same way, because `theSessionStateStaysPrivate` reads
    /// that one file and nothing else: if the `actor` declaration moved and `declaringFile`
    /// did not, that test would assert the state of a file the storage had left.
    @Test("Every file the connection session is written in is one this suite scans")
    func theScannedFilesAreEveryFileTheActorIsIn() throws {
        let sites = try MemberAccessScan.filesDeclaring(
            Self.sessionType, inTarget: Self.helperTarget)

        #expect(
            sites.members == Self.sessionFiles.sorted(),
            """
            the files \(Self.sessionType) is written in changed: the tree declares it in \
            \(sites.members), this suite scans \(Self.sessionFiles.sorted()). A file this \
            suite does not scan can widen any member of the actor — including a synchronous \
            internal method with `negotiated` and `hasInvalidated` in scope — and every \
            assertion here stays green. Add it to `sessionFiles` and say what it is allowed \
            to widen.
            """
        )
        #expect(
            sites.declarations == [Self.declaringFile],
            """
            \(Self.sessionType)'s own declaration is in \(sites.declarations), and \
            `declaringFile` names \(Self.declaringFile). That name is what \
            `theSessionStateStaysPrivate` opens, so a declaration that has moved leaves it \
            asserting about a file the stored state no longer lives in.
            """
        )
    }

    @Test("Every property a gate reads is private to the file that writes it")
    func theSessionStateStaysPrivate() throws {
        let code = try MemberAccessScan.strippedSource(of: Self.declaringFile)

        for member in Self.mustStayPrivate {
            let declaration = try MemberAccessScan.declaration(
                of: member, in: code, from: Self.declaringFile)
            #expect(
                declaration.hasPrefix("private "),
                """
                `\(declaration)` is no longer private. A gate whose input is writable from \
                every file in AeolusHelper is no longer a gate — see \
                HelperConnectionSession.swift for the widenings that were taken on purpose \
                and why this one is not among them.
                """
            )
        }
    }

    @Test("Only the acknowledged properties of the connection session are internal")
    func onlyTheAcknowledgedPropertiesAreInternal() throws {
        let internalProperties = Set(
            try MemberAccessScan.members(in: Self.sessionFiles, keyword: .property)
                .filter { !$0.isPrivate }
                .map(\.key))

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
                .map(\.key))

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
