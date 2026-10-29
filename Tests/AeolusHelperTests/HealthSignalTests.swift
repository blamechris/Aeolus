import Foundation
import Testing
import os

@testable import AeolusXPCClient

/// What a new observer of `HealthSignal` is handed first, and how a registration that races a
/// publication orders against it (#541).
///
/// Since #541 an observer of `HelperClient.healthUpdates()` registers in the step that makes its
/// stream, on whatever thread that is, and not on the client's actor. So its first element is the
/// value the signal holds. A registration that runs while the client publishes must still hand
/// its stream the value then and every later one, in order and once each; the storm test is
/// what holds the registration to the value at the instant it took the lock.
@Suite(
    "HealthSignal — a new observer starts with the value now, however it races a publish",
    .timeLimit(.minutes(1)))
struct HealthSignalTests {

    /// A new observer's first element is the last value published, a value equal to the one now
    /// is not published again, and a new client's first is its own `health`.
    ///
    /// **Mutation (V1, a value that is never stored):** in `HealthObservers.store(_:)`, delete
    /// `state.current = health`. Run, debug: red here at `signal.current` and at both reads after
    /// it, in 3 of 3, and in five tests of `HelperClientConnectionTests`.
    ///
    /// **Mutation (D1, no comparison):** in `HealthObservers.store(_:)`, delete the `guard` that
    /// returns `nil` for the value now. Run, debug: red here at "the repeated value was not sent
    /// again" in 3 of 3, and in
    /// `HelperClientConnectionTests.theHealthStreamFollowsTheConnection()`.
    @Test("A new observer starts with the last value published, and an unchanged one is not sent")
    func aNewObserverStartsWithTheValueNow() async {
        let signal = HealthSignal(startingWith: .idle)
        #expect(await Self.first(of: signal.streams.updates()) == .idle, "at the start")

        var following = signal.streams.updates().makeAsyncIterator()
        #expect(await following.next() == .idle)
        signal.publish(.handshaken)
        signal.publish(.handshaken)
        signal.publish(.interrupted)
        #expect(signal.current == .interrupted)
        #expect(await following.next() == .handshaken)
        #expect(await following.next() == .interrupted, "the repeated value was not sent again")
        #expect(
            await Self.first(of: signal.streams.updates()) == .interrupted,
            "after two changes")

        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client()
        let firstHealth = await Self.first(of: client.healthUpdates())
        #expect(
            firstHealth == (await client.health), "a new client's stream starts with its health")
    }

    /// Subscribers register on the pool while an actor that owns a signal, as the client does,
    /// publishes a cycle of distinct values in one turn and then `terminal`. In each stream, every
    /// element after the first must be the next value of the cycle after the one before it, until
    /// `terminal`, which must follow the last value of the cycle published.
    ///
    /// Values repeat around the cycle, so this checks each step rather than a whole run. A
    /// reordering would put a value after its successor, which is not a step of a cycle longer
    /// than two. It cannot prove that the first element was the value at the instant of
    /// registration, only that whatever came first was followed by every later value in order.
    ///
    /// **What it does not catch (V2, the first value yielded outside the lock):** in
    /// `HealthObservers.stream()`, register and read the value now under the lock, and yield it
    /// after the lock is released. Run, debug: green in 10 of 10. It registers 200 streams, and a
    /// review counted 11 to 14 of them registering while the owner published, so the window, the
    /// few instructions between the release and the yield, is crossed rarely if at all. That, and
    /// a snapshot and a set in two lock sections (C1 and C2), are pinned by
    /// `aStormOfRegistrationsIsHandedEachValueAfterTheOneBeforeIt()`. What this test holds is
    /// the run: every stream is handed every later value, in order, once each. V1 above is red
    /// here in 3 of 3.
    @Test("A registration racing a run of publications is handed each later value, in order")
    func aRegistrationRacingPublicationsGetsEveryLaterValueInOrder() async {
        let owner = Owner()
        let runs = await withTaskGroup(of: [HelperConnectionHealth]?.self) { group in
            for _ in 0..<Self.subscribers {
                group.addTask {
                    var seen: [HelperConnectionHealth] = []
                    for await health in owner.streams.updates() {
                        seen.append(health)
                        if health == Self.terminal { break }
                    }
                    return seen
                }
            }
            group.addTask {
                await owner.publish(Self.published)
                return nil
            }
            var runs: [[HelperConnectionHealth]] = []
            for await run in group { if let run { runs.append(run) } }
            return runs
        }

        #expect(runs.count == Self.subscribers)
        let lastOfTheCycle = Self.cycle[Self.published % Self.cycle.count]
        let broken = runs.filter { run in
            guard run.last == Self.terminal else { return true }
            let steps = zip(run, run.dropFirst())
            return !steps.allSatisfy { before, after in
                after == Self.terminal
                    ? before == lastOfTheCycle
                    : after == Self.successor(of: before)
            }
        }
        #expect(
            broken.isEmpty,
            """
            \(broken.count) of \(runs.count) streams were handed a value out of order or not at \
            all; the first: \(broken.first.map { Array($0.prefix(8)) } ?? [])
            """)
    }

    /// Streams register in a loop on the pool while an actor that owns a signal makes one long run
    /// of publications in a single turn. Each stream takes two elements, and the second must be
    /// the one the signal published right after the first: the value at registration, then the
    /// next change, with nothing between them and nothing ahead of the first.
    ///
    /// **Why this and not the test above.** The window a wrong first yield or a split lock opens is
    /// a few instructions wide. The test above registers 200 streams in all, and a run of it
    /// registered 0 to 14 of them while the owner was publishing. This registers streams for as
    /// long as the owner publishes (`stormPublished`), `stormers` tasks at a time, so a window that
    /// narrow is crossed many times in one run. `midRun` counts the registrations that began
    /// after the run did, and the test requires `minimumMidRun` of them wherever tasks can run
    /// beside the owner's turn.
    ///
    /// The owner publishes only once every task has registered once, so none of them is a
    /// latecomer to a run already over. Every wait is on a task group's child or on a stream, all
    /// of which end when the test is cancelled, and a reader still waiting once the owner has
    /// finished is cancelled after `grace` and counted as `abandoned`, so a mutant that loses an
    /// element is a red and not a test that waits for it until the suite's time limit.
    ///
    /// **It runs in rounds.** In 2 of 6 full runs of this package's tests, a single round did not
    /// race: 0 of 16 and 10 of 26 registrations began while the owner was publishing, because the
    /// pool was busy with other tests and no stormer got a thread beside the owner's turn. A
    /// round that did not race starts another, with a new owner, until the rounds have or
    /// `rounds` are spent; a stream that was wrong, or abandoned, ends the test at once. Run with
    /// only the other storm, a round raced in 12 of 12 runs.
    ///
    /// **Mutations (debug, four sweeps of 5 runs each, all 20 red at `total.broken.isEmpty`):**
    /// - **V2, the first value yielded after the lock is released:** 60 to 701 of about 267,000 to
    ///   380,000 streams broken in a run, each a value followed by the one before it.
    /// - **C1, `HealthObservers.store(_:)` taking the observers in one `withLock` section and
    ///   setting the value in a second:** 40,561 to 51,404 of about 245,000 to 312,000, each a
    ///   value that skipped its successor. Three runs also left a stream waiting for an element
    ///   that never came, which `grace` cancelled and `abandoned` counted.
    /// - **C2, the same two sections with the value set first:** 13,668 to 23,268 of about
    ///   256,000 to 295,000, each a value followed by itself.
    ///
    /// Unmutated, debug, a run registers about 275,000 streams, about 229,000 of them counted
    /// mid-run (a lower bound: a registration at the cycle's first value is not counted), and none
    /// is broken. `LeaseDriverPublisherRaceTests` has the same test for the lease driver's
    /// publisher.
    @Test("A storm of registrations is handed each value right after the one before it")
    func aStormOfRegistrationsIsHandedEachValueAfterTheOneBeforeIt() async {
        let total = await Self.stormUntilItRaces()

        #expect(
            total.abandoned == 0,
            "\(total.abandoned) streams never got a second element, and were cancelled")
        #expect(
            total.broken.isEmpty,
            """
            \(total.brokenCount) of \(total.registrations) streams were not handed the value \
            after their first as their second; the first few (first, second): \(total.broken)
            """)
        if Self.canRaceThePublisher {
            #expect(
                total.midRun >= Self.minimumMidRun,
                """
                only \(total.midRun) of \(total.registrations) registrations began while the owner \
                was publishing, in \(total.rounds) rounds, so this run did not race it
                """)
        }
    }

    // MARK: - Support

    /// How many streams race the publications.
    static let subscribers = 200

    /// How many values of the cycle the owner publishes after its first.
    static let published = 2_000

    /// Distinct values, published in this order and round again, so no publication repeats the
    /// value before it and none is dropped as unchanged. The signal starts at the first.
    static let cycle: [HelperConnectionHealth] = [
        .idle, .handshaken, .unresponsive, .interrupted, .invalidated, .refused,
    ]

    /// What the owner publishes last, which is on no step of the cycle.
    static let terminal = HelperConnectionHealth.versionMismatched

    static func successor(of health: HelperConnectionHealth) -> HelperConnectionHealth? {
        cycle.firstIndex(of: health).map { cycle[($0 + 1) % cycle.count] }
    }

    /// A signal owned by an actor, as `HelperClient` owns its own, so every publication runs on
    /// that actor and the streams are reached from anywhere.
    actor Owner {
        private let signal: HealthSignal
        nonisolated let streams: HealthSignal.Streams

        init() {
            let signal = HealthSignal(startingWith: HealthSignalTests.cycle[0])
            self.signal = signal
            streams = signal.streams
        }

        /// Publishes the next `count` values of the cycle, then `terminal`, in one turn.
        func publish(_ count: Int) {
            let cycle = HealthSignalTests.cycle
            for step in 1...count { signal.publish(cycle[step % cycle.count]) }
            signal.publish(HealthSignalTests.terminal)
        }
    }

    // MARK: - The storm

    /// How many tasks register streams at once.
    static let stormers = 8

    /// How many values of the cycle the owner publishes in the storm's single turn.
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

    /// How many rounds the storm may take to race the owner once.
    static let rounds = 5

    /// How long a stormer may wait for an element after the owner has finished, before it is
    /// cancelled and counted as abandoned.
    static let grace: Duration = .seconds(10)

    /// How many steps the owner waits for the stormers to register once, and how long each is.
    static let patience = 5_000
    static let step: Duration = .milliseconds(1)

    /// Runs the storm in rounds, each against a new owner, until the rounds so far have raced
    /// `minimumMidRun` registrations, a stream was wrong or abandoned, `rounds` are spent, or the
    /// pool cannot race the owner at all.
    static func stormUntilItRaces() async -> Tally {
        var total = Tally()
        for _ in 0..<rounds {
            total.add(await stormRegistrations(against: Owner()))
            total.rounds += 1
            let settled = total.brokenCount > 0 || total.abandoned > 0
            let raced = !canRaceThePublisher || total.midRun >= minimumMidRun
            if settled || raced { break }
        }
        return total
    }

    /// Runs one round of the storm: `stormers` tasks register streams against `owner` while it
    /// publishes `stormPublished` values in one turn, and what they found, added up.
    static func stormRegistrations(against owner: Owner) async -> Tally {
        let registered = Counter()
        return await withTaskGroup(of: StormOutcome.self) { group in
            for _ in 0..<stormers {
                group.addTask { .stormer(await storm(against: owner, counting: registered)) }
            }
            group.addTask {
                // Bounded by steps as well as by cancellation, so a stormer that cannot start does
                // not hold the owner back for ever.
                var waited = 0
                while registered.value < stormers, waited < patience {
                    do { try await Task.sleep(for: step) } catch { return .published }
                    waited += 1
                }
                await owner.publish(stormPublished)
                return .published
            }
            var total = Tally()
            var stormersLeft = stormers
            for await outcome in group {
                switch outcome {
                case .stormer(let tally):
                    total.add(tally)
                    stormersLeft -= 1
                    if stormersLeft == 0 { group.cancelAll() }
                case .published:
                    if stormersLeft > 0 {
                        group.addTask {
                            try? await Task.sleep(for: grace)
                            return .graceEnded
                        }
                    }
                case .graceEnded:
                    group.cancelAll()
                }
            }
            return total
        }
    }

    /// Registers streams one after another until it sees `terminal` first or is cancelled, taking
    /// two elements of each and checking the second against the first.
    static func storm(against owner: Owner, counting registered: Counter) async -> Tally {
        var tally = Tally()
        var counted = false
        while !Task.isCancelled {
            var stream = owner.streams.updates().makeAsyncIterator()
            guard let first = await stream.next() else {
                tally.abandoned += 1
                break
            }
            tally.registrations += 1
            if !counted {
                counted = true
                registered.increment()
            }
            if first == terminal { break }
            if first != cycle[0] { tally.midRun += 1 }
            guard let second = await stream.next() else {
                tally.abandoned += 1
                break
            }
            let next =
                second == terminal
                ? first == cycle[stormPublished % cycle.count] : second == successor(of: first)
            if !next { tally.record(broken: "\(first) then \(second)") }
            if second == terminal { break }
        }
        return tally
    }

    /// What the stormers found, added across them.
    struct Tally: Sendable {
        var registrations = 0
        var midRun = 0
        var abandoned = 0
        var rounds = 0
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
            rounds += other.rounds
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
    static func first(
        of stream: AsyncStream<HelperConnectionHealth>
    ) async -> HelperConnectionHealth? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
