import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The table itself, exercised directly. Everything here is also reachable through
/// `LeaseAuthority`; these pin the two selectors separately, because the whole reason they
/// are two functions is that the mechanisms above them must stay two mechanisms.
@Suite("The lease table")
struct LeaseTableTests {

    private func entry(
        connection: ConnectionID = ConnectionID(),
        fans: Set<Int> = [0],
        deadline: ContinuousClock.Instant
    ) -> LeaseRecord {
        LeaseRecord(
            id: UUID(),
            connection: connection,
            holderDescription: "test",
            fanIndices: fans,
            timeToLive: 30,
            deadline: deadline,
            expiresAt: Date(timeIntervalSince1970: 1_000_030)
        )
    }

    @Test("The earliest deadline is what the supervisor is told to wake for")
    func earliestDeadlineIsTheSoonest() {
        let start = ContinuousClock.now
        var table = LeaseTable()
        table.insert(entry(deadline: start.advanced(by: .seconds(90))))
        table.insert(entry(deadline: start.advanced(by: .seconds(30))))

        #expect(table.earliestDeadline == start.advanced(by: .seconds(30)))
    }

    @Test("An empty table has no deadline to wake for")
    func emptyTableHasNoDeadline() {
        #expect(LeaseTable().earliestDeadline == nil)
    }

    /// The TTL selector removes by deadline and knows nothing about connections.
    @Test("Removing lapsed leases takes exactly those past their deadline")
    func removesOnlyLapsedLeases() {
        let start = ContinuousClock.now
        var table = LeaseTable()
        let lapsed = entry(fans: [0], deadline: start)
        let live = entry(fans: [1], deadline: start.advanced(by: .seconds(30)))
        table.insert(lapsed)
        table.insert(live)

        let removed = table.removeLapsed(asOf: start)

        #expect(removed.map(\.id) == [lapsed.id])
        #expect(table.count == 1)
        #expect(table.entry(id: live.id) != nil)
    }

    /// The connection selector removes by connection and knows nothing about deadlines. Note
    /// the deadline below is far in the future: a lease with no chance of having lapsed is
    /// still released when its connection dies.
    @Test("Removing a connection's leases ignores their deadlines entirely")
    func removesByConnectionRegardlessOfDeadline() {
        let start = ContinuousClock.now
        var table = LeaseTable()
        let holder = ConnectionID()
        let held = entry(connection: holder, deadline: start.advanced(by: .seconds(120)))
        let other = entry(deadline: start.advanced(by: .seconds(120)))
        table.insert(held)
        table.insert(other)

        let removed = table.removeAll(heldBy: holder)

        #expect(removed.map(\.id) == [held.id])
        #expect(table.count == 1)
    }

    @Test("A lease is lapsed at its deadline, not merely after it")
    func lapsesAtTheDeadlineItself() {
        let start = ContinuousClock.now
        let lease = entry(deadline: start.advanced(by: .seconds(30)))

        #expect(lease.hasLapsed(asOf: start.advanced(by: .seconds(29))) == false)
        #expect(lease.hasLapsed(asOf: start.advanced(by: .seconds(30))))
        #expect(lease.hasLapsed(asOf: start.advanced(by: .seconds(31))))
    }
}

/// Lease state is in memory and nowhere else, deliberately.
///
/// [ADR 0007](../../docs/ADR/0007-safety-composition.md) rejected persisted lease state
/// outright — *"a lease that survives its enforcer's death is a setting wearing a lease's
/// name"* — and `docs/SAFETY.md` §1 already says the guarantee is *"a live supervised
/// process, not a value written to disk"*.
///
/// The comments in `LeaseTable` say so. This says so in a way that fails a build, because
/// the change it guards against does not arrive announced as "let us invert the central
/// claim of the project's most important safety mechanism" — it arrives as a convenience,
/// so that a restarted helper does not lose a user's fan curve. The mechanism that
/// legitimately covers helper death is startup reconciliation
/// ([#103](https://github.com/blamechris/Aeolus/issues/103)), which needs no stored lease.
///
/// A sibling of `WritePathAbsenceTests`, and a tripwire in the same sense: it cannot see
/// persistence reached by indirection, and it is not trying to. What it catches is the
/// realistic regression.
@Suite("The lease core persists nothing")
struct LeasePersistenceAbsenceTests {

    private static var leaseSources: [URL] {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests/AeolusHelperTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repository root
                .appendingPathComponent("Sources/AeolusHelper/Lease")
            let contents = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
            return contents.filter { $0.pathExtension == "swift" }
        }
    }

    @Test("No file in the lease core reaches for a store")
    func noPersistenceAPIIsUsed() throws {
        let banned = ["UserDefaults", "FileManager", "NSKeyedArchiver", "PropertyListEncoder"]
        let files = try Self.leaseSources

        // Without this the whole suite would be green on a path that resolved to nothing,
        // which is the failure mode `WritePathAbsenceTests` learned the same lesson from.
        #expect(files.count >= 6, "the lease core's sources were not found")

        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for symbol in banned {
                #expect(
                    !code.contains(symbol),
                    """
                    \(file.lastPathComponent) reaches for \(symbol). Lease state is \
                    in-memory only: a lease that survives its enforcer's death is a setting \
                    wearing a lease's name. Helper death is covered by startup \
                    reconciliation, not by a stored lease.
                    """
                )
            }
        }
    }
}
