import Foundation
import Testing
import os

@testable import AeolusLeaseControl

/// A `LeaseDriverPublisher`'s registrations racing its publications on threads of their own, not
/// on the cooperative pool (#541): the first value is yielded under the lock, and a publication
/// stores its value and takes its observers in one section. `HealthSignalThreadRaceTests` is the
/// same test for the health signal, and says why threads, why it is bounded and why it is sized
/// as it is. Run alone on the development machine, in debug, this takes 0.30 s and about 0.8
/// CPU-s (release: 0.24 s, about 0.5 CPU-s).
@Suite(
    "LeaseDriverPublisher — registrations on their own threads race a publisher on its own",
    .timeLimit(.minutes(1)))
struct LeaseDriverPublisherThreadRaceTests {

    /// How many threads register streams at once, beside the one that publishes; the even ones
    /// follow reports and the odd ones states.
    static let registrars = 4

    /// How many streams each registrar makes in a burst, and keeps until the burst is checked.
    static let registrationsEach = 8

    /// The longest pause between two registrations, in clock reads.
    static let jitter = 64

    /// How many bursts a run makes, each against a new publisher. 1,400 take about 0.3 s in
    /// debug. Other shapes tried (3 or 6 registrars, 16 streams a registrar over 700 bursts or 4
    /// over 2,800, jitter 16 or 256) broke 23 to 57 streams a second under V2 against this one's
    /// 39, so the shape is the reviewer's and only the count was chosen.
    static let bursts = 1_400

    /// How many changes a burst publishes at most while its registrars are at work.
    static let publicationCap = 2_000

    /// How many registrations must have followed a move of the publisher, over the run, for the
    /// run to have raced it at all. Alone, in debug, a run makes 17,216 to 18,361, so the floor is
    /// 8.7% of the fewest; on a pool of one thread 17,970 to 18,308; beside 13 busy loops 8,625 to
    /// 12,391 (17% of the fewest). A floor of 10,000,000 fails every run and prints these.
    static let minimumInterleaved = 1_500

