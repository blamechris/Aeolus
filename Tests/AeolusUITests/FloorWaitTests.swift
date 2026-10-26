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

    /// A floor in the ledger stops the sleeper: the wait does not sit out its patience after the
    /// ledger has what it waited for. Counted in steps, not timed, so that no stall can fail it:
    /// a sleeper that is cancelled when the floor ends the wait has slept through no step (none,
    /// in 200 waits of a probe), and one that is not has slept through all 3,000, which is three
    /// seconds at the least.
    ///
    /// **Mutation (E1′, "a published floor leaves the sleeper running"):** in `awaitFloor`,
    /// `if verdict != .published { group.cancelAll() }`. Run: red here at `wait.slept < patience`,
    /// after the 3,000 steps, 6 to 10 seconds in two runs. **(E1, "no one is cancelled"):** delete
    /// `group.cancelAll()`. Run: the same here, and the three tests whose wait the sleeper ends
    /// never return, so they are red at the suite's time limit; the run takes 63.8 s.
    @Test("A floor in the ledger stops the sleeper")
    func aFloorStopsTheSleeper() async throws {
        let scene = await LeaseScene()
        let floor = try await Self.floorReport()
        let mark = await scene.mark()
        await scene.ledger.record(.report(floor), at: scene.clock.now)
        let patience = 3_000

        let wait = await scene.awaitFloor(
            since: mark, patience: patience, step: .milliseconds(1), ceiling: .seconds(1_000))

        #expect(wait.end == .published, "\(wait)")
        #expect(wait.slept < patience, "the sleeper slept through its whole patience: \(wait)")
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
    /// `>= ceiling`. Run: red here at `end == .patience`, in the test above at the same, in the
    /// test below at `waited >= ceiling`, and in the cancellation test at `end == .cancelled`.
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

    /// A floor already in the ledger is found by the last look whatever ended the wait. With no
    /// patience at all the sleeper ends the wait at once, but so can the ledger's report, and
    /// which of them is first is not ordered: in a loop of 200 such waits the end was `patience`
    /// in 123. So this test sees the last look do its work only when the sleeper is first, and
    /// the test below is the one that cannot miss.
    ///
    /// **Mutation (B, "the last look only after a floor ended the wait"):** in `awaitFloor`,
    /// compute `report` only when `end == .published`. Run ten times: red here at
    /// `wait.report == floor` in 8 of the ten (10 of ten in an earlier set of mine, 7 of ten in a
    /// reviewer's), which is not promised; red in the test below in all ten, every time it has
    /// been run.
    @Test("A floor in the ledger is found when the patience was spent, too")
    func aFloorIsFoundAfterTheBound() async throws {
        let scene = await LeaseScene()
        let floor = try await Self.floorReport()
        let mark = await scene.mark()
        await scene.ledger.record(.report(floor), at: scene.clock.now)

        let wait = await scene.awaitFloor(since: mark, patience: 0, ceiling: .seconds(1_000))

        #expect(wait.report == floor, "\(wait)")
        await scene.finish()
    }

    /// A floor already in the ledger is found by the last look when the wait did not end on the
    /// ledger at all: the waiting task is cancelled before the wait starts, so neither racer
    /// reaches a verdict and the end is `cancelled` every time.
    ///
    /// **Mutation (B):** red at `wait.report == floor`.
    @Test("A floor in the ledger is found when the waiting task was cancelled")
    func aFloorIsFoundAfterACancellation() async throws {
        let scene = await LeaseScene()
        let floor = try await Self.floorReport()
        let mark = await scene.mark()
        await scene.ledger.record(.report(floor), at: scene.clock.now)

        let wait = try await Self.cancelled(scene, since: mark, before: true)

        #expect(wait.end == .cancelled, "\(wait)")
        #expect(wait.report == floor, "\(wait)")
        await scene.finish()
    }

    /// Cancelling the waiting task ends the wait, promptly and as `cancelled`, however far off the
    /// patience and the ceiling are. Neither racer has a verdict then, so it is not the one that
    /// stops first that decides.
    ///
    /// **Mutation (C, "the ledger's racer says published when cancelled"):** in `awaitFloor`,
    /// `return .published` for `return Task.isCancelled ? nil : .published`. Run ten times: red
    /// at `wait.end == .cancelled` in all ten, and in the test above in all ten.
    /// **(D, "the sleeper says patience when cancelled"):** in `spendPatience`, `return .patience`
    /// for `return nil` in the `catch`. Run ten times: the same.
    @Test("Cancelling the waiting task ends the wait as cancelled")
    func aCancellationEndsTheWait() async throws {
        let scene = await LeaseScene()
        let mark = await scene.mark()

        let wait = try await Self.cancelled(scene, since: mark, before: false)

        #expect(wait.end == .cancelled, "\(wait)")
        #expect(wait.report == nil, "\(wait)")
        await scene.finish()
    }

    /// `awaitFloor` with a patience and a ceiling too far off to end it, on a task of its own that
    /// is cancelled `before` the wait starts or while it is under way.
    ///
    /// The wait for the task to finish is bounded by a count of short sleeps, not by time, so that
    /// a stall of the whole process costs one step; it ends when the test's own task is cancelled
    /// too. The task is not awaited by its value, which does not respond to cancellation.
    static func cancelled(
        _ scene: LeaseScene, since mark: Int, before: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> LeaseScene.FloorWait {
        let finished = LeaseScene.Call(token: UUID())
        let box = ResultBox<LeaseScene.FloorWait>()
        let ledger = scene.ledger
        let clock = scene.clock
        let task = Task {
            // Ends at once if the task is already cancelled, and is never the end of the wait.
            if before { try? await Task.sleep(for: .seconds(60)) }
            box.set(
                await scene.awaitFloor(
                    since: mark, patience: 5_000_000, step: .milliseconds(1),
                    ceiling: .seconds(1_000)))
            await ledger.record(.callReturned(finished.token), at: clock.now)
        }
        if !before { try? await Task.sleep(for: .milliseconds(50)) }
        task.cancel()

        var returned = false
        for _ in 0..<2_000 {
            if await scene.hasReturned(finished) {
                returned = true
                break
            }
            do { try await Task.sleep(for: .milliseconds(1)) } catch { break }
        }
        try #require(
            returned, "the wait did not end within 2,000 steps of its task being cancelled",
            sourceLocation: sourceLocation)
        return try #require(box.value, sourceLocation: sourceLocation)
    }

    /// The scene's own bounds: the ceiling is below the smallest time limit Swift Testing can
    /// express, 60 s, by a margin, so that a driver that never mints is a red at the `#require`
    /// and not there. The margin is what a step in flight can overrun the ceiling by, and the
    /// time the test spends before and after the wait.
    ///
    /// **Mutation (W6, "the ceiling reaches the limit"):** set `LeaseScene.floorCeiling` to
    /// `.seconds(60)`. Run: red at `floorCeiling <= largestAllowedCeiling`.
    @Test("The scene's ceiling is below the suites' time limit, with a margin")
    func theCeilingIsBelowTheTimeLimit() {
        let largestAllowedCeiling = Duration.seconds(55)
        #expect(
            LeaseScene.floorCeiling <= largestAllowedCeiling,
            "\(LeaseScene.floorCeiling) is above \(largestAllowedCeiling), too near a 60 s limit")
    }
}
