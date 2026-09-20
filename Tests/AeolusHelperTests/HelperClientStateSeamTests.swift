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
    /// cannot see it. The five routes worth having were closed — the type position, the
    /// initialiser (`private let cached = SystemSnapshot(…)`, which `Property.names` reads), a
    /// **multi-line** initialiser whose type is named only below its first line, a **typealias**
    /// standing in for a listed type, and the wire form (`private var lastSnapshotPayload: Data?`,
    /// which `Data`'s move off `scalars` and onto `fanStateTypes` now catches) — and a scalar
    /// field copied out one at a time is not reachable from any list of type names. What would
    /// catch that is a review of a declaration whose name says what it remembers, which is a
    /// reader's job.
    ///
    /// The alias route is resolved rather than stated, because a type name is the only thing
    /// either list can compare against and an alias is the one construct that renames a type
    /// without wrapping it. `private typealias Remembered = SystemSnapshot` with `private var
    /// last: Remembered?` beneath it was **green** on a scratch type in
    /// `Sources/AeolusXPCClient`, and so was the lease half beside it. The resolution is
    /// transitive and reads every alias under `Sources`, so an alias declared in `FanKit` for a
    /// client to use is closed too; one declared outside `Sources` is the stated limit, and
    /// `SeamScanner.typeAliases(in:)` records it.
    ///
    /// The third of those was the one that mattered, because the formatter chose it. `= { … }()`
    /// broken across lines was read as the single character `{`, so the closure below contributed
    /// nothing and the stored snapshot was invisible — while the one-line form this test *did*
    /// catch is the form `.swift-format`'s 100-column limit reflows. A guard that fires only on a
    /// spelling nobody can commit is evaded by the house style rather than by an author. See
    /// `SeamScanner.fragment(in:from:stoppingAt:)` and the two fixtures in
    /// `SeamScannerScopeParsingTests` that pin it.
    ///
    /// **Mutation:** add `private var lastSnapshot: SystemSnapshot?` to `HelperClient`. Run:
    /// red, naming the declaration. **Mutation:** add `private let cached = SystemSnapshot(…)`,
    /// whose type is written nowhere — red too, because `Property.names` reads the initialiser
    /// as well as the type position. **Mutation:** add `private var lastSnapshot = {` with `let
    /// remembered: SystemSnapshot? = nil` on the line below — red, which it was **not** before
    /// the initialiser was read past its first line. **Mutation:** add `private var
    /// lastSnapshotPayload: Data?` — red, which it was not while `Data` sat on `scalars`.
    /// **Mutation:** add `private typealias Remembered = SystemSnapshot` and `private var last:
    /// Remembered?` — red on the alias resolution, which is the only half that sees it.
    @Test("The client stores no fan state")
    func theClientStoresNoFanState() throws {
        let stored = try SeamScanner.properties(in: Self.target).filter(\.isStored)
        let aliases = try Self.aliases()
        #expect(
            stored.count >= Self.storedPropertyFloor,
            """
            Sources/\(Self.target) declares \(stored.count) stored properties and this scan \
            expects at least \(Self.storedPropertyFloor). A population that shrank is a scan \
            that stopped reading declarations it used to read, and every claim below is an \
            absence asserted over it — so the smaller it gets the more of them are vacuous. \
            Lower the floor deliberately if a property really went away.
            """)

        let holding = stored.filter {
            !Self.resolving($0.names, through: aliases).isDisjoint(with: Self.fanStateTypes)
        }

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
    /// is the one the type half cannot cover. **Mutation:** add `private typealias Grant = Lease`
    /// and `private var held: Grant?` — red on the type half through the alias resolution, and
    /// green on the name half, since `held` splits to no `lease` word.
    @Test("The client stores no lease and no lease identifier")
    func theClientStoresNoLease() throws {
        let stored = try SeamScanner.properties(in: Self.target).filter(\.isStored)
        let aliases = try Self.aliases()
        #expect(
            stored.count >= Self.storedPropertyFloor,
            """
            Sources/\(Self.target) declares \(stored.count) stored properties and this scan \
            expects at least \(Self.storedPropertyFloor).
            """)

        let byType = stored.filter {
            !Self.resolving($0.names, through: aliases).isDisjoint(with: Self.leaseTypes)
        }
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

    /// How many stored properties `Sources/AeolusXPCClient` declares today, as a **floor**.
    ///
    /// `!stored.isEmpty` was the floor until this line, and it could not notice a population that
    /// shrank by ten: one surviving declaration satisfied it, while every claim in this file is an
    /// absence asserted over that population and an absence over one declaration is nearly
    /// vacuous. Both previous silent failures in this suite were shrinking populations — the
    /// send path losing `pinnedConnection`, and `structBody` reading a neighbour — so a count is
    /// what a floor here has to be. It is a floor and not an equality: a property added is fine
    /// and is scanned; a property removed is a deliberate edit to this number.
    ///
    /// Set to the population as it stands, not to a round number below it. Headroom is what makes
    /// a floor unable to see the shrink it was written for — eight of the target's declarations
    /// could leave the scan under a floor of 25 without a word, which is most of a file's worth.
    ///
    /// **Mutation:** raise this to `34`. Run: red on both floors, `(stored.count → 33) >= 34`,
    /// which is the boundary a shrink of one arrives at from the other side. That is the mutation
    /// actually run, and it is the constant rather than the tree for a reason worth stating: every
    /// stored property in this target is referenced, so deleting one does not compile and the
    /// population cannot be shrunk by an edit that builds. The count itself is read from the tree
    /// and not asserted anywhere else — a floor of `9999` reports `declares 33 stored properties`.
    private static let storedPropertyFloor = 33

    /// How many top-level public types the payload file declares today, as a floor.
    ///
    /// Three: `SystemSnapshot`, `SensorSample` and `LeaseRequest`. `!declared.isEmpty` would have
    /// been satisfied by one of them, and the assertion beneath it is that *every* declaration is
    /// listed — an assertion a pattern that matches fewer declarations passes more easily. The
    /// count is what makes a pattern that stopped matching fail instead.
    private static let payloadDTOFloor = 3

    /// Every `typealias` under `Sources`, as a map from the alias to what it names.
    ///
    /// `uniquingKeysWith` concatenates rather than picks, because two targets may each declare an
    /// alias of the same name and keeping only one of them would silently drop the other's
    /// right-hand side — which is the resolution failing open, quietly.
    private static func aliases() throws -> [String: [String]] {
        try Dictionary(
            SeamScanner.typeAliases(in: nil).map { ($0.name, $0.names) },
            uniquingKeysWith: { $0 + $1 })
    }

    /// `names`, with every alias replaced by what it names, transitively.
    ///
    /// The `insert(_:).inserted` check is what terminates on a cycle: `typealias A = B` beside
    /// `typealias B = A` does not compile, but an alias chain that passes through a generic
    /// specialisation can revisit a name, and a resolver that looped here would hang the suite
    /// rather than fail it.
    private static func resolving(
        _ names: [String], through aliases: [String: [String]]
    ) -> Set<String> {
        var resolved: Set<String> = []
        var pending = names
        while let name = pending.popLast() {
            guard resolved.insert(name).inserted else { continue }
            pending += aliases[name] ?? []
        }
        return resolved
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
    /// It descends through `SeamScanner.structBody(of:inSource:file:)`, which matches the struct's
    /// name **whole**. That is not a detail: the pattern was a prefix match answered by the first
    /// hit in the file, so a `FanStateReport` declared above `FanState` would hand this check a
    /// neighbour's fields, find them all accounted for, and stay green — auditing a type nobody
    /// asked about while the listed one went on being validated by nothing. This tree matched
    /// correctly by declaration order alone, and declaration order is not something a
    /// completeness check may rest on.
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
    /// Top-level declarations only, by the column-zero `public`: a nested one is a field type
    /// of its parent and is reached by `theFanStateListNamesEveryTypeTheseDTOsCarry` instead. A
    /// `public enum` carrying fan state in an associated value is the stated hole, and it is the
    /// same one `opaqueToTheParser` records — what catches it is the stored property of that
    /// enum's type.
    ///
    /// **An attribute in front of the declaration does not hide it.** The pattern anchored on
    /// `^public struct`, so `@available(macOS 14.0, *) public struct FanTargetReport` — one line,
    /// which `swift format lint --strict` accepts at exit 0, so the formatter does not break it
    /// onto two — was invisible to the one check whose whole job is to keep the two lists in step
    /// with that file. Verified by appending exactly that declaration to the payload file: this
    /// test stayed **green**. The leading group is therefore any run of attributes, and `class` is
    /// read beside `struct`, because an `NSXPC` payload does not have to be a value type and a
    /// listed-but-unread class fails loudly here rather than passing quietly.
    ///
    /// **Mutation:** add a `public struct FanTargetReport` to the payload file. Run: red, naming
    /// it. **Mutation:** put `@available(macOS 14.0, *)` in front of it on the same line. Run:
    /// red, which it was **not** while the pattern anchored on `^public struct`. **Mutation:**
    /// write it as `public final class FanTargetReport`. Run: red.
    @Test("Every DTO in the payload file is on a forbidden list")
    func everyPayloadDTOIsOnAForbiddenList() throws {
        let file = try #require(
            SeamScanner.swiftFiles().first { $0.lastPathComponent == Self.payloadFile },
            "\(Self.payloadFile) is not in the source tree")
        let code = SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8))
        let attributes = #"(?:@[A-Za-z_]\w*(?:\([^\n]*\))?\s+)*"#
        let declaration = try NSRegularExpression(
            pattern: #"(?m)^"# + attributes
                + #"public (?:final class|class|struct) ([A-Za-z_]\w*)"#)
        let declared =
            declaration
            .matches(in: code, range: NSRange(code.startIndex..<code.endIndex, in: code))
            .compactMap { Range($0.range(at: 1), in: code).map { String(code[$0]) } }

        #expect(
            declared.count >= Self.payloadDTOFloor,
            """
            \(Self.payloadFile) declares \(declared.count) top-level public types and this scan \
            expects at least \(Self.payloadDTOFloor). The check below asserts that each one is on \
            a forbidden list, so a pattern that stopped matching a declaration would satisfy it \
            by finding nothing — which is what an anchor on `^public struct` did for an attributed \
            one.
            """)

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
