import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// The bounds of `LeaseScene.firstFloor(since:)` (#521), pinned on a ledger a test writes to, so
/// that no driver is needed and no bound is waited out at its full length.
///
/// What these pin is the wait, not the driver: that it ends at the first of its bounds, says which,
/// and finds what the ledger holds when it does. That the waits in the driver's suites are red at
/// their own `#require` when the driver never mints is a property of those suites, shown by
/// deleting `publishEvidenceChange` in `LeaseDriver.applyAnswered()` and running them.
@Suite(
    "LeaseScene — the wait for a floor ends at the first bound it meets", .timeLimit(.minutes(1)))
struct FloorWaitTests {

    /// A report published with a floor, as the driver publishes one when it stops acting.
    static func floorReport() async throws -> LeaseDriverReport {
        let ticket = await SnapshotTickets.any()
        return LeaseDriverReport(state: .released, automaticEvidence: .readFrom(ticket))
    }

    /// A report published with `noRead`: an `apply` is unanswered.
    static let waiting = LeaseDriverReport(state: .released, automaticEvidence: .noRead)

    /// A floor published after the mark ends the wait, whatever its bounds, and is what it finds.
    ///
    /// **Mutation (W1, "the wait ignores the ledger"):** in `awaitFloor`, replace the ledger's
    /// condition with `{ _ in false }`. Run: red at `end == .published`, the wait ended by the
    /// patience after ten seconds.
    @Test("A floor in the ledger ends the wait at once, and is what the wait finds")
    func aFloorEndsTheWait() async throws {
        let scene = await LeaseScene()
        let floor = try await Self.floorReport()
        let mark = await scene.mark()
        await scene.ledger.record(.report(floor), at: scene.clock.now)

        let wait = await scene.awaitFloor(since: mark)

        #expect(wait.end == .published, "\(wait)")
        #expect(wait.report == floor, "\(wait)")
        await scene.finish()
    }

    /// Neither a floor from before the mark nor a report that carries none is the floor asked for.
    ///
    /// **Mutation (W2, "the mark is ignored"):** in `awaitFloor`, `dropFirst(0)` for
    /// `dropFirst(mark)`, in the ledger's condition and in the last look. Run: red at
    /// `end == .patience` and at `report == nil`.
    /// **Mutation (W3, "a wait for a floor ends on `noRead`"):** in `isFloor`, answer `true` for
    /// `noRead`. Run: the same two.
    @Test("A floor from before the mark, and a report with none, do not end the wait")
    func onlyAFloorAfterTheMarkEndsTheWait() async throws {
        let scene = await LeaseScene()
        await scene.ledger.record(.report(try await Self.floorReport()), at: scene.clock.now)
        let mark = await scene.mark()
        await scene.ledger.record(.report(Self.waiting), at: scene.clock.now)

        let wait = await scene.awaitFloor(since: mark, patience: 20, ceiling: .seconds(1_000))

        #expect(wait.end == .patience, "\(wait)")
        #expect(wait.report == nil, "\(wait)")
        await scene.finish()
    }

    /// A driver that never mints publishes nothing; the patience ends the wait, and says so.
    ///
    /// **Mutation (W4, "the ceiling fires at once"):** in `spendPatience`, `< ceiling` for
    /// `>= ceiling`. Run: red here at `end == .patience`, in the test above at the same, and in
    /// the test below at `waited >= ceiling`.
    @Test("With no floor, the wait ends when its patience is spent")
    func thePatienceEndsTheWait() async {
        let scene = await LeaseScene()
        let mark = await scene.mark()

        let wait = await scene.awaitFloor(since: mark, patience: 20, ceiling: .seconds(1_000))

        #expect(wait.end == .patience, "\(wait)")
        #expect(wait.report == nil, "\(wait)")
        await scene.finish()
    }

    /// The ceiling ends a wait the patience would not. 3,000 steps of a millisecond are three
    /// seconds at the least, so a wait that ends at 50 ms was ended by the ceiling and by nothing
    /// else: a ceiling that never fires leaves the patience to end it, and the end says so.
    ///
    /// **Mutation (W5, "the ceiling never fires"):** in `spendPatience`, replace the
    /// `>= ceiling` check with `_ = began`. Run: red at `end == .ceiling`, the wait ended by the
    /// patience after about six seconds.
    @Test("With steps too slow for the patience, the wall-clock ceiling ends the wait")
    func theCeilingEndsTheWait() async {
        let scene = await LeaseScene()
        let mark = await scene.mark()
        let ceiling = Duration.milliseconds(50)
        let began = ContinuousClock.now

        let wait = await scene.awaitFloor(
            since: mark, patience: 3_000, step: .milliseconds(1), ceiling: ceiling)
        let waited = ContinuousClock.now - began

        #expect(wait.end == .ceiling, "\(wait)")
        #expect(wait.report == nil, "\(wait)")
        #expect(waited >= ceiling, "the wait gave up after \(waited), before its ceiling")
        await scene.finish()
    }

    /// The scene's own bounds: the ceiling is below the smallest time limit Swift Testing can
    /// express, 60 s, so that a driver that never mints is a red at the `#require` and not there.
    ///
    /// **Mutation (W6, "the ceiling reaches the limit"):** set `LeaseScene.floorCeiling` to
    /// `.seconds(60)`. Run: red at `floorCeiling < limit`.
    @Test("The scene's ceiling is below the suites' time limit")
    func theCeilingIsBelowTheTimeLimit() {
        let limit = Duration.seconds(60)
        #expect(LeaseScene.floorCeiling < limit, "\(LeaseScene.floorCeiling) is not below \(limit)")
    }
}
