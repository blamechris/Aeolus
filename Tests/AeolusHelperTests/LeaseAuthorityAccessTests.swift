import Foundation
import Testing

/// The access levels [#128](https://github.com/blamechris/Aeolus/issues/128) left behind,
/// asserted rather than described.
///
/// ## Why this suite exists
///
/// #128 split three refusals out of `LeaseAuthority.swift` into
/// `LeaseAuthorityRefusals.swift`, and a Swift extension in another file cannot see a
/// `private` member — so five of the actor's properties had to go `internal` for the move to
/// compile. That is the trade #128's own comments declined twice, for
/// `SMCReadScheduler` and `ReclamationWatchdog`: *"the split would trade a line count for
/// widened access on the one type whose entire subject is who may touch the connection"*.
///
/// It was taken here only for members that decide nothing — a get-only capability report, a
/// read verb, a foreign-control query, and a log — and refused for every member that decides
/// **who may hold a fan, who may have one handed back, or whether § 3's latch is engaged**.
/// That distinction was a paragraph in a file header until this suite, and a paragraph is not
/// enforcement: the next split has no way to notice it is widening `table` rather than `log`.
///
/// ## Both directions, for the reason `WriteVerbAllowlistTests` gives
///
/// `theRegistryStaysPrivate` fails when a listed member loses its `private`, when it is no
/// longer declared at all, **and** when a second line of the file matches the same spelling. A
/// guard naming a member that has been renamed away asserts nothing while still reading like
/// protection, and one with two lines to choose from was silently judging the first of them —
/// see `MemberAccessScan.declaration(of:in:from:)` for what that cost on the sibling suite.
///
/// `onlyTheAcknowledgedPropertiesAreInternal` and `onlyTheAcknowledgedMethodsAreInternal` are
/// the halves that catch the widening nobody listed. They scan every property and every
/// method declared at the actor's own member indent — across **every** file the actor is
/// written in — and require the internal ones to be exactly the acknowledged sets, so a new
/// one is a failure a maintainer has to answer for here, in the file that says why the
/// existing ones were acceptable.
///
/// That the files below are every file is itself asserted, by
/// `theScannedFilesAreEveryFileTheActorIsIn`. The list was hand-written until
/// [#236](https://github.com/blamechris/Aeolus/issues/236), which is the same gap #236
/// reproduced on `HelperConnectionSessionAccessTests`: a *third* file declaring
/// `extension LeaseAuthority` was scanned by nothing, so a synchronous internal method written
/// there — with `table`, `tombstones` and `restore(_:because:)` all in scope — widened the
/// lease core while every assertion here passed.
///
/// ## Where the parse lives
///
/// In `MemberAccessScan`, shared with `HelperConnectionSessionAccessTests` since
/// [#98](https://github.com/blamechris/Aeolus/issues/98) split
/// `HelperConnectionSession.swift` the same way and needed the same guard. It records why
/// the modifier run is parsed rather than assumed absent — `private(set) var table` is the
/// spelling that motivated it — why an attribute is skipped by its parentheses rather than by
/// its whitespace, why a method's key carries its signature, and why a method is scanned as
/// well as a property:
/// `WriteVerbAllowlistTests` filters its population on `isAsync || mentions(anyOf: permits)`,
/// so `func forceRelease(fanAt: Int) { table.remove(...) }` added here would be reachable
/// from every file in `AeolusHelper` and caught by nothing else.
@Suite("The lease core's registry stays private to LeaseAuthority.swift")
struct LeaseAuthorityAccessTests {

    private static let authorityFile = "LeaseAuthority.swift"

    /// The type whose members these guards are about, and the target it is written in.
    private static let authorityType = "LeaseAuthority"
    private static let helperTarget = "AeolusHelper"

    /// Every file `LeaseAuthority`'s members are written in, **sorted**, and checked against
    /// the tree by `theScannedFilesAreEveryFileTheActorIsIn` rather than trusted.
    ///
    /// The extension's members sit at the same indent and are members of the same actor, so
    /// scanning only the main file would let the next split widen a member simply by putting
    /// it in the second one — which is the move that made this suite necessary. Adding a file
    /// is a decision about what it may widen, so it is written here rather than derived
    /// silently at the point of use.
    /// #128's lease-core pass added two, each declaring a value type inside `extension
    /// LeaseAuthority` and no member of the actor: `LeaseAuthorityRegistersAccessTests` holds them.
    private static let authorityFiles = [
        "LeaseAuthority.swift",
        "LeaseAuthorityHandbackRegisters.swift",
        "LeaseAuthorityRefusals.swift",
        "LeaseAuthoritySleepSealPairing.swift",
    ]

