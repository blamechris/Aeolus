import Foundation
import Testing
import os

@testable import AeolusLeaseControl

/// What a new observer of `LeaseDriverPublisher` is handed first, and how a registration that
/// races a publication orders against it (#541).
///
/// Since #541 an observer registers in the step that makes its stream, on whatever thread that
/// is, and not on the driver's actor. So its first element is the value the publisher holds,
/// not `LeaseDriver.report` read on the actor. The two must agree, and a registration that runs
/// while the driver publishes must still hand its stream the value then and every later one, in
/// order and once each.
@Suite(
    "LeaseDriverPublisher — a new observer starts with the value now, however it races a publish",
    .timeLimit(.minutes(1)))
struct LeaseDriverPublisherTests {

    /// A new observer's first element is the last report published, after a change of state and
    /// after a change of the evidence alone, and a fresh driver's first is its own report. That a
    /// real driver's publisher agrees with its `report` after the evidence moved alone is
    /// `aNewObserverStartsWithTheReportAsTheEvidenceMovesAlone()`.
    ///
    /// **Mutation (V1, a value that is never stored):** in `Followers.store(_:)`, delete
    /// `state.current = value`. Run, debug: red at "after a change of state" and at each first
    /// element checked after it, in 3 of 3. #513's `aTurnOfChangesIsPublishedWhole()` goes red too,
    /// at "in order" and at its state stream, because its subscribers start with the report from
    /// before the lease.
    @Test("A new observer starts with the last report published, and a new driver with its own")
    func aNewObserverStartsWithTheReportNow() async throws {
        let start = LeaseDriverReport.idle
        let acquiring = LeaseDriverReport(state: .acquiring(fans: [0]), automaticEvidence: .anyRead)
        let waiting = LeaseDriverReport(state: .acquiring(fans: [0]), automaticEvidence: .noRead)
        let publisher = LeaseDriverPublisher(startingWith: start)

        #expect(await Self.first(of: publisher.streams.reportUpdates()) == start, "at the start")
        #expect(await Self.first(of: publisher.streams.stateUpdates()) == start.state)

        publisher.publishStateChange(acquiring)
        #expect(
            await Self.first(of: publisher.streams.reportUpdates()) == acquiring,
            "after a change of state")
        #expect(await Self.first(of: publisher.streams.stateUpdates()) == acquiring.state)

