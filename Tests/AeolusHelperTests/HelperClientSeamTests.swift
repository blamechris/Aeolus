import Foundation
import Testing

/// The client's structural claims — the ones with nothing to observe at runtime, asserted
/// against the source tree instead.
///
/// A source tripwire is this repository's last resort, and each one below says why the
/// behavioural test it would rather be does not exist. Every one of them is about
/// **absence** — a second caller, a second conformer, a second way of taking the proxy, a
/// stored snapshot, a stored lease, a retry, a connection built elsewhere. Absence is what
/// no green run can demonstrate, because the thing that would fail is the thing nobody wrote
/// yet.
///
/// The three added for #238 are the row `CLAUDE.md` gives this target, which #237's body
/// called structural and which was not: "the only `NSXPCConnection` outside the helper",
/// "never runs as root", "holds no fan state … never re-acquires a lease". The pinning half
/// of that row had a tripwire from the start; the rest was the current absence of a stored
/// property, and a fifth one compiles beside the four that are there.
@Suite("What the XPC client's sources must and must not contain")
struct HelperClientSeamTests {

    private static let target = "AeolusXPCClient"

    private static func sources() throws -> [(file: String, code: String)] {
        try SeamScanner.swiftFiles(under: target).map {
            (
                file: $0.lastPathComponent,
                code: SeamScanner.strippingComments(try String(contentsOf: $0, encoding: .utf8))
            )
        }
    }