    /// Every member of `LeaseAuthority` whose privacy is load-bearing, spelled as declared.
    ///
    /// The five collaborators that were **not** widened are here for a reason each:
    /// `restorer` is the keystone's own seam, `enumeration` says which fans exist,
    /// `thermalEmergency` is a concrete actor with mutators rather than a query role, and the
    /// two clocks are what `expireLapsedLeases` judges a lapse against — ADR 0005's monotonic
    /// rule is only inexpressible from outside while the clock cannot be reached.
    private static let mustStayPrivate = [
        "let clock: any MonotonicClock",
        "let wallClock: @Sendable () -> Date",
        "let enumeration: any FanEnumerating",
        "let restorer: any FanRestoring",
        "let thermalEmergency: ThermalEmergencyLatch",
        "var table = LeaseTable()",
        "var tombstones: ConnectionTombstones",
        "var releasing: [Int: Int] = [:]",
        // #368's waiters. A reference to one is a continuation anybody could resume, ending a
        // `.gone` revocation before the handback it outwaits — the wait gone, with no error.
        "var handbackWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]",
        "var restoreAbandoned: Set<Int> = []",
        "var handbackUnconfirmed: Set<Int> = []",
        "var sleepSeal = false",
        // The two halves of § 4's episode pairing. Listed beside `sleepSeal` because they can
        // *cancel* it: a `sealForSleep(generation:)` whose generation is not newer than
        // `latestWakeGeneration` declines, so anything able to write these could hold the
        // table open across a sleep without ever touching `sleepSeal` itself (#202 item 1).
        "var latestWakeGeneration: UInt64 = 0",
        "var sealGeneration: UInt64 = 0",
        // The machine-wide restore seal (#350, #364). Writable from elsewhere, it could reopen
        // the gate under a panic verb or a sleep handback still restoring, or close it for the
        // life of the process.
        "var machineWideRestoresInFlight = 0",
        "static let invalidatedInFlight",
        "func restore(_ fans: Set<Int>, because cause: FanRestoreCause) async {",
        "func outwaitHandback(of fan: Int) async {",
        "func refuseIfInvalidated(_ connection: ConnectionID) throws {",
        "func refuseIfThermalEmergencyActive(_ connection: ConnectionID) async throws {",
    ]

    /// Every property of `LeaseAuthority` that is not `private`, and why each is allowed
    /// to be.
    ///
    /// The first five are #128's, widened so that `LeaseAuthorityRefusals.swift` could reach
    /// them. Four are references to stateless query roles or to the log; the fifth,
    /// `fansAeolusIsAccountableFor`, is derived and read-only, and `activeLeaseView()` —
    /// internal, and what the control plane calls — already returns exactly that set, so
    /// widening it exposed nothing that was not already on the seam.
    ///
    /// `leaseCount` and `tombstoneCount` pre-date #128 and are the counts the control plane
    /// and the lease suite read. They are listed because this assertion is exhaustive in both
    /// directions: an entry a maintainer did not have to write down is a widening this suite
    /// would not have caught.
    ///
    /// `fansWithUnconfirmedHandbacks` and `fansWithAbandonedHandbacks` are #209's, and they
    /// are the same trade `fansAeolusIsAccountableFor` was allowed on: **derived, read-only
    /// views of state that stays private**. Nothing reached through them can put a fan into
    /// either register or take one out — `recordUnconfirmedHandbacks()` and
    /// `restore(_:because:)` are the only writers, and the second of those is still private.
    /// They exist because decision D33 gave a handback three distinguishable endings —
    /// cleared, converted to the durable set, still standing — and the refusal alone cannot
    /// tell "cleared" from "never recorded", so a test asserting only the thrown fault would
    /// pass against a helper that recorded nothing at all. `fansMidHandback` is the third of
    /// the same kind — `releasing`'s keys — and exists so the subset invariant the first two
    /// rest on is asserted by a test rather than stated by a comment. `fansARevocationAwaits` is
    /// the fourth (#368): `handbackWaiters`' keys and none of its continuations, so a test can
    /// wait for a parked revocation as a state rather than counting yields.
    ///
    /// `emergencyRestores` is #303's: § 3's `EmergencyRestoreConfirming` role, readable from
    /// `LeaseAuthorityRefusals.swift` for the same reason `foreignControl` is, and `private(set)`
    /// so only `bind(emergencyRestores:)` can change it. It is a role, not § 3's actor, so
    /// reading it reaches one read-only question and none of § 3's mutators.
    ///
    /// `envelopes` is #270's: `FanEnvelopeReading`, one read verb, readable from
    /// `LeaseAuthorityRefusals.swift` for `foreignControl`'s reason. It is a role, not the plane:
    /// what it answers is a `FanEnvelope`, and turning one into a permit is a step the lease
    /// core's files are held to never naming, by `theLeaseCoreMintsNoPermit` below.
    private static let acknowledgedInternalProperties: Set<String> = [
        "writeCapability",
        "telemetry",
        "foreignControl",
        "envelopes",
        "log",
        "fansAeolusIsAccountableFor",
        "leaseCount",
        "tombstoneCount",
        "fansWithUnconfirmedHandbacks",
        "fansWithAbandonedHandbacks",
        "fansMidHandback",
        "fansARevocationAwaits",
        "emergencyRestores",
    ]

