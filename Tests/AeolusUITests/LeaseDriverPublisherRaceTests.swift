import Foundation
import Testing
import os

@testable import AeolusLeaseControl

/// A storm of registrations against one long turn of publications of a `LeaseDriverPublisher`
/// (#541): the first value is yielded under the lock, and a publication stores its value and takes
/// its observers in one section. `LeaseDriverPublisherTests` holds what a new observer is handed
/// in the plain cases; the storm loops make a window a few instructions wide something a run
/// crosses many times.
///
/// The loops are bounded by cancellation, and by `grace` and `patience`, so a mutant that loses an
/// element is a red and not a hang.
@Suite(
    "LeaseDriverPublisher — registrations racing a long run of publications",
    .timeLimit(.minutes(1)))
struct LeaseDriverPublisherRaceTests {

    typealias Owner = LeaseDriverPublisherTests.Owner

    /// Streams register in a loop on the pool while an actor that owns a publisher makes one long
    /// run of publications in a single turn. Each stream takes two elements, and the second must
    /// be the change published right after the first: the value at registration, then the next
    /// change, with nothing between them and nothing ahead of the first.
    ///
    /// **Why this and not `LeaseDriverPublisherTests`' run test.** The window a wrong first yield
    /// or a split lock opens is a few instructions wide. That test registers 200 streams in all,
    /// and a run of it registered 0 to 10 of them while the owner was publishing. This registers
    /// streams for as long as the owner publishes (`stormPublished`), `stormers` tasks at a time,
    /// half of each kind, so a window that narrow is crossed many times in one run. `midRun`
    /// counts the registrations that began after the run did, and the test requires
    /// `minimumMidRun` of them wherever tasks can run beside the owner's turn.
    ///
    /// The owner publishes only once every task has registered once, so none of them is a
    /// latecomer to a run already over. Every wait is on a task group's child or on a stream, all
    /// of which end when the test is cancelled, and a reader still waiting once the owner has
    /// finished is cancelled after `grace` and counted as `abandoned`, so a mutant that loses an
    /// element is a red and not a test that waits for it until the suite's time limit.
    ///
    /// **It runs in rounds.** The health signal's storm, which this one mirrors, did not race in
    /// a single round in 2 of 6 full runs of this package's tests: 0 of 16 and 10 of 26
    /// registrations began while the owner was publishing, because the pool was busy with other
    /// tests and no stormer got a thread beside the owner's turn. A round that did not race
    /// starts another, with a new owner, until the rounds have or `rounds` are spent; a stream
    /// that was wrong, or abandoned, ends the test at once. Run with only the other storm, a
    /// round raced in 12 of 12 runs.
    ///
    /// **Mutations (debug, three sweeps of 5 runs each, all 15 red at `total.broken.isEmpty`):**
    /// - **V2, the first value yielded after the lock is released:** 151 to 286 of about 480,000
    ///   to 562,000 streams broken in a run, each a change followed by the one before it.
    /// - **C1, `Followers.store(_:)` taking the observers in one `withLock` section and setting
    ///   the value in a second:** 6,178 to 22,518 of about 145,000 to 531,000, each a change
    ///   that skipped its successor. One run also left a stream waiting for an element that never
    ///   came, which `grace` cancelled and `abandoned` counted.
    /// - **C2, the same two sections with the value set first:** 13,457 to 18,096 of about
    ///   490,000 to 536,000, each a change followed by itself.
    ///
    /// Unmutated, debug, a run registers about 490,000 to 500,000 streams, all but a few of them
    /// mid-run, and none is broken. `HealthSignalTests` has the same test for the health signal.
    @Test("A storm of registrations is handed each change right after the one before it")
    func aStormOfRegistrationsIsHandedEachChangeAfterTheOneBeforeIt() async {
        let total = await Self.stormUntilItRaces()

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
                was publishing, in \(total.rounds) rounds, so this run did not race it
                """)
        }
    }

    // MARK: - Support

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

    /// How many rounds the storm may take to race the owner once.
    static let rounds = 5

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

    /// Runs one round of the storm: `stormers` tasks register streams of `owner`'s publisher,
    /// half of each kind, while it publishes `stormPublished` changes in one turn, and what they
    /// found, added up.
    static func stormRegistrations(against owner: Owner) async -> Tally {
        let registered = Counter()
        return await withTaskGroup(of: StormOutcome.self) { group in
            for index in 0..<stormers {
                group.addTask {
                    .stormer(
                        index.isMultiple(of: 2)
                            ? await storm(
                                owner.streams.reportUpdates, fan: { fan(of: $0.state) },
                                counting: registered)
                            : await storm(
                                owner.streams.stateUpdates, fan: fan(of:), counting: registered))
                }
            }
            group.addTask {
                // Bounded by steps as well as by cancellation, so a stormer that cannot start does
                // not hold the owner back for ever.
                var waited = 0
                while registered.value < stormers, waited < patience {
                    do { try await Task.sleep(for: step) } catch { return .published }
                    waited += 1
                }
                await owner.publish(through: stormPublished)
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
}
