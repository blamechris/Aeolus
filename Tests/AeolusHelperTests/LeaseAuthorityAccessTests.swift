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
/// ## Why the modifiers are parsed rather than assumed absent
///
/// The first version of this suite classified a line by `hasPrefix("let ")` or
/// `hasPrefix("var ")` after trimming, which meant every declaration carrying an explicit
/// modifier — `internal var`, `package var`, `static var`, and worst of all
/// `private(set) var` — was skipped rather than checked. The widening the exhaustive half
/// exists to catch could therefore be written in a spelling it could not see, and
/// `private(set) var table` is the exact worst case: an internal *getter* on the state this
/// suite exists to keep unreadable. `member(in:keyword:)` strips the modifier run instead,
/// and treats `private(set)` as internal because that is what its getter is.
///
/// A method is scanned for the same reason a property is. `WriteVerbAllowlistTests` filters
/// its population on `isAsync || mentions(anyOf: permits)`, and an actor's *synchronous*
/// isolated method is `async` only at the call site — that suite records the blind spot in
/// its own doc comment — so `func forceRelease(fanAt: Int) { table.remove(...) }` added here
/// would be reachable from every file in `AeolusHelper` and caught by nothing else.
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

    private enum MemberKeyword {
        case property
        case method
    }

    private struct Member {
        let name: String
        let isPrivate: Bool
    }

    /// The modifiers that may precede `let`/`var`/`func` without changing what is declared.
    ///
    /// `private` and `fileprivate` are handled separately because they are the answer, not
    /// noise. A modifier written with a parenthesised argument — `private(set)`,
    /// `nonisolated(unsafe)` — is matched on the part before the parenthesis, and
    /// `private(set)` deliberately does **not** count as private: it restricts the setter and
    /// leaves an internal getter on whatever it guards.
    private static let ignorableModifiers: Set<String> = [
        "internal", "package", "public", "open", "static", "class", "final", "lazy", "weak",
        "unowned", "override", "mutating", "nonmutating", "dynamic", "distributed",
        "nonisolated", "isolated", "borrowing", "consuming", "indirect", "required",
        "convenience", "optional",
    ]

    /// Every member of the requested kind declared at the actor's own member indent, across
    /// both files it is written in.
    ///
    /// Four spaces is that indent. Neither file declares a nested type, so nothing else in
    /// either sits at that depth; a `let` inside a method body is indented further and is a
    /// local, not a member. Computed properties are counted alongside stored ones
    /// deliberately — `fansAeolusIsAccountableFor` is computed, and it is the widening most
    /// worth watching.
    private static func members(keyword: MemberKeyword) throws -> [Member] {
        var found: [Member] = []
        for file in Self.authorityFiles {
            let code = try Self.strippedSource(of: file)
            for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let member = Self.member(in: line, keyword: keyword) else { continue }
                found.append(member)
            }
        }
        return found
    }

    /// One line, classified — or `nil` when it declares nothing of the requested kind.
    private static func member(in line: Substring, keyword: MemberKeyword) -> Member? {
        guard line.hasPrefix("    "), !line.hasPrefix("     ") else { return nil }
        var tokens = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        var isPrivate = false

        while let token = tokens.first {
            let head = String(token.prefix { $0 != "(" })
            if token.hasPrefix("@") {
                tokens.removeFirst()
            } else if head == "private" || head == "fileprivate" {
                // `private(set)` leaves the getter internal, so only the bare form answers.
                if head.count == token.count { isPrivate = true }
                tokens.removeFirst()
            } else if Self.ignorableModifiers.contains(head) {
                tokens.removeFirst()
            } else {
                break
            }
        }

        let introducers: Set<String> = keyword == .property ? ["let", "var"] : ["func"]
        guard tokens.count > 1, introducers.contains(String(tokens[0])) else { return nil }

        let name = tokens[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !name.isEmpty else { return nil }
        return Member(name: String(name), isPrivate: isPrivate)
    }

    private static func strippedSource(of file: String) throws -> String {
        let url = try #require(
            SeamScanner.swiftFiles().first { $0.lastPathComponent == file },
            "\(file) is not in the source tree")
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }
}
