import Foundation
import Testing

/// The half of the client's structural claims that is about **what it may not keep**, split
/// from `HelperClientSeamTests` along that seam.
///
/// Split because the file crossed SwiftLint's 1000-line error threshold, but the seam is a real
/// one and is the same one `SeamScannerScopes` was split along: everything here asks what the
/// client *stores*, and answers it from a declaration's scope and the DTOs the helper answers
/// with. Everything left there asks what the client *does* — a second caller, a retry, a
/// connection built elsewhere, a build graph — and answers it from call shape and from two
/// build files.
///
/// `CLAUDE.md`'s row for this target is "holds no fan state … never re-acquires a lease", and
/// #237's body called that structural. It was not: it was the current absence of a stored
/// property, and a fifth one compiles beside the four that are there.
@Suite("What the XPC client may not keep")
struct HelperClientStateSeamTests {

    private static let target = HelperClientSources.target

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
        let declared =
            declaration
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
}