        publisher.publishEvidenceChange(waiting)
        #expect(
            await Self.first(of: publisher.streams.reportUpdates()) == waiting,
            "after an evidence change")
        #expect(
            await Self.first(of: publisher.streams.stateUpdates()) == waiting.state,
            "an evidence change leaves the state stream's value as it was")

        let clock = HandWoundClock()
        let driver = LeaseDriver(
            control: FakeLeaseHelper(clock: clock, ledger: LeaseLedger()),
            holderDescription: LeaseScene.holder, clock: clock)
        let firstReport = await Self.first(of: driver.reportUpdates())
        #expect(
            firstReport == (await driver.report), "a new driver's stream starts with its report")
        #expect(await Self.first(of: driver.stateUpdates()) == (await driver.state))
    }

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

        let ready = Counter()
        let driver = scene.driver
        let answered = await scene.mark()
        let raced = await withTaskGroup(of: Comparisons.self) { group in
            for _ in 0..<Self.followers {
                group.addTask { await Self.compareNewStreams(with: driver, counting: ready) }
            }
            var waited = 0
            while ready.value < Self.followers, waited < Self.patience {
                do { try await Task.sleep(for: Self.step) } catch { break }
                waited += 1
            }
            await scene.helper.answerParked(.apply)
            if await scene.firstFloor(since: answered) == nil { group.cancelAll() }
            var raced = Comparisons()
            for await comparisons in group { raced.add(comparisons) }
            return raced
        }
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
            await Self.first(of: stream) == report,
            "a stream opened after the evidence moved alone starts with the driver's report")
        await scene.finish()
    }

    /// Subscribers register on the pool while an actor that owns a publisher, as the driver does,
    /// publishes `published` changes of state in one turn. Each stream must hold an unbroken run:
    /// some value, then every later one in order, once each, through the last.
    ///
    /// A run proves the order and that nothing is skipped or repeated. It cannot prove that the
    /// first element was the value at the instant of registration, only that whatever came first
    /// was followed by every later value and nothing earlier.
    ///
    /// **What it does not catch (V2, the first value yielded outside the lock):** in
    /// `Followers.stream()`, register and read the value now under the lock, and yield it after
    /// the lock is released. A publication could then take the lock between the two, find the new
    /// observer, and yield it the next value ahead of its first. Run, debug: green in 10 of 10.
    /// It registers 200 streams, and a review counted 0 to 10 of them registering while the owner
    /// published, so the window, the few instructions between the release and the yield, is
    /// crossed rarely if at all. That, and a snapshot and a set in two lock sections (C1 and C2),
    /// are pinned by `aStormOfRegistrationsIsHandedEachChangeAfterTheOneBeforeIt()`. What this
    /// test holds is the run: every stream is handed every later change, in order, once each.
    ///
    /// What it does catch, run in debug: P1 (`.bufferingNewest(1)` in `Followers.stream()`), red in
    /// 3 of 3 with every stream broken, as #513's test is; and V1 above, red in 2 of 3.
    @Test("A registration racing a run of publications is handed an unbroken run of them")
    func aRegistrationRacingPublicationsGetsAnUnbrokenRun() async {
        let owner = Owner()
        let runs = await withTaskGroup(of: [Int]?.self) { group in
            for index in 0..<Self.subscribers {
                group.addTask {
                    index.isMultiple(of: 2)
                        ? await Self.run(of: owner.streams.reportUpdates()) { $0.state }
                        : await Self.run(of: owner.streams.stateUpdates()) { $0 }
                }
            }
            group.addTask {
                await owner.publish(through: Self.published)
                return nil
            }
            var runs: [[Int]] = []
            for await run in group { if let run { runs.append(run) } }
            return runs
        }

        #expect(runs.count == Self.subscribers)
        let broken = runs.filter { run in
            guard let first = run.first else { return true }
            return run != Array(first...Self.published)
        }
        #expect(
            broken.isEmpty,
            """
            \(broken.count) of \(runs.count) streams were not handed an unbroken run through \
            \(Self.published); the first: \(broken.first.map { Array($0.prefix(8)) } ?? [])
            """)
    }

    /// Streams register in a loop on the pool while an actor that owns a publisher makes one long
    /// run of publications in a single turn. Each stream takes two elements, and the second must
    /// be the change published right after the first: the value at registration, then the next
    /// change, with nothing between them and nothing ahead of the first.
    ///
    /// **Why this and not the test above.** The window a wrong first yield or a split lock opens is
    /// a few instructions wide. The test above registers 200 streams in all, and a run of it
    /// registered 0 to 10 of them while the owner was publishing. This registers streams for as
    /// long as the owner publishes (`stormPublished`), `stormers` tasks at a time, half of each
    /// kind, so a window that narrow is crossed many times in one run. `midRun` counts the
    /// registrations that began after the run did, and the test requires `minimumMidRun` of them
    /// wherever tasks can run beside the owner's turn.
    ///
    /// The owner publishes only once every task has registered once, so none of them is a
    /// latecomer to a run already over. Every wait is on a task group's child or on a stream, all
    /// of which end when the test is cancelled, and a reader still waiting once the owner has
    /// finished is cancelled after `grace` and counted as `abandoned`, so a mutant that loses an
    /// element is a red and not a test that waits for it until the suite's time limit.
    ///
    /// **Mutations (debug, 5 runs each, all red at `total.broken.isEmpty`):**
    /// - **V2, the first value yielded after the lock is released:** 177 to 286 of about 500,000
    ///   to 560,000 streams broken in a run, each a change followed by the one before it.
    /// - **C1, `Followers.store(_:)` taking the observers in one `withLock` section and setting
    ///   the value in a second:** 20,224 to 21,686 of about 490,000 to 510,000, each a change
    ///   that skipped its successor.
    /// - **C2, the same two sections with the value set first:** 15,646 to 17,776 of about
    ///   490,000 to 525,000, each a change followed by itself.
    ///
    /// Unmutated, debug, a run registers about 490,000 to 500,000 streams, all but a few of them
    /// mid-run, and none is broken. `HealthSignalTests` has the same test for the health signal.
    @Test("A storm of registrations is handed each change right after the one before it")
    func aStormOfRegistrationsIsHandedEachChangeAfterTheOneBeforeIt() async {
        let owner = Owner()
        let registered = Counter()
        let total = await withTaskGroup(of: StormOutcome.self) { group in
            for index in 0..<Self.stormers {
                group.addTask {
                    .stormer(
                        index.isMultiple(of: 2)
                            ? await Self.storm(
                                owner.streams.reportUpdates, fan: { Self.fan(of: $0.state) },
                                counting: registered)
                            : await Self.storm(
                                owner.streams.stateUpdates, fan: Self.fan(of:),
                                counting: registered))
                }
            }
            group.addTask {
                // Bounded by steps as well as by cancellation, so a stormer that cannot start does
                // not hold the owner back for ever.
                var waited = 0
                while registered.value < Self.stormers, waited < Self.patience {
                    do { try await Task.sleep(for: Self.step) } catch { return .published }
                    waited += 1
                }
                await owner.publish(through: Self.stormPublished)
                return .published
            }
            var total = Tally()
            var stormersLeft = Self.stormers
            for await outcome in group {
                switch outcome {
                case .stormer(let tally):
                    total.add(tally)
                    stormersLeft -= 1
                    if stormersLeft == 0 { group.cancelAll() }
                case .published:
                    if stormersLeft > 0 {
                        group.addTask {
                            try? await Task.sleep(for: Self.grace)
                            return .graceEnded
                        }
                    }
                case .graceEnded:
                    group.cancelAll()
                }
            }
            return total
        }

        #expect(
            total.abandoned == 0,
            "\(total.abandoned) streams never got a second element, and were cancelled")
        #expect(
            total.broken.isEmpty,
            """
            \(total.brokenCount) of \(total.registrations) streams were not handed the change \
            after their first as their second; the first few (first, second): \(total.broken)
            """)
        if Self.canRaceThePublisher {
            #expect(
                total.midRun >= Self.minimumMidRun,
                """
                only \(total.midRun) of \(total.registrations) registrations began while the owner \
                was publishing, so this run did not race it
                """)
        }
    }

    // MARK: - Support

    /// How many streams race the publications, half of each kind.
    static let subscribers = 200

    /// How many changes of state the owner publishes after its first value.
    static let published = 2_000

    /// A publisher owned by an actor, as `LeaseDriver` owns its own, so every publication runs on
    /// that actor and the streams are reached from anywhere.
    actor Owner {
        private let publisher: LeaseDriverPublisher
        nonisolated let streams: LeaseDriverPublisher.Streams

        init() {
            let publisher = LeaseDriverPublisher(startingWith: LeaseDriverPublisherTests.report(0))
            self.publisher = publisher
            streams = publisher.streams
        }

        /// Publishes the changes `1...last`, in one turn of this actor.
        func publish(through last: Int) {
            for value in 1...last {
                publisher.publishStateChange(LeaseDriverPublisherTests.report(value))
            }
        }
    }

    /// The report for change `value`: acquiring fan `value`, so the fan number orders them.
    static func report(_ value: Int) -> LeaseDriverReport {
        LeaseDriverReport(state: .acquiring(fans: [value]), automaticEvidence: .anyRead)
    }

    /// The fan numbers `stream` hands over until it reaches `published`. Iterating an
    /// `AsyncStream` ends when the task is cancelled, so the suite's time limit can end it.
    static func run<Element: Sendable>(
        of stream: AsyncStream<Element>, state: (Element) -> LeaseDriverState
    ) async -> [Int] {
        var seen: [Int] = []
        for await element in stream {
            guard case .acquiring(let fans) = state(element), let fan = fans.first else { break }
            seen.append(fan)
            if fan == published { break }
        }
        return seen
    }

    // MARK: - Following a driver's reports

    /// How many tasks open streams of a real driver at once.
    static let followers = 8

    /// A stream of `driver`'s reports and its `report`, both taken in the same turn of the
    /// driver's actor, so nothing can have been published between them.
    static func openAndRead(
        _ driver: isolated LeaseDriver
    ) -> (stream: AsyncStream<LeaseDriverReport>, report: LeaseDriverReport) {
        (driver.reportUpdates(), driver.report)
    }

    /// Opens a stream and reads the report in one turn, again and again, until the driver's
    /// report carries a floor or the task is cancelled. Counts itself in `ready` after its first
    /// comparison.
    static func compareNewStreams(
        with driver: LeaseDriver, counting ready: Counter
    ) async
        -> Comparisons
    {
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

    // MARK: - The storm

    /// How many tasks register streams at once, half of each kind.
    static let stormers = 8

    /// How many changes of state the owner publishes in the storm's single turn.
    static let stormPublished = 100_000

    /// How many registrations must have begun after the owner started publishing. Their number
    /// depends on the machine, and a run is far above this one on the development machine; a run
    /// below it did not race the owner, which is what the floor is there to say.
    static let minimumMidRun = 1_000

    /// Whether the pool can run a stormer beside the owner's turn. On a pool of one thread
    /// (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) the turn holds the only thread, so no
    /// registration can begin in the middle of it and the run claims no race.
    static let canRaceThePublisher =
        ProcessInfo.processInfo.activeProcessorCount > 1
        && ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] != "1"

    /// How long a stormer may wait for an element after the owner has finished, before it is
    /// cancelled and counted as abandoned.
    static let grace: Duration = .seconds(10)

    /// How many steps the owner waits for the stormers to register once, and how long each is.
    static let patience = 5_000
    static let step: Duration = .milliseconds(1)

    /// The fan number a change of state carries, or `nil` for any other state.
    static func fan(of state: LeaseDriverState) -> Int? {
        guard case .acquiring(let fans) = state else { return nil }
        return fans.first
    }

    /// Registers streams one after another, made by `stream`, until it sees the last change first
    /// or is cancelled, taking two elements of each and checking the second against the first.
    static func storm<Element: Sendable>(
        _ stream: @Sendable () -> AsyncStream<Element>, fan: @Sendable (Element) -> Int?,
        counting registered: Counter
    ) async -> Tally {
        var tally = Tally()
        var counted = false
        while !Task.isCancelled {
            var elements = stream().makeAsyncIterator()
            guard let first = await elements.next().flatMap(fan) else {
                tally.abandoned += 1
                break
            }
            tally.registrations += 1
            if !counted {
                counted = true
                registered.increment()
            }
            if first == stormPublished { break }
            if first != 0 { tally.midRun += 1 }
            guard let second = await elements.next().flatMap(fan) else {
                tally.abandoned += 1
                break
            }
            if second != first + 1 { tally.record(broken: "\(first) then \(second)") }
            if second == stormPublished { break }
        }
        return tally
    }

    /// What the stormers found, added across them.
    struct Tally: Sendable {
        var registrations = 0
        var midRun = 0
        var abandoned = 0
        var brokenCount = 0
        /// The first few streams that were wrong, as text.
        var broken: [String] = []

        mutating func record(broken example: String) {
            brokenCount += 1
            if broken.count < 3 { broken.append(example) }
        }

        mutating func add(_ other: Tally) {
            registrations += other.registrations
            midRun += other.midRun
            abandoned += other.abandoned
            brokenCount += other.brokenCount
            for example in other.broken where broken.count < 3 { broken.append(example) }
        }
    }

    /// What ends a child of the storm's task group.
    enum StormOutcome: Sendable {
        case stormer(Tally)
        case published
        case graceEnded
    }

    /// A count that tasks add to and one task reads.
    final class Counter: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)

        var value: Int { count.withLock { $0 } }

        func increment() { count.withLock { $0 += 1 } }
    }

    /// The first element of `stream`. It always has one: registering yields the value now.
    static func first<Element: Sendable>(of stream: AsyncStream<Element>) async -> Element? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
