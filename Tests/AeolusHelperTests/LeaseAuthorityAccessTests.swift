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
/// `theRegistryStaysPrivate` fails when a listed member loses its `private`, **and** when it
/// is no longer declared at all. A guard naming a member that has been renamed away asserts
/// nothing while still reading like protection.
///
/// `onlyTheAcknowledgedPropertiesAreInternal` and `onlyTheAcknowledgedMethodsAreInternal` are
/// the halves that catch the widening nobody listed. They scan every property and every
/// method declared at the actor's own member indent — across **both** files the actor is
/// written in — and require the internal ones to be exactly the acknowledged sets, so a new
/// one is a failure a maintainer has to answer for here, in the file that says why the
/// existing ones were acceptable.
///
/// ## Where the parse lives
///
/// In `MemberAccessScan`, shared with `HelperConnectionSessionAccessTests` since
/// [#98](https://github.com/blamechris/Aeolus/issues/98) split
/// `HelperConnectionSession.swift` the same way and needed the same guard. It records why
/// the modifier run is parsed rather than assumed absent — `private(set) var table` is the
/// spelling that motivated it — and why a method is scanned as well as a property:
/// `WriteVerbAllowlistTests` filters its population on `isAsync || mentions(anyOf: permits)`,
/// so `func forceRelease(fanAt: Int) { table.remove(...) }` added here would be reachable
/// from every file in `AeolusHelper` and caught by nothing else.
@Suite("The lease core's registry stays private to LeaseAuthority.swift")
struct LeaseAuthorityAccessTests {

    private static let authorityFile = "LeaseAuthority.swift"

    /// Both files `LeaseAuthority`'s members are written in.
    ///
    /// The extension's members sit at the same indent and are members of the same actor, so
    /// scanning only the main file would let the next split widen a member simply by putting
    /// it in the second one — which is the move that made this suite necessary.
    private static let authorityFiles = [
        "LeaseAuthority.swift",
        "LeaseAuthorityRefusals.swift",
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
        "var restoreAbandoned: Set<Int> = []",
        "var sleepSeal = false",
        "static let invalidatedInFlight",
        "func restore(_ fans: Set<Int>, because cause: FanRestoreCause) async {",
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
    private static let acknowledgedInternalProperties: Set<String> = [
        "writeCapability",
        "telemetry",
        "foreignControl",
        "log",
        "fansAeolusIsAccountableFor",
        "leaseCount",
        "tombstoneCount",
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
    private static let acknowledgedInternalMethods: Set<String> = [
        "refuseIfWritePathNotBuilt",
        "refuseIfBlind",
        "refuseIfForeignManualControl",
        "acquireLease",
        "renewLease",
        "releaseLease",
        "heldLease",
        "expireLapsedLeases",
        "nextExpiryDeadline",
        "connectionDidInvalidate",
        "revokeLeases",
        "revokeEveryLease",
        "releaseEveryLease",
        "sealForSleep",
        "unsealAfterWake",
        "abandonOutstandingHandbacks",
        "activeLease",
        "activeLeaseView",
        "holdsTombstone",
    ]

    @Test("Every member that decides who may hold or release a fan is still private")
    func theRegistryStaysPrivate() throws {
        let code = try Self.strippedSource(of: Self.authorityFile)

        for member in Self.mustStayPrivate {
            let line =
                code
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first { $0.contains(member) }
            let declaration = try #require(
                line,
                """
                \(member) is no longer declared in \(Self.authorityFile). This guard names \
                the members whose privacy is load-bearing; one that has been renamed or \
                removed has to be re-stated here, or the entry is protecting nothing.
                """
            )
            #expect(
                declaration.trimmingCharacters(in: .whitespaces).hasPrefix("private "),
                """
                `\(declaration.trimmingCharacters(in: .whitespaces))` is no longer private. \
                An internal member of the lease core is reachable from every file in \
                AeolusHelper — see LeaseAuthorityRefusals.swift for the ones that were \
                widened on purpose and why this one is not among them.
                """
            )
        }
    }

    @Test("Only the acknowledged properties of the lease core are internal")
    func onlyTheAcknowledgedPropertiesAreInternal() throws {
        let internalProperties = Set(
            try Self.members(keyword: .property).filter { !$0.isPrivate }.map(\.name))

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
            try Self.members(keyword: .method).filter { !$0.isPrivate }.map(\.name))

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

    // MARK: - The member parse

    /// Every member of the requested kind declared at the actor's own member indent, across
    /// both files it is written in.
    ///
    /// The parse itself is `MemberAccessScan`, shared with
    /// `HelperConnectionSessionAccessTests` since #98 rather than copied into it. Neither
    /// file here declares a nested type, so nothing but a member of the actor sits at that
    /// depth — which is the precondition that scan states and its callers have to keep.
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
