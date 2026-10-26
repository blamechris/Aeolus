import Foundation
import Testing

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
    /// after a change of the evidence alone, and a fresh driver's first is its own report.
    ///
    /// **Mutation (V1, an evidence change that is not stored):** in
    /// `LeaseDriverPublisher.publishEvidenceChange(_:)`, yield `report` to the report observers
    /// without storing it as the value now. Run: red at "after an evidence change", where the
    /// new report stream starts with the evidence before it.
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

    /// Subscribers register on the pool while an actor that owns a publisher, as the driver does,
    /// publishes `published` changes of state in one turn. Each stream must hold an unbroken run:
    /// some value, then every later one in order, once each, through the last.
    ///
    /// A run proves the order and that nothing is skipped or repeated. It cannot prove that the
    /// first element was the value at the instant of registration, only that whatever came first
    /// was followed by every later value and nothing earlier.
    ///
    /// **Mutation (V2, the first value yielded outside the lock):** in `Followers.stream()`,
    /// read the value now and register under the lock, and yield the value after the lock is
    /// released. A publication can then take the lock between the two, find the new observer, and
    /// yield it the next value ahead of its first. See the PR for how often a run caught it; a
    /// pool of one thread cannot interleave the two at all.
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

    /// The first element of `stream`. It always has one: registering yields the value now.
    static func first<Element: Sendable>(of stream: AsyncStream<Element>) async -> Element? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
