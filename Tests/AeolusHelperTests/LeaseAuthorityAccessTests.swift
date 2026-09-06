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
/// `onlyTheAcknowledgedPropertiesAreInternal` is the half that catches the widening nobody
/// listed. It scans every property declared at the actor's own member indent and requires the
/// internal ones to be exactly the acknowledged set — so a new one is a failure a maintainer
/// has to answer for here, in the file that says why the existing ones were acceptable.
@Suite("The lease core's registry stays private to LeaseAuthority.swift")
struct LeaseAuthorityAccessTests {

    private static let authorityFile = "LeaseAuthority.swift"

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
        let code = try Self.strippedSource(of: Self.authorityFile)

        // Four spaces is the actor's own member indent. `LeaseAuthority.swift` declares no
        // nested type, so nothing else in the file sits at that depth; a `let` inside a
        // method body is indented further and is a local, not a member. Computed properties
        // are counted alongside stored ones deliberately — `fansAeolusIsAccountableFor` is
        // computed, and it is the widening most worth watching.
        var internalProperties: Set<String> = []
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("    ") && !line.hasPrefix("     ") else { continue }
            let declaration = line.trimmingCharacters(in: .whitespaces)
            guard declaration.hasPrefix("let ") || declaration.hasPrefix("var ") else {
                continue
            }
            let name =
                declaration
                .dropFirst(4)
                .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            internalProperties.insert(String(name))
        }

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

    private static func strippedSource(of file: String) throws -> String {
        let url = try #require(
            SeamScanner.swiftFiles().first { $0.lastPathComponent == file },
            "\(file) is not in the source tree")
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }
}
