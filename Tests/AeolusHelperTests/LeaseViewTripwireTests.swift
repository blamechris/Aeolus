import Foundation
import Testing

/// `LeaseAuthority.activeLeaseView()` reads the lease and the handback registers with no
/// suspension between them (#516's review). ADR 0015 D5's *Clearance* rests on it.
///
/// The snapshot restates a fan whose restore is on the wire as `.releaseInProgress` only because
/// the registers it is judged against were read in the same synchronous region as the lease it is
/// listed beside. Read the registers, suspend, then read the table: a lease granted during the
/// suspension is listed beside registers from before a handback that began meanwhile, and a fan
/// whose restore is on the wire reads cleared to automatic beside that lease, `CLAUDE.md` rule 6.
/// `HandbackBesideAnotherLeaseTests` cannot see this, because it holds the handback parked across
/// the whole snapshot. Two such mutations left all 1543 helper tests green before this suite.
///
/// **The anchor is the first read of lease-core state, wherever it falls**: `table`, `registers`,
/// `sleep`, `fansAeolusIsAccountableFor` or `machineWideRestoresInFlight`, bare or after `self.`.
/// Everything from there to the end of the body must hold no `await`. The `await`s above it, the
/// sweep of lapsed leases and § 3's read of `emergencyRestores`, are allowed, and § 3's comes first
/// on purpose (`LeaseAccountability.restoresAwaitingConfirmation` says why). Anchoring on the first
/// read rather than on § 3's line means a register read moved above an `await` is still inside the
/// region.
///
/// Read through `TeardownCountTripwireTests`' parsing: comments stripped, whitespace and line
/// breaks collapsed, and the space around `.` and before `(` removed, so `try await`, `await(`, a
/// doubled space and an `await` on a line of its own all read as `await`. It fails closed when it
/// cannot find the function, the anchor, or both reads in the region.
///
/// **It catches an accidental suspension, not an adversarial spelling.** State read through a
/// helper method above an `await`, or a register read hidden behind a computed property this
/// pattern does not name, passes it. A behavioural pin would need a seam inside the view.
@Suite("The lease view reads the lease and the registers in one synchronous region")
struct LeaseViewTripwireTests {

    private typealias Scan = TeardownCountTripwireTests

    /// A read of this actor's own state the view reports, in normalised code. The lookbehind keeps
    /// `Task.sleep` and a member of something else (`x.table`) out of it.
    private static let leaseCoreRead =
        #"(?<![\w.])(?:self\.)?"#
        + #"(?:table|registers|sleep|fansAeolusIsAccountableFor|machineWideRestoresInFlight)\b"#

    /// **Mutation (M-view):** add `await Task.yield()` after `let shown = table.all.first`. Run:
    /// red. **Mutation (M-view2):** read `fansAeolusIsAccountableFor` and the three registers into
    /// locals first, then `await Task.yield()`, then `let shown = table.all.first`, and pass the
    /// locals. Run: red. Both were green across the whole suite before this test. **Mutation:** the
    /// same `await`, spelled `try? await Task.sleep(for: .zero)`, then `await` and `Task.yield()`
    /// on two lines, then `await (Task.yield())`. Run: red, each. **Mutation (this suite's own):**
    /// replace `leaseCoreRead` with a pattern nothing matches. Run: red on the `#require`.
    @Test("activeLeaseView() does not suspend between its first lease-core read and its return")
    func theViewDoesNotSuspendAfterItsFirstRead() throws {
        let code = Scan.normalised(try Scan.leaseCoreWithoutAnyComment())
        let view = try #require(
            Scan.function(named: "activeLeaseView", in: code),
            "the lease core declares no `func activeLeaseView(`, so the view was not read")
        let first = try #require(
            view.body.range(of: Self.leaseCoreRead, options: .regularExpression),
            "activeLeaseView() reads no lease-core state this scan can find: \(view.body)")
        let region = view.body[first.lowerBound...]

        #expect(
            region.contains("table.") && region.contains("registers."),
            """
            activeLeaseView() does not read both the lease table and the handback registers \
            after its first lease-core read: \(region). Read through a helper outside the region, \
            one of them could come from before a suspension this scan cannot see.
            """)
        #expect(
            region.range(of: #"\bawait\b"#, options: .regularExpression) == nil,
            """
            activeLeaseView() suspends between its first read of lease-core state and its \
            return: \(region). A lease granted in that suspension is listed beside registers \
            read before a handback that began meanwhile, so a fan whose restore is on the wire \
            reads cleared to automatic beside the new lease (ADR 0015 D5, *Clearance*). Read \
            the lease and every register in one straight-line region.
            """)
    }
}