    /// Every method of `LeaseAuthority` that is not `private`, and what each of them is.
    ///
    /// The first three are #128's — the refusals that moved to `LeaseAuthorityRefusals.swift`
    /// and are `internal` only because a Swift extension in another file cannot see a
    /// `private` member. Calling one of them from elsewhere in the module can produce a
    /// refusal and nothing else.
    ///
    /// The rest pre-date #128 and are the lease core's actual seam: what the XPC service, the
    /// control plane, the reclamation watchdog and the sleep supervisor call. They are listed
    /// for the same reason the pre-existing properties are — an entry nobody had to write
    /// down is a widening this suite would not have caught. A **new** name appearing here is
    /// the thing to argue about: `table` and `restore(_:because:)` are private, and a new
    /// internal method is the shortest route to reaching them from outside this actor.
    ///
    /// **Spelled as signatures, not names**, since #236. A bare-name key cannot tell a second
    /// method that reuses an acknowledged name from the one that was acknowledged, and the
    /// shortest route it leaves open here is the worst: `releaseEveryLease()` is on this list,
    /// so `releaseEveryLease(sparing: Set<Int>)` would have been too, for free.
    ///
    /// `bind(emergencyRestores:)` is #303's, and the one writer of `emergencyRestores`. The worst
    /// a caller elsewhere in the module can do with it is bind a role that answers the wrong set,
    /// and that changes **which** refusal a manual fan is given, never **whether** it is refused:
    /// both consumers consult the set only after a fresh read has already found the fan manual,
    /// and never as an exemption. It touches no register and no fan.
    private static let acknowledgedInternalMethods: Set<String> = [
        "refuseIfWritePathNotBuilt(_: ConnectionID)",
        "refuseIfBlind(_: ConnectionID)",
        "refuseIfForeignManualControl(_: ConnectionID, wanting: Set<Int>)",
        // #311's. Synchronous, in the straight-line region, and like the three above it can
        // produce a refusal and nothing else: it reads `fansAeolusIsAccountableFor`, which is
        // already acknowledged below, and no register that set is derived from.
        "refuseIfExemptionLapsed(_: ConnectionID, exempted: Set<Int>)",
        // #270's, § 2's bounds gate, above the marker. Like the three above it, it can produce a
        // refusal and nothing else: it reads `envelopes`, judges what it reads and drops it, and
        // touches no register.
        "refuseIfBoundsImplausible(_: ConnectionID, wanting: Set<Int>)",
        "acquireLease(_: LeaseRequest, from: ConnectionID)",
        "renewLease(id: UUID, from: ConnectionID)",
        "releaseLease(id: UUID, from: ConnectionID)",
        "heldLease(id: UUID, from: ConnectionID)",
        "expireLapsedLeases()",
        "nextExpiryDeadline()",
        // #180's, and ADR 0009 D2's question for § 5 and the engagement driver, about one
        // lease since #357. Synchronous and read-only: it reads `table` and `clock` and writes
        // neither, sweeps nothing, and answers one boolean about one lease and one fan — so a
        // caller holding a lease's ID can learn whether it is live, which `heldLease(id:from:)`
        // already answers its holder, and cannot change who holds it.
        "hasLiveLease(id: UUID, coveringFan: Int)",
        "connectionDidInvalidate(_: ConnectionID)",
        "revokeLeases(coveringFan: Int, because: FanRestoreCause)",
        // #353's, § 5's terminal revocation. Strictly narrower than `revokeEveryLease` below,
        // which is already internal: one named lease, whole — revoked if live, ended as expired
        // if lapsed (#361's panel). The fan only chooses which handback a `.gone` outwaits
        // (#368): a caller can park itself, and it resumes nothing and restores nothing.
        "revokeLease(id: UUID, forFan: Int, because: FanRestoreCause)",
        "revokeEveryLease(because: FanRestoreCause)",
        "releaseEveryLease()",
        "confirmAcceptedHandbacks()",
        "sealForSleep(generation: UInt64)",
        "unsealAfterWake(generation: UInt64)",
        "recordUnconfirmedHandbacks()",
        "activeLease()",
        "activeLeaseView()",
        // #350's. It runs a caller's closure with the grant gate sealed, and it can only seal:
        // the count is private, the increment and decrement are paired in its own frame, and
        // nothing it is handed can reach `table` or `restore(_:because:)` except through the
        // internal methods already listed here. A caller elsewhere in the module can refuse
        // grants for as long as its closure runs — the safe direction — and nothing more.
        "sealingGrants(during: @Sendable () async -> Outcome)",
        "holdsTombstone(for: ConnectionID)",
        "bind(emergencyRestores: some EmergencyRestoreConfirming)",
    ]