    /// Streams of both kinds made on registrar threads while a thread that owns a publisher
    /// publishes changes of state, each acquiring the next fan. Each stream's second element must
    /// carry the fan after its first's.
    ///
    /// **Mutations (debug, two sweeps of 5 runs each, all 10 red at `total.broken.isEmpty`;
    /// broken streams of 44,800 a run):**
    /// - **V2, the first value yielded after the lock is released:** 5 to 16. Release, 3 runs:
    ///   6 to 10. A pool of one thread, 3 runs: 7 to 9. Beside 13 busy loops, 5 runs: 13 to 22.
    ///   Sixteen more runs at this size while choosing it: 2 to 20, all red.
    /// - **C1, `Followers.store(_:)` taking the observers in one `withLock` section and setting
    ///   the value in a second:** 2,547 to 2,810.
    /// - **C2, the same two sections with the value set first:** 1,633 to 1,816.
    @Test("Registrations on threads of their own are each handed the change after their first")
    func registrationsOnTheirOwnThreadsAreHandedTheChangeAfterTheirFirst() async {
        var total = Tally()
        for _ in 0..<Self.bursts { total.add(await Self.burst()) }

        #expect(
            total.broken.isEmpty,
            """
            \(total.brokenCount) of \(total.registrations) streams were not handed the change \
            after their first as their second; the first few (first, second): \(total.broken)
            """)
        #expect(
            total.interleaved >= Self.minimumInterleaved,
            """
            only \(total.interleaved) of \(total.registrations) registrations followed a move of \
            the publisher (\(Self.minimumInterleaved) needed), in \(total.publications) \
            publications, so the threads did not race
            """)
    }

    // MARK: - A burst

    /// The fan number a change of state carries, or `nil` for any other state.
    static func fan(of state: LeaseDriverState) -> Int? {
        guard case .acquiring(let fans) = state else { return nil }
        return fans.first
    }

    /// One burst against a new publisher, checked once its threads are done.
    static func burst() async -> Tally {
        let shared = Burst()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            shared.whenFinished(finished, threads: registrars + 1)
            start { publish(shared) }
            for index in 0..<registrars {
                start { register(shared, reports: index.isMultiple(of: 2)) }
            }
        }
        var tally = Tally(publications: shared.publications)
        for made in shared.collected {
            var previous: Int?
            // Both elements of each are buffered: two publications followed every registration.
            for stream in made.states {
                var elements = stream.makeAsyncIterator()
                let first = await elements.next().flatMap(fan(of:))
                tally.check(first, then: await elements.next().flatMap(fan(of:)), after: &previous)
            }
            for stream in made.reports {
                var elements = stream.makeAsyncIterator()
                let first = await elements.next().flatMap { fan(of: $0.state) }
                let second = await elements.next().flatMap { fan(of: $0.state) }
                tally.check(first, then: second, after: &previous)
            }
        }
        return tally
    }

    static func start(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The publisher's thread. The publisher is made here and never leaves it, as a driver's
    /// never leaves the driver's actor; only its `Streams` reach the registrars.
    static func publish(_ shared: Burst) {
        let publisher = LeaseDriverPublisher(startingWith: LeaseDriverPublisherTests.report(0))
        shared.offer(publisher.streams)
        var step = 0
        while !shared.registrarsDone, step < publicationCap {
            step += 1
            publisher.publishStateChange(LeaseDriverPublisherTests.report(step))
        }
        shared.waitForRegistrars()
        for _ in 0..<2 {
            step += 1
            publisher.publishStateChange(LeaseDriverPublisherTests.report(step))
        }
        shared.finish(publications: step)
    }

    /// A registrar's thread: `registrationsEach` streams of one kind, each after a pause of
    /// random length.
    static func register(_ shared: Burst, reports: Bool) {
        let streams = shared.waitForStreams()
        var made = Made()
        var random = SystemRandomNumberGenerator()
        for _ in 0..<registrationsEach {
            for _ in 0..<Int.random(in: 0...jitter, using: &random) { _ = mach_absolute_time() }
            if reports {
                made.reports.append(streams.reportUpdates())
            } else {
                made.states.append(streams.stateUpdates())
            }
        }
        shared.deposit(made)
    }

    /// The streams one registrar made.
    struct Made: Sendable {
        var states: [AsyncStream<LeaseDriverState>] = []
        var reports: [AsyncStream<LeaseDriverReport>] = []
    }

    /// What the threads of one burst share, under a lock, and the condition they wait on.
    final class Burst: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: BurstState())
        private let condition = NSCondition()

        func whenFinished(_ finished: CheckedContinuation<Void, Never>, threads: Int) {
            state.withLock {
                $0.finished = finished
                $0.threadsLeft = threads
            }
        }

        func offer(_ streams: LeaseDriverPublisher.Streams) {
            signalling { $0.streams = streams }
        }

        func waitForStreams() -> LeaseDriverPublisher.Streams {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let streams = state.withLock({ $0.streams }) { return streams }
                condition.wait()
            }
        }

        var registrarsDone: Bool { state.withLock { $0.registrarsLeft == 0 } }

        func deposit(_ made: Made) {
            signalling {
                $0.collected.append(made)
                $0.registrarsLeft -= 1
            }
            finishThread()
        }

        func waitForRegistrars() {
            condition.lock()
            while !registrarsDone { condition.wait() }
            condition.unlock()
        }

        func finish(publications: Int) {
            state.withLock { $0.publications = publications }
            finishThread()
        }

        var collected: [Made] { state.withLock { $0.collected } }
        var publications: Int { state.withLock { $0.publications } }

        private func signalling(_ change: @Sendable (inout BurstState) -> Void) {
            condition.lock()
            state.withLock(change)
            condition.broadcast()
            condition.unlock()
        }

        /// The last thread of the burst to finish resumes the test.
        private func finishThread() {
            let finished = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.threadsLeft -= 1
                return state.threadsLeft == 0 ? state.finished : nil
            }
            finished?.resume()
        }
    }

    /// What the bursts found, added across them.
    struct Tally: Sendable {
        var publications = 0
        var registrations = 0
        var interleaved = 0
        var brokenCount = 0
        /// The first few streams that were wrong, as text.
        var broken: [String] = []

        /// Records one stream's first two fans, and whether the publisher moved since the
        /// registration before it on the same thread.
        mutating func check(_ first: Int?, then second: Int?, after previous: inout Int?) {
            guard let first, let second else {
                record(broken: "a stream ended, or carried no fan")
                return
            }
            registrations += 1
            if let previous, previous != first { interleaved += 1 }
            previous = first
            if second != first + 1 { record(broken: "\(first) then \(second)") }
        }

        mutating func record(broken example: String) {
            brokenCount += 1
            if broken.count < 3 { broken.append(example) }
        }

        mutating func add(_ other: Tally) {
            publications += other.publications
            registrations += other.registrations
            interleaved += other.interleaved
            brokenCount += other.brokenCount
            for example in other.broken where broken.count < 3 { broken.append(example) }
        }
    }
}

/// What the threads of one burst share. At file scope so that `Burst` is the only type nested in
/// the suite.
private struct BurstState {
    var streams: LeaseDriverPublisher.Streams?
    var collected: [LeaseDriverPublisherThreadRaceTests.Made] = []
    var registrarsLeft = LeaseDriverPublisherThreadRaceTests.registrars
    var threadsLeft = 0
    var publications = 0
    var finished: CheckedContinuation<Void, Never>?
}