    /// `restoreAllToAutomatic` is the only verb that reaches a proxy without a handshake,
    /// and the count is what keeps it so.
    ///
    /// Two occurrences of the name: the declaration, and the one call. A behavioural test
    /// can show that *today's* verbs handshake — `helloRunsOncePerConnection` and
    /// `thePanicPathNeedsNoHandshake` between them do — but it cannot fail for a verb added
    /// next year, and the whole point of the gate is that exempting yourself from it is not
    /// a decision an author gets to take quietly.
    ///
    /// The bare name rather than the name with its opening parenthesis, because the one
    /// call site passes a trailing closure and so is not followed by one at all — a detail
    /// that made the first version of this tripwire fire on a correct tree.
    /// `withHandshakenProxy` does not contain this name, so the two gates cannot be
    /// confused for one another.
    ///
    /// **Mutations, one per direction.** Route `restoreAllToAutomatic` through
    /// `withHandshakenProxy` instead: red at one. Route `releaseLease` — a gated verb —
    /// through the unhandshaken gate: red at three. The second is the one no behavioural
    /// test in this suite catches, because every test that calls `releaseLease` has already
    /// handshaken on that connection for an earlier verb; a verb added next year that is
    /// *only* ever called first would not even have that.
    @Test("The unhandshaken proxy has exactly one caller")
    func theUnhandshakenProxyHasExactlyOneCaller() throws {
        var found: [String] = []
        for source in try Self.sources() {
            let occurrences = source.code.components(separatedBy: "withProxy").count - 1
            found.append(contentsOf: Array(repeating: source.file, count: occurrences))
        }

        #expect(
            found.count == 2,
            """
            the unhandshaken gate is named \(found.count) times in Sources/\(Self.target) \
            (\(found.sorted())). Exactly two are correct: the declaration, and \
            `restoreAllToAutomatic`'s single call. Anything else is a verb exempting itself \
            from the handshake gate on the client's side of a boundary whose design is that \
            gates are not optional.
            """)
    }

    /// Exactly one thing in `Sources` can acquire a connection's code-signing requirement,
    /// and it is the one that pins the helper.
    ///
    /// The suite drives the client through a policy that applies no requirement at all,
    /// declared in the test target where production code cannot name it. That arrangement is
    /// only worth anything while `Sources` has no equivalent: a "no requirement" conformer
    /// living beside the real one would be one mis-wired initialiser away from a client that
    /// talks to whoever answered, and every test here would stay green.
    ///
    /// This is the client-side mirror of `ConnectionAdmission`'s own rule, and it is checked
    /// rather than documented because #72's review found the documented version of the same
    /// claim in three files while the diff did not stand behind it.
    ///
    /// **Mutation:** add `struct UnpinnedConnection: HelperConnectionPinning { … }` anywhere
    /// under `Sources`. Run: red.
    @Test("Exactly one connection-pinning policy ships in Sources")
    func exactlyOnePinningPolicyShipsInSources() throws {
        let conformers = try SeamScanner.declarations(
            matching: #"(?:struct|final class|class|actor|enum|extension)\s+\w+\s*:"#
                + #"[^{\n]*\bHelperConnectionPinning\b"#)

        #expect(
            conformers.map(\.text) == ["struct SignedHelperPinning: HelperConnectionPinning"],
            """
            Sources declares \(conformers.map(\.text)). Exactly one conformer may ship, and \
            it is the one that derives, compiles and applies the requirement. A conformer \
            that skipped it would leave every test in this target green while the client \
            trusted whoever answered the mach name.
            """)
    }

    /// The proxy is never taken without an error handler.
    ///
    /// `AeolusXPCProtocol` is explicit that a dropped reply block is the failure case that
    /// matters most: when the connection fails, the block passed with the message is simply
    /// dropped and only the error handler runs. A client that took a bare
    /// `remoteObjectProxy` would have no failure path for exactly that case, and its symptom
    /// is a caller that waits rather than a caller that is told.
    ///
    /// Counted rather than pattern-matched for absence, because
    /// `remoteObjectProxyWithErrorHandler` *contains* the forbidden spelling: the assertion
    /// is that the two counts are equal, so every occurrence of the shorter name is part of
    /// a longer one.
    ///
    /// **Mutation:** change one `remoteObjectProxyWithErrorHandler` to `remoteObjectProxy`.
    /// Run: red — and `aMessageInFlightWhenTheHelperDiesIsARestart` goes red with it, which
    /// is the behavioural half.
    @Test("Every proxy in the client carries an error handler")
    func everyProxyCarriesAnErrorHandler() throws {
        var bare = 0
        var handled = 0
        for source in try Self.sources() {
            bare += source.code.components(separatedBy: "remoteObjectProxy").count - 1
            handled +=
                source.code.components(separatedBy: "remoteObjectProxyWithErrorHandler").count - 1
        }

        #expect(handled > 0, "the client takes no proxy at all")
        #expect(
            bare == handled,
            """
            \(bare - handled) bare `remoteObjectProxy` use(s) in Sources/\(Self.target). When \
            the connection fails, the reply block is dropped and only the error handler runs \
            — a client without one has no failure path for the case that matters most.
            """)
    }

    // MARK: - What the client may not keep

    /// The file whose `public struct`s are the DTOs a helper's answer about the machine
    /// arrives in. The seam: this file is fan state, the handshake file beside it is not.
    private static let payloadFile = "AeolusXPCPayload.swift"

    /// The types a helper's answer **about the fans** arrives in.
    ///
    /// The first two are every `public struct` in `AeolusXPC/AeolusXPCPayload.swift` bar the
    /// lease pair below, and `everyPayloadDTOIsOnAForbiddenList` is what keeps that claim from
    /// being prose: it enumerates that file's top-level public structs and fails if one is on
    /// neither list. The distinction between the two files is load-bearing rather than tidy —
    /// `negotiatedReply: HelloReply?` is a stored DTO this client is *supposed* to hold, so a
    /// list that forbade "every DTO" would need an exemption by name, and an exemption list is
    /// where the next stored snapshot would have been written.
    ///
    /// The rest are the types those DTOs embed, **at every depth**, and they are on this list
    /// because `theFanStateListNamesEveryTypeTheseDTOsCarry` put them there rather than because
    /// anyone judged them worth naming. The first version of that check read `SystemSnapshot`'s
    /// own stored properties only, so it validated three of six entries and descended into
    /// none: `FanState.mode: FanControlMode` and `FanState.manualControlAvailability` were on
    /// no list, and `private var lastMode: FanControlMode?` — a remembered per-fan control mode,
    /// which a UI renders as "manual" after the helper has stopped answering, rule 6 in its
    /// purest form — was green. `Fan`, `FanReading` and `FanSetting` were checked by nothing at
    /// all.
    ///
    /// `Data` is here rather than on `scalars`, and it is the one entry that is not a type of
    /// the helper's own. It is the **wire form** of every one of them: each verb in
    /// `HelperClientVerbs.swift` is `let data: Data = try await withHandshakenProxy { … }`
    /// followed by a decode, so `private var lastSnapshotPayload: Data?` plus a re-decode in a
    /// `catch` is #238's failure scenario with the type name filed off. It was accounted for by
    /// `scalars` and forbidden by nothing.
    static let fanStateTypes = [
        "SystemSnapshot", "SensorSample",
        "Fan", "FanState", "FanReading", "FanSetting",
        "FanControlMode", "ManualControlAvailability",
        "LabelConfidence", "Unit", "Control",
        "Data",
    ]

    /// The types manual control arrives in. Separate from the list above because the rule they
    /// break is a different one: a stored snapshot is rule 6 (claiming control you do not
    /// have), a stored lease is ADR 0007 (manual control is never silently re-asserted).
    static let leaseTypes = ["Lease", "LeaseRequest"]

    /// Where each **struct** on the two lists is declared, so its own fields can be read.
    ///
    /// This is what makes the lists self-maintaining instead of hand-written: a type on a
    /// forbidden list is either here, and its fields are audited by
    /// `theFanStateListNamesEveryTypeTheseDTOsCarry`, or it is on `opaqueToTheParser` and the
    /// reason is stated. `theForbiddenListsAreFullyAccountedFor` requires the three sets to
    /// partition, so adding a type to a list without deciding which it is fails.
    private static let declarationSites = [
        "SystemSnapshot": payloadFile, "SensorSample": payloadFile,
        "LeaseRequest": payloadFile,
        "Fan": "Fan.swift", "FanState": "Fan.swift",
        "FanSetting": "Profile.swift", "Lease": "Lease.swift",
    ]

    /// The entries whose own fields this parser cannot enumerate, and why.
    ///
    /// `SeamScanner.properties(inSource:file:)` states that an `enum case` with an associated
    /// value is not scanned, and every type here is either such an enum — `FanReading`,
    /// `ManualControlAvailability` and `FanSetting.Control` all carry values in their cases —
    /// or a raw-value enum with no storage at all (`FanControlMode`, `SensorSample.Unit`,
    /// `SensorSample.LabelConfidence`), or `Data`, which is Foundation's. What catches a value
    /// hidden in a case is the stored property of the enum's own type, which is exactly what
    /// the two lists forbid.
    private static let opaqueToTheParser: Set<String> = [
        "FanReading", "FanControlMode", "ManualControlAvailability",
        "LabelConfidence", "Unit", "Control", "Data",
    ]

    /// The scalars a DTO may carry without being fan state itself.
    ///
    /// Written out so that a DTO growing a field of a *new* type fails
    /// `theFanStateListNamesEveryTypeTheseDTOsCarry` rather than passing it. Padding this to
    /// silence that failure is a decision an author has to make in the open, which is the
    /// point — and `Data` was removed from it for exactly that reason, because it was the one
    /// entry doing the silencing.
    private static let scalars = [
        "Int", "Double", "Bool", "String", "Date", "TimeInterval", "UUID",
    ]

    /// **The client keeps no copy of what the helper said about the fans.**
    ///
    /// `CLAUDE.md`'s row for this target says it "holds no fan state", and #237's body called
    /// that structural. It was not: it was the current absence of a stored property, and a
    /// fifth one compiles beside the four that are there. The failure that absence prevents is
    /// rule 6 exactly — `private var lastSnapshot: SystemSnapshot?` added to smooth a UI
    /// flicker, served when `snapshot()` throws `helperNeverAnswered`, and the app renders a
    /// fan speed nothing is honouring. Every test in this package stays green, because nothing
    /// in it can tell a fresh snapshot from a remembered one: both decode.
    ///
    /// Scoped to **stored** declarations outside every function body, which is the whole of
    /// the point. Each verb in `HelperClientVerbs.swift` decodes a `SystemSnapshot` into a
    /// local and returns it, and must go on doing so; the same type on the actor is the defect.
    /// A computed property is not storage either — it can only re-derive what something else
    /// holds, and what it would have to hold is what this forbids.
    ///
    /// **A type-name tripwire, and that is a limit rather than an oversight.** What it forbids
    /// is a stored declaration *naming* one of these types, so a spelling that names none of
    /// them escapes: `private var wasReclaimed: Bool` remembers one bit of `FanState` and this
    /// cannot see it. The three routes worth having were closed — the type position, the
    /// initialiser (`private let cached = SystemSnapshot(…)`, which `Property.names` reads), and
    /// the wire form (`private var lastSnapshotPayload: Data?`, which `Data`'s move off
    /// `scalars` and onto `fanStateTypes` now catches) — and a scalar field copied out one at a
    /// time is not reachable from any list of type names. What would catch that is a review of
    /// a declaration whose name says what it remembers, which is a reader's job.
    ///
    /// **Mutation:** add `private var lastSnapshot: SystemSnapshot?` to `HelperClient`. Run:
    /// red, naming the declaration. **Mutation:** add `private let cached = SystemSnapshot(…)`,
    /// whose type is written nowhere — red too, because `Property.names` reads the initialiser
    /// as well as the type position. **Mutation:** add `private var lastSnapshotPayload: Data?`
    /// — red, which it was not while `Data` sat on `scalars`.
    @Test("The client stores no fan state")
    func theClientStoresNoFanState() throws {
        let stored = try SeamScanner.properties(in: Self.target).filter(\.isStored)
        #expect(!stored.isEmpty, "no stored property was found in Sources/\(Self.target) at all")

        let holding = stored.filter { !$0.names.filter(Self.fanStateTypes.contains).isEmpty }

        #expect(
            holding.isEmpty,
            """
            \(holding.map { "\($0.file): \($0.text)" }.sorted()) stores what the helper said \
            about the fans. A client that can serve a remembered answer will serve one when \
            the fresh one fails, and `CLAUDE.md` rule 6 is that a reported target nothing is \
            honouring is worse than an error, because the user acts on it. The verbs decode \
            these into locals and return them; nothing in this target may keep one.
            """)
    }

    /// **The client stores no lease and no lease identifier**, so there is nothing to renew or
    /// replay with.
    ///
    /// `docs/SAFETY.md` § 4 and ADR 0007 both rule that manual control is not silently
    /// re-asserted, and `HelperClientVerbs` says renewal is the caller's job "because a lease
    /// renewed by the transport layer is a lease nobody is proving they still want". A stored
    /// `LeaseRequest` replayed on `.interrupted` would be exactly that: the fans handed back
    /// to a client that has stopped asking, by the one layer whose whole design is that it
    /// does not decide anything.
    ///
    /// Two halves, because the identifier has no type of its own: `renewLease(id:)` takes a
    /// `UUID`, which is indistinguishable from any other stored `UUID` — the observer tokens
    /// in `observers` are `UUID`s too. So the type half forbids `Lease` and `LeaseRequest`,
    /// and the name half forbids a stored property with `lease` as a **word** in its name.
    ///
    /// A word rather than a substring, split on the camel humps: `wasReleased` contains
    /// "lease" and is not a lease identifier, and a tripwire that fired on it would be
    /// deleted by the third person it inconvenienced. `heldLease`, `leaseID` and
    /// `pendingLeaseRequest` all split to a `lease` word.
    ///
    /// **Mutation:** add `private var heldLease: Lease?` — red on the type half. **Mutation:**
    /// add `private var leaseID: UUID?`, whose type says nothing — red on the name half, which
    /// is the one the type half cannot cover.
    @Test("The client stores no lease and no lease identifier")
    func theClientStoresNoLease() throws {
        let stored = try SeamScanner.properties(in: Self.target).filter(\.isStored)
        #expect(!stored.isEmpty, "no stored property was found in Sources/\(Self.target) at all")

        let byType = stored.filter { !$0.names.filter(Self.leaseTypes.contains).isEmpty }
        let byName = stored.filter { Self.words(of: $0.name).contains("lease") }
        // A set, because the two halves overlap on the declaration that is caught by both —
        // `heldLease: Lease?` is one defect and reads as two in a concatenated list.
        let holding = Set((byType + byName).map { "\($0.file): \($0.text)" }).sorted()

        #expect(
            holding.isEmpty,
            """
            \(holding) stores a lease or \
            the identifier of one. Whatever holds either can replay it after an interruption, \
            and ADR 0007 is that manual control is re-acquired by the caller that still wants \
            it, never re-asserted by the transport. `renewLease(id:)` takes the identifier as \
            an argument for this reason.
            """)
    }

    /// `heldLease` → `["held", "lease"]`. The camel humps, lowercased.
    private static func words(of name: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in name {
            if character.isUppercase, !current.isEmpty {
                words.append(current.lowercased())
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    /// The hand-written lists are complete, judged against the DTOs themselves.
    ///
    /// The lists' first entries come from a file; the types those embed are typed out, and a
    /// list typed out by hand is a list that goes stale on the day a DTO grows a field. So this
    /// reads the stored properties of **every struct on either list** and requires every type
    /// they name to be accounted for — on one of the two forbidden lists, or on `scalars`.
    ///
    /// **Every struct, not just `SystemSnapshot`.** The first version read `SystemSnapshot`'s
    /// own fields and stopped, which validated three of the six entries and descended into
    /// none. `FanState` carries `mode: FanControlMode` and `manualControlAvailability:
    /// ManualControlAvailability`, both public FanKit types nameable from the client and both on
    /// no list, so `private var lastMode: FanControlMode?` stored on `HelperClient` — a
    /// remembered per-fan control mode, served to a UI badge when `snapshot()` throws
    /// `helperNeverAnswered` — left this test and `theClientStoresNoFanState` green together.
    /// `Fan`, `FanReading` and `FanSetting` were validated by nothing at all. Reading every
    /// listed struct closes that at every depth, because a type a listed struct embeds is
    /// itself forced onto a list and then read in turn.
    ///
    /// This is the tripwire's **own** mutation, and it is the reason it exists: a
    /// source-scanning guard whose list is short is a guard that always finds nothing, which
    /// is a decoration rather than a guard. Deleting `FanState` from `fanStateTypes` leaves
    /// `theClientStoresNoFanState` green — that is silent. It fails *here*, loudly, whatever
    /// the client currently contains.
    ///
    /// **Mutation:** delete `"FanState"` from `fanStateTypes`. Run: red here, green there.
    /// **Mutation:** delete `"FanControlMode"`. Run: red here, because `FanState`'s own fields
    /// are now read — which is what the first version could not say.
    @Test("The forbidden lists name every type these DTOs carry")
    func theFanStateListNamesEveryTypeTheseDTOsCarry() throws {
        var carried: Set<String> = []
        for (type, file) in Self.declarationSites.sorted(by: { $0.key < $1.key }) {
            let body = try SeamScanner.structBody(of: type, in: file)
            let names =
                SeamScanner
                .properties(inSource: body, file: file)
                .filter(\.isStored)
                .flatMap(\.names)
            #expect(!names.isEmpty, "\(type)'s stored properties were not found in \(file)")
            // `Property.names` splits an initialiser on everything that cannot be part of a
            // name, so a numeric literal arrives as a token: `Lease.defaultTimeToLive = 30`
            // reports "30". No Swift type name can begin with a digit, so dropping those loses
            // nothing a forbidden list could ever hold.
            carried.formUnion(names.filter { !($0.first?.isNumber ?? true) })
        }

        let accounted = Self.fanStateTypes + Self.leaseTypes + Self.scalars
        let unaccounted = carried.subtracting(accounted).sorted()

        #expect(
            unaccounted.isEmpty,
            """
            the DTOs on the two forbidden lists carry \(unaccounted), which neither list names \
            and `scalars` does not either. A DTO field of an unlisted type is a DTO the client \
            may store one field of, so a list grows or `scalars` does — visibly, in this file.
            """)
    }

    /// Every struct on a forbidden list is either **read** by the check above or **declared
    /// unreadable**, with the reason stated.
    ///
    /// `declarationSites` is what lets the check above descend, and nothing made it keep up with
    /// the lists: a type added to `fanStateTypes` and to neither of the two sets below would be
    /// forbidden as client storage and never audited for what *it* carries, which is the gap
    /// that hid `FanControlMode` for one review round. The three sets must partition, so the
    /// decision — "read this one" or "the parser cannot, because its cases carry the values" —
    /// is made in the open.
    ///
    /// **Mutation:** add `"Profile"` to `fanStateTypes`. Run: red, naming it as accounted for
    /// nowhere.
    @Test("Every forbidden type is either read or declared unreadable")
    func theForbiddenListsAreFullyAccountedFor() {
        let listed = Set(Self.fanStateTypes + Self.leaseTypes)
        let read = Set(Self.declarationSites.keys)

        #expect(
            read.intersection(Self.opaqueToTheParser).isEmpty,
            """
            \(read.intersection(Self.opaqueToTheParser).sorted()) is both read and declared \
            unreadable. One of the two is wrong, and the check above believes the first.
            """)
        #expect(
            listed.symmetricDifference(read.union(Self.opaqueToTheParser)).isEmpty,
            """
            \(listed.symmetricDifference(read.union(Self.opaqueToTheParser)).sorted()) is on a \
            forbidden list without being read, or is read without being forbidden. A forbidden \
            type whose own fields nobody enumerates is how a field of an unlisted type reaches \
            the client: name where it is declared, or say why the parser cannot read it.
            """)
    }

    /// **Every DTO in the payload file is on a forbidden list.**
    ///
    /// `fanStateTypes` documents its first entries as "every `public struct` in
    /// `AeolusXPCPayload.swift` bar the lease pair", and that derivation was checked by nothing:
    /// appending a `public struct FanTargetReport { let fanIndex: Int; let targetRPM: Int }` to
    /// that file and storing `private var lastTargetReport: FanTargetReport?` on `HelperClient`
    /// left every test in this suite green. A new DTO is exactly how the next remembered fan
    /// speed arrives — it is the natural place to put one — so the file is enumerated rather
    /// than quoted.
    ///
    /// Top-level structs only, by the column-zero `public struct`: a nested one is a field type
    /// of its parent and is reached by `theFanStateListNamesEveryTypeTheseDTOsCarry` instead. A
    /// `public enum` carrying fan state in an associated value is the stated hole, and it is the
    /// same one `opaqueToTheParser` records — what catches it is the stored property of that
    /// enum's type.
    ///
    /// **Mutation:** add a `public struct FanTargetReport` to the payload file. Run: red,
    /// naming it.
    @Test("Every DTO in the payload file is on a forbidden list")
    func everyPayloadDTOIsOnAForbiddenList() throws {
        let file = try #require(
            SeamScanner.swiftFiles().first { $0.lastPathComponent == Self.payloadFile },
            "\(Self.payloadFile) is not in the source tree")
        let code = SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8))
        let declaration = try NSRegularExpression(
            pattern: #"(?m)^public struct ([A-Za-z_]\w*)"#)
        let declared = declaration
            .matches(in: code, range: NSRange(code.startIndex..<code.endIndex, in: code))
            .compactMap { Range($0.range(at: 1), in: code).map { String(code[$0]) } }

        #expect(!declared.isEmpty, "no public struct was found in \(Self.payloadFile)")

        let forbidden = Set(Self.fanStateTypes + Self.leaseTypes)
        let unlisted = Set(declared).subtracting(forbidden).sorted()

        #expect(
            unlisted.isEmpty,
            """
            \(unlisted) are DTOs in \(Self.payloadFile) that neither forbidden list names. \
            Everything the helper answers with about this machine crosses in that file, and a \
            DTO on no list is one the client may store — which is the remembered answer rule 6 \
            forbids, under a name nothing is watching for.
            """)
    }

    // MARK: - What the send path may not do

    /// The three callees that are on the send path without calling into it.
    ///
    /// The downward half of `sendPath()`'s closure now reaches all three on its own, so this is a
    /// **floor** rather than the derivation it started as: naming them is what makes their absence
    /// a failure instead of a smaller population.
    ///
    /// `liveConnection` looping over a refused pinning is the boot-loop amplifier
    /// `HelperClient`'s own documentation argues against; `translate` looping is the reconnect
    /// ADR 0007 forbids, written at the one point that has a failed message in hand; and
    /// `pinnedConnection` is where the connection is actually built, so a loop there retries
    /// `transport.makeConnection()` against a mach name launchd may be restarting.
    ///
    /// `pinnedConnection` was **not** here, and adding the name alone would have changed
    /// nothing: `functionBody(named:inSource:)` took the first declaration in the file, which is
    /// `HelperConnectionPinning`'s bodiless requirement, so the name resolved to no body and
    /// `sendPath()` dropped it. A three-attempt retry inside `SignedHelperPinning`'s
    /// implementation was green. The scanner takes the first declaration *with a body* now, and
    /// the floor below is what proves the name arrived.
    private static let sendPathCallees = ["liveConnection", "translate", "pinnedConnection"]

    /// The names `sendPath()` must reach, so a rename cannot quietly empty the population.
    ///
    /// Every verb is here as well as the gates. A verb that stopped going through a gate would
    /// drop out of the derivation and fail this — which makes it a second, independent check
    /// on the claim `theUnhandshakenProxyHasExactlyOneCaller` counts.
    ///
    /// It is a **floor and not an allowlist**, which is what keeps it from being the usual
    /// list-that-rots: what gets scanned is the derived population, so shortening this cannot
    /// shrink what the test looks at — only stop it noticing that something vanished.
    ///
    /// `sendPathCallees` is asserted against the population **through this floor**, by the union
    /// the test takes. Without that, a name added to `sendPathCallees` whose body cannot be
    /// found is a silent no-op — which is exactly what `pinnedConnection` was, and the only
    /// reason the other two were not is that they happen to be here as well.
    private static let sendPathFloor: Set<String> = [
        "exchange", "withProxy", "withHandshakenProxy", "handshakenConnection",
        "performHandshake", "liveConnection", "translate", "pinnedConnection",
        "snapshot", "acquireLease", "renewLease", "releaseLease", "apply",
        "restoreAllToAutomatic",
    ]

    /// Every function in the client that reaches a proxy, **derived** from the source.
    ///
    /// `exchange` is the one function that hands a message to a proxy, and the population is its
    /// transitive closure **in both directions**, plus `sendPathCallees`. Derived rather than
    /// listed because a list is exactly what a verb added next year is not on: the eighth message
    /// will be written the way the other seven are, through a gate, and will be in this
    /// population the moment it exists.
    ///
    /// **Both directions, and the downward one is why.** The first version grew upward only —
    /// the transitive *callers* of `exchange` — so a helper factored out one level *below* it was
    /// in neither the derivation nor `sendPathCallees`. Factoring the send into `private func
    /// resend<Answer>(to typed: any AeolusXPCProtocol, …)` whose body is `for _ in 0..<3 { … }`,
    /// and calling it from `exchange`, left this test green: `resend`'s body names nothing on the
    /// path. That is #238's scenario one ordinary refactor away, and writing a retry as its own
    /// small function is at least as natural as writing it inline.
    ///
    /// The downward half is **unrestricted**, and exactly one function in this target needs
    /// saying so out loud: `publish`, whose `for continuation in observers.values` is a fan-out
    /// over the health stream's observers and not a retry of anything. It is named in
    /// `sendPathFanOut` and exempted from the loop half alone — it stays in the population for
    /// the recursion and double-send halves, and the test requires it to be *in* the population,
    /// so the exemption cannot quietly become a no-op. A restriction to `async` callees was the
    /// alternative and is worse: it reads as principled (a retry must `await` what it retries)
    /// and it lets the exact mutation above through, because a `resend` that loops without
    /// awaiting anything is not `async` and is still a retry.
    ///
    /// The limits: a name no declaration of which has a body — a protocol requirement with no
    /// conformer in this target — is skipped, and the floor is what stops that being silent for
    /// any name this test depends on. And the reachability test is call-shaped (`name(` or
    /// `name {`) rather than a bare substring, which no longer counts a body merely *mentioning*
    /// a name — a change that could only shrink the population, which is the direction the floor
    /// watches.
    private static func sendPath() throws -> [(name: String, file: String, body: String)] {
        let sources = try Dictionary(
            uniqueKeysWithValues: Self.sources().map { ($0.file, $0.code) })
        var bodies: [(name: String, file: String, body: String)] = []
        var seen: Set<String> = []

        for function in try SeamScanner.functions(in: Self.target) {
            guard !seen.contains("\(function.file): \(function.name)"),
                let source = sources[function.file],
                let body = try SeamScanner.functionBody(named: function.name, inSource: source)
            else { continue }
            seen.insert("\(function.file): \(function.name)")
            bodies.append((name: function.name, file: function.file, body: body))
        }

        var reached: Set<String> = ["exchange"]
        reached.formUnion(Self.sendPathCallees)
        var growing = true
        while growing {
            growing = false
            for function in bodies where !reached.contains(function.name) {
                // Upward: this function calls something already on the path. Downward: something
                // already on the path calls this one.
                let onThePath =
                    try reached.contains { try Self.calls($0, in: function.body) }
                    || bodies.contains {
                        try reached.contains($0.name) && Self.calls(function.name, in: $0.body)
                    }
                guard onThePath else { continue }
                reached.insert(function.name)
                growing = true
            }
        }

        return bodies.filter { reached.contains($0.name) }
    }

    /// How often `name` is **called** in `body`: the name followed by a `(` or a `{`.
    ///
    /// The `{` is not optional. Every gated verb in `HelperClientVerbs.swift` is written `try
    /// await withHandshakenProxy { proxy, resolve in … }`, a trailing closure with no parameter
    /// list at all, so a `name\s*\(` pattern reaches none of them.
    private static func callCount(of name: String, in body: String) throws -> Int {
        let call = try NSRegularExpression(pattern: #"\b\#(name)\s*[({]"#)
        return call.numberOfMatches(
            in: body, range: NSRange(body.startIndex..<body.endIndex, in: body))
    }

    /// Whether `body` calls `name` at all. A separate name rather than an overload differing only
    /// in return type: Swift resolves those by context, and a resolution nobody can see at the
    /// call site is how a helper ends up shadowing the one that was meant.
    private static func calls(_ name: String, in body: String) throws -> Bool {
        try callCount(of: name, in: body) > 0
    }

    /// **Nothing on the send path loops, and nothing on it calls itself.**
    ///
    /// The claim #237's body makes is "no internal retry loop anywhere", and the argument
    /// behind it is not a style preference: a client that retries into a mach name launchd is
    /// restarting a daemon behind is a boot-loop amplifier, and the retry would be invisible to
    /// every caller — a verb that eventually succeeded after three attempts reports exactly
    /// what one that succeeded first time does. There is nothing to observe at runtime, which
    /// is what makes this a source tripwire rather than a test.
    ///
    /// `for`, `while` and `repeat` are the whole of it, and that is a completeness claim rather
    /// than a list of the ones worth catching: every function in this population is `async`,
    /// and a retry has to `await` the thing it is retrying. `forEach` and the other sequence
    /// verbs take a non-`async` closure, so a retried `await` cannot be written with one. What
    /// does escape is **recursion**, so the second half of this test forbids a function on the
    /// path from calling itself — bare or through `self.`, not through `proxy.`, since a verb
    /// and the protocol message it sends share a name by design. Mutual recursion between two
    /// of them is the remaining hole, and it is stated rather than closed.
    ///
    /// The third half is a **second send in one body**, and it is the retry an author actually
    /// writes: `do { … } catch { /* second attempt */ … }` around the same gate is neither a loop
    /// nor recursion, so the completeness argument above did not reach it and the two halves were
    /// green with a two-attempt `snapshot()` in the tree. Counting the gate calls per body is the
    /// pattern this file already uses for `withProxy`; here it is per derived body rather than
    /// per file, so a second attempt is caught in whichever verb wrote it.
    ///
    /// **Mutation:** wrap `exchange`'s body in `for attempt in 0..<3 { … }`. Run: red, naming
    /// `exchange`. **Mutation:** write the same loop with a typed binding, `for attempt: Int in
    /// 0..<3 { … }`. Run: red — which it was **not** while the loop pattern carried a `(?!\s*\w+
    /// \s*:)` lookahead meant for a parameter label. **Mutation:** make `snapshot()` retry itself
    /// — `if data.isEmpty { return try await snapshot() }`. Run: red on the recursion half, which
    /// the loop half cannot see. **Mutation:** give `snapshot()` a second
    /// `withHandshakenProxy { … }` in a `catch`. Run: red on the count, which neither other half
    /// sees. **Mutation:** rename `exchange`. Run: red on the floor, which is what stops a rename
    /// from emptying the population silently.
    @Test("Nothing on the send path loops or calls itself")
    func nothingOnTheSendPathRetries() throws {
        let path = try Self.sendPath()
        let loop = try NSRegularExpression(pattern: Self.loopPattern)
        var looping: [String] = []
        var recursive: [String] = []
        var sendingTwice: [String] = []

        for function in path {
            // A leading space, so a loop written as the body's first token is still preceded by
            // something the lookbehind accepts.
            let body = " " + function.body
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            if loop.numberOfMatches(in: body, range: range) > 0,
                !Self.sendPathFanOut.contains(function.name)
            {
                looping.append("\(function.file): \(function.name)")
            }

            let bare = try NSRegularExpression(pattern: #"(?<![\w.])\#(function.name)\s*\("#)
            let qualified = try NSRegularExpression(pattern: #"self\.\#(function.name)\s*\("#)
            let calls =
                bare.numberOfMatches(in: body, range: range)
                + qualified.numberOfMatches(in: body, range: range)
            if calls > 0 { recursive.append("\(function.file): \(function.name)") }

            let sends = try Self.sendGates.reduce(0) {
                $0 + (try Self.callCount(of: $1, in: function.body))
            }
            if sends > 1 { sendingTwice.append("\(function.file): \(function.name)") }
        }

        #expect(
            Self.sendPathFloor.union(Self.sendPathCallees).subtracting(path.map(\.name)).isEmpty,
            """
            the send path derived from the source is \(path.map(\.name).sorted()), which does \
            not reach \
            \(Self.sendPathFloor.union(Self.sendPathCallees).subtracting(path.map(\.name)).sorted()). \
            Either a verb no longer goes through a gate, or something on the path was renamed, or \
            a name this test asks for resolved to no body — and a population that no longer \
            contains a function is a guard that no longer watches it, silently.
            """)
        #expect(
            looping.isEmpty,
            """
            \(looping.sorted()) loops. A client-side retry is invisible to its caller and \
            amplifies a helper launchd is already restarting; every one of the four situations \
            `HelperClient` gives up a connection in is a teardown, and the caller asks again at \
            its own cadence or does not.
            """)
        #expect(
            recursive.isEmpty,
            """
            \(recursive.sorted()) calls itself. Recursion is the one retry that is not a loop, \
            and it is the same defect: a second attempt this client decided to make, reported \
            to nobody.
            """)
        #expect(
            sendingTwice.isEmpty,
            """
            \(sendingTwice.sorted()) reaches a gate more than once. That is the retry an author \
            writes without a loop and without recursion — a second attempt in a `catch` — and it \
            is the same defect for the same reason: the caller cannot tell a verb that succeeded \
            first time from one that succeeded on the second try.
            """)
    }

    /// The gates a body may call at most once. `exchange` is the send itself; the two `withProxy`
    /// spellings are the only ways to reach it.
    private static let sendGates = ["exchange", "withProxy", "withHandshakenProxy"]

    /// The one function on the path whose loop is a **fan-out** rather than a retry.
    ///
    /// `publish`'s `for continuation in observers.values` yields one health value to every
    /// observer of the stream; it retries nothing and sends nothing. It is on the path because
    /// `liveConnection`, `performHandshake` and `discardConnection` all call it, which is the
    /// price of closing the path downward — and paying that price out loud, for one named
    /// function, is better than the `async`-only restriction that would have hidden it along with
    /// a `resend` that loops.
    ///
    /// Exempted from the **loop half only**. It is still scanned for recursion and for a second
    /// send, and `theSendPathFanOutIsOnThePath` requires it to be in the population — so a rename
    /// turns this into a red test rather than into a silently empty exemption.
    private static let sendPathFanOut = ["publish"]

    /// The fan-out exemption names a function that is really there, and really has nothing to
    /// send.
    ///
    /// An exemption list is where the next retry gets written, so this is the guard on the guard:
    /// a name here that has left the population is an exemption covering nothing, and a name here
    /// that reaches a gate is a send site exempted from the loop rule.
    ///
    /// **Mutation:** rename `publish`. Run: red here. **Mutation:** add `try await
    /// withHandshakenProxy { … }` to `publish`'s body. Run: red here.
    @Test("The fan-out exemption names a function on the path that sends nothing")
    func theSendPathFanOutIsOnThePath() throws {
        let path = try Self.sendPath()

        for name in Self.sendPathFanOut {
            let function = try #require(
                path.first { $0.name == name },
                """
                \(name) is exempted from the loop rule and is not on the send path. An exemption \
                covering nothing is an exemption that has stopped saying what it meant, and the \
                loop it was written for is now either gone or unwatched.
                """)
            let sends = try Self.sendGates.reduce(0) {
                $0 + (try Self.callCount(of: $1, in: function.body))
            }
            #expect(
                sends == 0,
                """
                \(name) reaches a gate and is exempted from the loop rule. It is on this list \
                because it fans a health value out to observers and sends nothing; a version of \
                it that sends is a retry loop with a written permission slip.
                """)
        }
    }

    /// What counts as a loop, extracted so `theLoopPatternReadsLoopsAndNotLabels` can pin it.
    ///
    /// `while` and `repeat` are taken bare: both are Swift keywords, so neither can be an
    /// argument label without backticks, and the lookahead the first version applied to all three
    /// bought nothing on those two.
    ///
    /// `for` needs its `in`, and that is the fix rather than a refinement. The first version was
    /// `(for|while|repeat)\b(?!\s*\w+\s*:)`, whose lookahead was there to skip an argument label
    /// — `func send(for name: String)` — and which also skipped a loop binding written with a
    /// type: `for attempt: Int in 0..<3 { … }` inside `exchange` left this test **green**, one
    /// word away from the mutation the body cites as red. Requiring the `in` separates the two
    /// without a lookahead: a label is `for name:` and never reaches one, a loop always does. The
    /// scan stops at a `{`, `}` or `;` so it cannot run out of a header into a body.
    static let loopPattern =
        #"(?<=[\s{};])(?:while|repeat)\b|(?<=[\s{};])for\b[^{};]*?\bin\b"#

    /// The loop pattern reads loops and not argument labels — **fixtures, because nothing else
    /// pins it.**
    ///
    /// Every other claim in this file is asserted against `Sources`, which is exactly why this
    /// pattern went wrong: the tree contains no typed loop binding, so the tree could not say the
    /// pattern missed one. `SeamScannerScopeParsingTests` covers the parser's own shapes and
    /// never this regex.
    ///
    /// **Mutation:** restore the `(?!\s*\w+\s*:)` lookahead. Run: red on the typed binding.
    /// **Mutation:** drop the `\bin\b` requirement. Run: red on the argument label.
    @Test("The loop pattern reads loops and not argument labels")
    func theLoopPatternReadsLoopsAndNotLabels() throws {
        let loop = try NSRegularExpression(pattern: Self.loopPattern)
        func matches(_ code: String) -> Bool {
            let body = " " + code
            return loop.numberOfMatches(
                in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)) > 0
        }

        for retry in [
            "for attempt in 0..<3 { _ = attempt }",
            "for attempt: Int in 0..<3 { _ = attempt }",
            "for (index, value) in pairs { _ = value }",
            "while !done { done = true }",
            "repeat { done = true } while !done",
            "{ for _ in 0..<3 { send() } }",
        ] {
            #expect(matches(retry), "\(retry) is a loop and this pattern does not read it")
        }

        // A `for` the lookbehind actually reaches: preceded by a space rather than by the `(` of
        // a call, which is the shape the old lookahead was written for. A negative fixture whose
        // `for` sits immediately after `(` proves nothing — the lookbehind refuses it before any
        // of this is consulted, and two of the first drafts here were exactly that.
        for notALoop in [
            "func send(to sink: Sink, for name: String) { }",
            "func reset(index: Int, for fan: Fan) async throws -> Fan { fan }",
            "reset(index, for: fan) { error in resolve(error) }",
            "let deadline = deadlines.forVerb",
        ] {
            #expect(!matches(notALoop), "\(notALoop) is not a loop and this pattern reads one")
        }
    }

    // MARK: - What the rest of the tree may not do

    /// **This target owns every `NSXPCConnection` outside the helper, and constructs every one
    /// in the tree.**
    ///
    /// `CLAUDE.md`'s row is "the only `NSXPCConnection` outside the helper", and the reason is
    /// the pinning policy two tests above: a connection built anywhere else is a connection
    /// that did not go through `pinnedConnection(over:)`, so it talks to whoever answered the
    /// mach name. A SwiftUI view model that built its own — the shortest path to a preview that
    /// does not need the helper — would compile, would pass, and would be a client of an
    /// unverified peer.
    ///
    /// Two halves. The naming half is the architectural claim: outside `AeolusHelper`, which
    /// receives connections it never builds, only this target may name the type. The
    /// construction half is sharper and is where the risk actually is — exactly one file in
    /// `Sources` calls the initialiser, and it is the transport whose result
    /// `SignedHelperPinning` applies a requirement to.
    ///
    /// Comments are stripped first, which matters here more than usual: `AeolusXPC` discusses
    /// `NSXPCConnection` at length in prose and touches it in none of its code.
    ///
    /// **Mutation:** add `_ = NSXPCConnection(machServiceName: "x")` to a file under
    /// `Sources/AeolusUI`. Run: red on both halves. **Mutation:** add the same line to
    /// `Sources/AeolusHelper` — red on the construction half only, which is the half that says
    /// where a connection may be born.
    @Test("The client target owns every NSXPCConnection in Sources")
    func theClientTargetOwnsEveryConnection() throws {
        let construction = try NSRegularExpression(pattern: #"(?<![\w.])NSXPCConnection\s*\("#)
        var naming: Set<String> = []
        var constructing: Set<String> = []

        for file in try SeamScanner.swiftFiles() {
            let code = SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8))
            guard code.contains("NSXPCConnection") else { continue }
            naming.insert(Self.owningTarget(of: file))
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            if construction.numberOfMatches(in: code, range: range) > 0 {
                constructing.insert(file.lastPathComponent)
            }
        }

        #expect(
            naming.contains(Self.target), "nothing in Sources/\(Self.target) names a connection")
        #expect(
            naming.subtracting(["AeolusHelper", Self.target]).isEmpty,
            """
            \(naming.sorted()) name an `NSXPCConnection`. Only this target may, outside the \
            helper that receives them: a connection reached anywhere else is one that did not \
            go through `pinnedConnection(over:)`, and being able to connect is not \
            authorisation.
            """)
        #expect(
            constructing == ["HelperClientTransport.swift"],
            """
            \(constructing.sorted()) construct an `NSXPCConnection`. Exactly one file may, and \
            it is the transport `SignedHelperPinning` applies the code-signing requirement to — \
            a second construction site is a client of whoever answered the mach name.
            """)
    }

    /// Which target directory under `Sources` a file belongs to.
    private static func owningTarget(of file: URL) -> String {
        file.pathComponents.drop(while: { $0 != "Sources" }).dropFirst().first
            ?? file.lastPathComponent
    }

    /// **No build graph links this target into the root daemon.**
    ///
    /// `CLAUDE.md`'s row says the client "never runs as root", and nothing in the language
    /// enforces that: `HelperClient` compiles perfectly well inside a root daemon, and the
    /// shortest route to one is a helper that wants to talk to *itself* for a reconciliation
    /// pass. What keeps the claim true is that no build graph puts this code in that process,
    /// which is a property of two files rather than of any Swift declaration — so it is checked
    /// at those two files.
    ///
    /// **Both** of them, because they are not redundant: `Package.swift` is what CI builds and
    /// `project.yml` is what generates the Xcode project that produces the shipping helper.
    /// The one previous defect of this exact shape — an access level that compiled under
    /// SwiftPM and broke in the Xcode build — was invisible to CI for the same reason, and the
    /// fix there was to check the thing CI does not run.
    ///
    /// Both halves `#require` that they found what they slice, and both carry a **floor** of
    /// the products the daemon does link. Neither is defensive padding — each stands for a
    /// defect the mutation found, and the floor is what the first two had in common:
    ///
    /// - The first version matched the bare `name: "AeolusHelper",`, which found the
    ///   `.executable(…)` **product** declared forty lines above the target. The region it
    ///   sliced contained no dependencies at all, so adding `"AeolusXPCClient"` to the daemon's
    ///   real ones left it **green**. A test that passed and could not fail.
    /// - Anchoring on `.executableTarget(` fixed that and made it fail on the **clean** tree,
    ///   because a target's declaration runs up to the next target and the comment between
    ///   them is `fanctl`'s — which explains at length why *it* links `AeolusXPCClient`.
    /// - The `project.yml` half then sliced from `^    dependencies:$` to the next `^    \S`,
    ///   and `#` is `\S`. This file's own style puts target-level comments at exactly four
    ///   spaces, so one comment line immediately below `dependencies:` collapsed the region to
    ///   nothing and the `product: AeolusXPCClient` below it passed. `ruby -ryaml` confirmed the
    ///   mutated file resolves `AeolusHelper` to `[SMCCore, FanKit, AeolusXPC, AeolusXPCClient]`:
    ///   the graph that builds the shipping helper linked the client, and the half this test's
    ///   own body calls "the one CI never builds" was green. Whole-line comments are stripped
    ///   now, and the floor is what makes an empty region fail rather than pass.
    ///
    /// The `project.yml` half reads the target's **whole region** rather than its dependency
    /// list, and that is the fourth mutation: `- path: Sources/AeolusXPCClient` added to the
    /// same target's `sources:` compiles every line of the client into the root daemon, which is
    /// precisely what the name of this test forbids, and a dependency-list scan cannot see it.
    /// In xcodegen a `sources:` entry is a plausible way for someone to "just include" a file.
    /// Reading the region is only safe because the comments are gone: a region-wide search is
    /// what fired on the clean tree above, and the comment it fired on is the kind that is now
    /// dropped.
    ///
    /// **Mutation:** add `"AeolusXPCClient"` to the `AeolusHelper` target's `dependencies` in
    /// `Package.swift`. Run: red. **Mutation:** add the matching `product: AeolusXPCClient`
    /// entry under `AeolusHelper:` in `project.yml`. Run: red — and green in `Package.swift`,
    /// which is the whole reason both are read. **Mutation:** add `- path:
    /// Sources/AeolusXPCClient` to that target's `sources:`. Run: red, which the dependency-list
    /// version was not. **Mutation:** delete the daemon's `product: FanKit` entry. Run: red on
    /// the floor, which is what a region that shrank to nothing trips.
    @Test("No build graph links the client into the root daemon")
    func theRootDaemonDoesNotLinkTheClient() throws {
        let root = SeamScanner.sourcesRoot.deletingLastPathComponent()

        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        // The `.executableTarget(` prefix is what makes this the **target** rather than the
        // `.executable(` product of the same name declared forty lines above it. The first
        // version of this test matched the bare `name: "AeolusHelper",`, found the product,
        // and sliced a region that could not contain a dependency at all: adding
        // `"AeolusXPCClient"` to the daemon's real `dependencies` left it green. It was a test
        // that passed and could not fail, and the mutation is the only reason it is not still
        // one.
        let daemon = try #require(
            manifest.range(
                of: #"\.executableTarget\(\s*name: "AeolusHelper","#, options: .regularExpression),
            "Package.swift no longer declares an executable target named AeolusHelper")
        let nextTarget =
            manifest.range(
                of: #"\.(?:executableTarget|target|testTarget)\("#, options: .regularExpression,
                range: daemon.upperBound..<manifest.endIndex)?.lowerBound ?? manifest.endIndex
        // The **dependency list**, not the target's whole declaration. The declaration runs up
        // to the next target, and what sits between the two is the comment introducing that
        // one — which, for `fanctl`, explains at length why it links `AeolusXPCClient`. A
        // region-wide search therefore fired on the clean tree, which is the mirror image of
        // the defect above and was found the same way.
        let list = try #require(
            manifest.range(
                of: #"dependencies: \[[^\]]*\]"#, options: .regularExpression,
                range: daemon.upperBound..<nextTarget),
            "the AeolusHelper target in Package.swift declares no dependency list")
        let manifestDependencies = String(manifest[list])

        // Comments first, because everything below reads a whole region rather than one list.
        // A `#` is `\S`, and this file puts its target-level comments at exactly four spaces —
        // which is how one comment line below `dependencies:` collapsed the old region to
        // nothing and let the entry underneath it through.
        let project = Self.strippingWholeLineComments(
            try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8))
        let daemonKey = try #require(
            project.range(of: "\n  AeolusHelper:\n"),
            "project.yml no longer declares an AeolusHelper target")
        // Terminated by the next target key **or by the next top-level key**: `AeolusHelper` is
        // the last target in the file, so a two-space-only terminator runs the region on into
        // `schemes:` and everything after it.
        let nextKey =
            project.range(
                of: #"(?m)^(?:\S|  [A-Za-z])"#, options: .regularExpression,
                range: daemonKey.upperBound..<project.endIndex)?.lowerBound ?? project.endIndex
        let daemonRegion = String(project[daemonKey.upperBound..<nextKey])

        // Both sub-keys, because either one links the client. `dependencies:` is the declared
        // route; `sources:` is the one that compiles the client's files into the daemon directly,
        // and it is the shorter path for someone who only wants to "include" a file.
        for key in ["sources", "dependencies"] {
            _ = try #require(
                daemonRegion.range(of: "(?m)^    \(key):$", options: .regularExpression),
                "the AeolusHelper target in project.yml declares no \(key)")
        }

        #expect(
            !manifestDependencies.contains(Self.target),
            """
            Package.swift links \(Self.target) into the root daemon. Everything in this target \
            then runs as root, including a connection actor whose entire design assumes it does \
            not — and `CLAUDE.md`'s helper row is that the daemon is the only writer, not that \
            it is also a client.
            """)
        #expect(
            !daemonRegion.contains(Self.target),
            """
            project.yml links \(Self.target) into the root daemon, through its `dependencies:` \
            or its `sources:`. That is the graph the shipping helper is built from, and it is \
            the one CI never builds.
            """)

        // The floor. Both halves above assert an **absence** inside a region they sliced, and a
        // region that shrank to nothing satisfies any absence: that is exactly how the first
        // version of the `Package.swift` half and the first version of the `project.yml` half
        // each passed while the daemon really did link the client. What the daemon does link is
        // therefore asserted too, so a slice that lost its content fails instead of passing.
        for product in Self.daemonDependencyFloor {
            #expect(
                manifestDependencies.contains("\"\(product)\""),
                """
                the dependency list this test sliced out of Package.swift does not name \
                \(product), which the root daemon links. The slice is wrong, and an absence \
                asserted over the wrong text is a test that cannot fail.
                """)
            #expect(
                daemonRegion.range(
                    of: "(?m)^\\s*product: \(product)$", options: .regularExpression) != nil,
                """
                the AeolusHelper region this test sliced out of project.yml does not name \
                \(product), which the root daemon links. The slice is wrong, and an absence \
                asserted over the wrong text is a test that cannot fail.
                """)
        }
    }

    /// The products the root daemon links, for the floor above. Three, and none of them is the
    /// client.
    private static let daemonDependencyFloor = ["SMCCore", "FanKit", "AeolusXPC"]

    /// YAML with every whole-line comment removed, lines preserved so the anchored patterns above
    /// still line up.
    ///
    /// Whole-line only, rather than `#`-to-end-of-line: a `#` inside a quoted value is not a
    /// comment, and this is not a YAML parser. The mutation that made it necessary was a
    /// whole-line comment, and this file's own style has no trailing ones.
    private static func strippingWholeLineComments(_ yaml: String) -> String {
        yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? "" : String($0) }
            .joined(separator: "\n")
    }
}
