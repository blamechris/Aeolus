import Foundation
import Testing
import os

@testable import AeolusLeaseControl

/// A queue of followers against the answer of the last unanswered `apply` (#541): every write to
/// a `LeaseDriver`'s `evidence` is published in the turn that makes it, so an observer opened at
/// any moment starts with the driver's `report`.
///
/// The loop is bounded by cancellation and by `patience`, so a driver that never mints the floor
/// is a red and not a hang.
@Suite(
    "LeaseDriver — a stream opened as the evidence moves alone starts with the report",
    .timeLimit(.minutes(1)))
struct LeaseDriverEvidencePublishTests {

    /// Observers of a real driver, opened over and over from the moment the evidence moves alone,
    /// start with the driver's `report`, read in the same turn of the driver's actor.
    ///
    /// The evidence moves alone when the last unanswered `apply` answers after the driver let go
    /// of its lease: `applyAnswered()` mints the floor and publishes the report with the state
    /// unchanged. Since #541 an observer's first element is the publisher's value, not
    /// `LeaseDriver.report` read on the actor, so the two agree between turns only while every
    /// write to `current` or `evidence` is published in the turn that makes it. Nothing else
    /// reads the publisher's value against the driver's, and a publish left to a task is correct
    /// in the end, which is why the other tests of the driver cannot see it.
    ///
    /// **A deferred publish is visible only between its turn and its task**, and the task runs
    /// next unless something else is already queued. So `followers` tasks open a stream and read
    /// `report` in one isolated turn (`openAndRead(_:)`) as fast as they can, from before the
    /// `apply` answers until a stream or the driver shows the floor. The driver's actor then has
    /// a queue in which the answer's turn is followed by their turns, and a task the answer's
    /// turn started would be behind them.
    ///
    /// After the floor is published the same is done once more with nothing racing, which is the
    /// plain reading of the property.
    ///
    /// **Mutation (B, a deferred publish):** in `applyAnswered()`, replace the publish with
    /// `let answered = report; Task { self.publisher.publishEvidenceChange(answered) }`. Run,
    /// debug: red in 5 of 5 at `raced.mismatches.isEmpty`, with 8 of 320 to 537 streams
    /// mismatched in every run, one for each follower: the stream started with `noRead` where the
    /// driver's `report` already carried the floor. Before this test, B was green on all 777 tests
    /// of the package in 5 of 5 runs (the review that found it).
    @Test("A stream opened as the evidence moves alone starts with the driver's report")
    func aNewObserverStartsWithTheReportAsTheEvidenceMovesAlone() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.applies.isEmpty }
        let released = await scene.mark()
        await scene.driver.selectAutomatic()
        let noRead = try #require(await scene.firstReport(since: released) { $0.isReleased })
        try #require(noRead.automaticEvidence == .noRead, "no floor until the apply answers")

        let answered = await scene.mark()
        let raced = await Self.followTheDriver(through: scene, answeredAfter: answered)
        let floor = try #require(
            await scene.firstFloor(since: answered), "the apply answered and no floor was published"
        )

        #expect(raced.beforeTheFloor >= Self.followers, "every follower compared before the answer")
        #expect(raced.sawTheFloor > 0, "a follower compared once the floor was minted")
        #expect(
            raced.mismatches.isEmpty,
            """
            \(raced.mismatchCount) of \(raced.compared) streams opened while the evidence moved \
            alone did not start with the driver's report; the first few: \(raced.mismatches)
            """)

        let (stream, report) = await Self.openAndRead(scene.driver)
        #expect(report == floor, "the driver's report is the floor that was published")
        #expect(
            await LeaseDriverPublisherTests.first(of: stream) == report,
            "a stream opened after the evidence moved alone starts with the driver's report")
        await scene.finish()
    }

    // MARK: - Support

    /// How many steps the test waits for the followers to compare once, and how long each is.
    static let patience = 5_000
    static let step: Duration = .milliseconds(1)

    /// How many tasks open streams of a real driver at once.
    static let followers = 8

    /// A stream of `driver`'s reports and its `report`, both taken in the same turn of the
    /// driver's actor, so nothing can have been published between them.
    static func openAndRead(
        _ driver: isolated LeaseDriver
    ) -> (stream: AsyncStream<LeaseDriverReport>, report: LeaseDriverReport) {
        (driver.reportUpdates(), driver.report)
    }

    /// Starts `followers` tasks that open streams of `scene`'s driver and read its `report` in the
    /// same turn, again and again; once each has compared at least once, answers the `apply` that
    /// is parked at the helper; and returns what they found when each has seen the floor.
    /// Cancels them if no floor is published, so a driver that never mints cannot hold the test.
    static func followTheDriver(
        through scene: LeaseScene, answeredAfter answered: Int
    ) async -> Comparisons {
        let ready = Counter()
        let driver = scene.driver
        return await withTaskGroup(of: Comparisons.self) { group in
            for _ in 0..<followers {
                group.addTask { await compareNewStreams(with: driver, ready: ready) }
            }
            var waited = 0
            while ready.value < followers, waited < patience {
                do { try await Task.sleep(for: step) } catch { break }
                waited += 1
            }
            await scene.helper.answerParked(.apply)
            if await scene.firstFloor(since: answered) == nil { group.cancelAll() }
            var raced = Comparisons()
            for await comparisons in group { raced.add(comparisons) }
            return raced
        }
    }

    /// Opens a stream and reads the report in one turn, again and again, until the driver's
    /// report carries a floor or the task is cancelled. Counts itself in `ready` after its first
    /// comparison.
    static func compareNewStreams(with driver: LeaseDriver, ready: Counter) async -> Comparisons {
        var comparisons = Comparisons()
        var counted = false
        while !Task.isCancelled {
            let (stream, report) = await openAndRead(driver)
            var elements = stream.makeAsyncIterator()
            guard let first = await elements.next() else { break }
            comparisons.compared += 1
            if report.automaticEvidence.isFloor {
                comparisons.sawTheFloor += 1
            } else {
                comparisons.beforeTheFloor += 1
            }
            if first != report {
                comparisons.record(
                    mismatch: "first \(first.automaticEvidence), report \(report.automaticEvidence)"
                )
            }
            if !counted {
                counted = true
                ready.increment()
            }
            if report.automaticEvidence.isFloor { break }
        }
        return comparisons
    }

    /// What the followers found, added across them.
    struct Comparisons: Sendable {
        var compared = 0
        var beforeTheFloor = 0
        var sawTheFloor = 0
        var mismatchCount = 0
        /// The first few streams that were wrong, as text.
        var mismatches: [String] = []

        mutating func record(mismatch example: String) {
            mismatchCount += 1
            if mismatches.count < 3 { mismatches.append(example) }
        }

        mutating func add(_ other: Comparisons) {
            compared += other.compared
            beforeTheFloor += other.beforeTheFloor
            sawTheFloor += other.sawTheFloor
            mismatchCount += other.mismatchCount
            for example in other.mismatches where mismatches.count < 3 {
                mismatches.append(example)
            }
        }
    }

    /// A count that tasks add to and one task reads.
    final class Counter: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)

        var value: Int { count.withLock { $0 } }

        func increment() { count.withLock { $0 += 1 } }
    }
}