    /// The file set is a claim about the tree, so it is read off the tree — see
    /// `HelperConnectionSessionAccessTests`, where #236's mutation was reproduced, for the
    /// shape of the hole this closes. `authorityFile` is checked the same way, because
    /// `theRegistryStaysPrivate` opens that one file and asserts nothing about any other.
    @Test("Every file the lease core is written in is one this suite scans")
    func theScannedFilesAreEveryFileTheActorIsIn() throws {
        let sites = try MemberAccessScan.filesDeclaring(
            Self.authorityType, inTarget: Self.helperTarget)

        #expect(
            sites.members == Self.authorityFiles.sorted(),
            """
            the files \(Self.authorityType) is written in changed: the tree declares it in \
            \(sites.members), this suite scans \(Self.authorityFiles.sorted()). A file this \
            suite does not scan can widen any member of the lease core — and inside one \
            `table`, `tombstones` and `restore(_:because:)` are all in scope — while every \
            assertion here stays green. Add it to `authorityFiles` and say what it is allowed \
            to widen.
            """
        )
        #expect(
            sites.declarations == [Self.authorityFile],
            """
            \(Self.authorityType)'s own declaration is in \(sites.declarations), and \
            `authorityFile` names \(Self.authorityFile). That name is what \
            `theRegistryStaysPrivate` opens, so a declaration that has moved leaves it \
            asserting about a file the registry no longer lives in.
            """
        )
    }

    @Test("Every member that decides who may hold or release a fan is still private")
    func theRegistryStaysPrivate() throws {
        let code = try Self.strippedSource(of: Self.authorityFile)

        for member in Self.mustStayPrivate {
            let declaration = try MemberAccessScan.declaration(
                of: member, in: code, from: Self.authorityFile)
            #expect(
                declaration.hasPrefix("private "),
                """
                `\(declaration)` is no longer private. An internal member of the lease core \
                is reachable from every file in AeolusHelper — see \
                LeaseAuthorityRefusals.swift for the ones that were widened on purpose and \
                why this one is not among them.
                """
            )
        }
    }

    @Test("Only the acknowledged properties of the lease core are internal")
    func onlyTheAcknowledgedPropertiesAreInternal() throws {
        let internalProperties = Set(
            try Self.members(keyword: .property).filter { !$0.isPrivate }.map(\.key))

        #expect(
            internalProperties == Self.acknowledgedInternalProperties,
            """
            the internal properties of LeaseAuthority changed: found \
            \(internalProperties.sorted()), acknowledged \
            \(Self.acknowledgedInternalProperties.sorted()). Widening one is a decision \
            about what the rest of AeolusHelper may read out of the lease core — say why \
            here, in the suite that records why the acknowledged ones were acceptable.
            """
        )
    }

    @Test("Only the acknowledged methods of the lease core are internal")
    func onlyTheAcknowledgedMethodsAreInternal() throws {
        let internalMethods = Set(
            try Self.members(keyword: .method).filter { !$0.isPrivate }.map(\.key))

        #expect(
            internalMethods == Self.acknowledgedInternalMethods,
            """
            the internal methods of LeaseAuthority changed: found \
            \(internalMethods.sorted()), acknowledged \
            \(Self.acknowledgedInternalMethods.sorted()). A method of this actor that is \
            not private is callable from every file in AeolusHelper, and inside it `table`, \
            `tombstones` and `restore(_:because:)` are all in scope — say why here.
            """
        )
    }

    /// The lease core's files name neither the permit nor the property that mints one
    /// ([#270](https://github.com/blamechris/Aeolus/issues/270)).
    ///
    /// `refuseIfBoundsImplausible(_:wanting:)` reads a `FanEnvelope`, and a `FanEnvelope` is one
    /// property away from the `CommandableFan` both write verbs take. The gate judges the bounds
    /// with `FanState.controlEnvelope(declaredMinimum:declaredMaximum:)` instead, which yields an
    /// envelope that carries no fan index and so authorises nothing, and this is what keeps it
    /// that way: a lease core that minted a permit would be one edit from writing.
    ///
    /// Every file named `LeaseAuthority*.swift` under `Sources/AeolusHelper`, and every file the
    /// actor is written in, comments stripped and string literals kept — an interpolation is
    /// code — matched case-insensitively, so the type name and the property name are one
    /// search. A helper elsewhere that mints the
    /// permit for it evades this; such a helper names `CommandableFan` and enters
    /// `WriteVerbAllowlistTests`' population, which is where it would have to be answered for.
    ///
    /// **Mutation:** in `refuseIfBoundsImplausible(_:wanting:)`, judge with
    /// `declared.commandable.map(\.envelope)` in place of `FanState.controlEnvelope(…)`. Run:
    /// red here, while every behavioural test stays green.
    @Test("The lease core's files name no permit and nothing that mints one")
    func theLeaseCoreMintsNoPermit() throws {
        let named = try SeamScanner.swiftFiles(under: Self.helperTarget)
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix(Self.authorityType) && $0.hasSuffix(".swift") }
        let files = Set(named).union(Self.authorityFiles).sorted()
        #expect(
            files == Self.authorityFiles.sorted(),
            "the scan covers \(files), so a LeaseAuthority file this suite does not know exists")

        var offences: [String] = []
        for file in files {
            let code = SeamScanner.strippingAllComments(
                try MemberAccessScan.strippedSource(of: file))
            if code.range(of: "commandable", options: .caseInsensitive) != nil {
                offences.append(file)
            }
        }
        #expect(
            offences.isEmpty,
            """
            \(offences) name CommandableFan or `commandable`. The lease core judges bounds and \
            grants leases; minting the permit a write verb takes is `apply`'s and § 5's, and a \
            lease core holding one is one edit from writing (docs/SAFETY.md § 2).
            """)
    }

    // MARK: - The member parse

    /// Every member of the requested kind declared at the actor's own member indent, across
    /// every file it is written in.
    ///
    /// The parse itself is `MemberAccessScan`, shared with
    /// `HelperConnectionSessionAccessTests` since #98 rather than copied into it. Two files
    /// here declare nested types, whose members sit eight spaces in, so nothing but a member of
    /// the actor sits at that depth — the precondition that scan states and its callers keep.
    /// Computed properties are counted alongside stored ones deliberately —
    /// `fansAeolusIsAccountableFor` is computed, and it is the widening most worth watching.
    private static func members(
        keyword: MemberAccessScan.Keyword
    ) throws -> [MemberAccessScan.Member] {
        try MemberAccessScan.members(in: Self.authorityFiles, keyword: keyword)
    }

    private static func strippedSource(of file: String) throws -> String {
        try MemberAccessScan.strippedSource(of: file)
    }

}
