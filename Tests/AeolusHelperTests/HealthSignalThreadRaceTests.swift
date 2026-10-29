import Foundation
import Testing
import os

@testable import AeolusXPCClient

/// A signal's registrations racing its publications on threads of their own, not on the
/// cooperative pool (#541): the first value is yielded under the lock, and a publication stores
/// its value and takes its observers in one section.
///
/// **Why threads.** The windows a wrong first yield (V2) or a split lock (C1, C2) opens are a few
/// instructions wide, so only a race between two threads that run at the same moment crosses
/// them. On the cooperative pool that needs a free pool thread beside the publisher's turn,
/// which a loaded runner does not have: the pool storm this replaces raced 67 registrations of
/// 156 in 5 rounds on CI, which runs every test in one process on a pool of three threads, and
/// failed its floor (run 40805903008). A `Thread` is scheduled by the kernel, so these race on a
/// pool of any width, one thread included.
///
/// **Bounded by construction, not by cancellation.** Each registrar makes `registrationsEach`
/// streams and stops. The publisher publishes until every registrar has stopped, or
/// `publicationCap`, then waits for them without spinning and publishes twice more, so every
/// stream has at least two elements buffered before anything reads one. Reading them afterwards
/// waits on nothing, and no thread loops on a condition another must make true.
///
/// **Sized to cost about 0.3 s** (`bursts`), because it keeps `registrars + 1` threads busy for
/// that long, which on a runner with three cores is the whole machine, beside tests that are
/// bounded by the wall clock. Run alone on the development machine, in debug, it takes 0.28 to
/// 0.29 s and about 0.7 CPU-s (release: 0.22 s, about 0.5 CPU-s). A bigger run kills V2, the
/// rare one, more often, and costs that much more.
@Suite(
    "HealthSignal — registrations on their own threads race a publisher on its own",
    .timeLimit(.minutes(1)))
struct HealthSignalThreadRaceTests {

    /// How many threads register streams at once, beside the one that publishes.
    static let registrars = 4

    /// How many streams each registrar makes in a burst, and keeps until the burst is checked.
    static let registrationsEach = 8

    /// The longest pause between two registrations, in clock reads, so each meets the publisher
    /// at a phase of its own.
    static let jitter = 64

    /// How many bursts a run makes, each against a new signal. 1,400 take about 0.3 s in debug;
    /// 800 already killed V2 in 10 of 10 runs, with as few as 1 broken stream, and 4,800 take a
    /// second.
    static let bursts = 1_400

    /// How many publications a burst makes at most while its registrars are at work. A burst
    /// needs about 60; this bounds what a registrar the scheduler starves can cost.
    static let publicationCap = 2_000

    /// How many registrations must have followed a move of the publisher, over the run, for the
    /// run to have raced it at all. Alone, in debug, a run makes 25,635 to 26,679, so the floor is
    /// 5.9% of the fewest; on a pool of one thread 25,958 to 26,128; beside 13 busy loops 18,252
    /// to 19,985 (8.2% of the fewest). A floor of 10,000,000 fails every run and prints these.
    static let minimumInterleaved = 1_500

    /// Streams made on registrar threads while a thread that owns a signal publishes a cycle of
    /// distinct values. Each stream's second element must be the value published right after
    /// its first: the value at registration, then the next change, with nothing between them
    /// and nothing ahead of the first.
    ///
    /// **Mutations (debug, two sweeps of 5 runs each, all 10 red at `total.broken.isEmpty`;
    /// broken streams of 44,800 a run):**
    /// - **V2, the first value yielded after the lock is released:** 10 to 24. Release, 3 runs:
    ///   19 to 26. A pool of one thread, 3 runs: 14 to 16. Beside 13 busy loops, 5 runs: 19 to 29.
    ///   Ten more runs at this size while choosing it: 15 to 115.
    /// - **C1, `HealthObservers.store(_:)` taking the observers in one `withLock` section and
    ///   setting the value in a second:** 8,268 to 9,575.
    /// - **C2, the same two sections with the value set first:** 2,913 to 3,974.
    @Test("Registrations on threads of their own are each handed the value after their first")
    func registrationsOnTheirOwnThreadsAreHandedTheValueAfterTheirFirst() async {
        var total = Tally()
        for _ in 0..<Self.bursts { total.add(await Self.burst()) }

        #expect(
            total.broken.isEmpty,
            """
            \(total.brokenCount) of \(total.registrations) streams were not handed the value \
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

    /// One burst against a new signal, checked once its threads are done.
    static func burst() async -> Tally {
        let shared = Burst()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            shared.whenFinished(finished, threads: registrars + 1)
            start { publish(shared) }
            for _ in 0..<registrars { start { register(shared) } }
        }
        var tally = Tally(publications: shared.publications)
        for streams in shared.collected {
            var previous: HelperConnectionHealth?
            for stream in streams {
                var elements = stream.makeAsyncIterator()
                // Both are buffered: two publications followed every registration.
                guard let first = await elements.next(), let second = await elements.next() else {
                    tally.record(broken: "a stream ended")
                    continue
                }
                tally.registrations += 1
                if let previous, previous != first { tally.interleaved += 1 }
                previous = first
                if second != HealthSignalTests.successor(of: first) {
                    tally.record(broken: "\(first) then \(second)")
                }
            }
        }
        return tally
    }

    static func start(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The publisher's thread. The signal is made here and never leaves it, as a client's never
    /// leaves the client's actor; only its `Streams` reach the registrars.
    static func publish(_ shared: Burst) {
        let cycle = HealthSignalTests.cycle
        let signal = HealthSignal(startingWith: cycle[0])
        shared.offer(signal.streams)
        var step = 0
        while !shared.registrarsDone, step < publicationCap {
            step += 1
            signal.publish(cycle[step % cycle.count])
        }
        shared.waitForRegistrars()
        for _ in 0..<2 {
            step += 1
            signal.publish(cycle[step % cycle.count])
        }
        shared.finish(publications: step)
    }

    /// A registrar's thread: `registrationsEach` streams, each after a pause of random length.
    static func register(_ shared: Burst) {
        let streams = shared.waitForStreams()
        var made: [AsyncStream<HelperConnectionHealth>] = []
        var random = SystemRandomNumberGenerator()
        for _ in 0..<registrationsEach {
            for _ in 0..<Int.random(in: 0...jitter, using: &random) { _ = mach_absolute_time() }
            made.append(streams.updates())
        }
        shared.deposit(made)
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

        func offer(_ streams: HealthSignal.Streams) {
            signalling { $0.streams = streams }
        }

        func waitForStreams() -> HealthSignal.Streams {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let streams = state.withLock({ $0.streams }) { return streams }
                condition.wait()
            }
        }

        var registrarsDone: Bool { state.withLock { $0.registrarsLeft == 0 } }

        func deposit(_ made: [AsyncStream<HelperConnectionHealth>]) {
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

        var collected: [[AsyncStream<HelperConnectionHealth>]] { state.withLock { $0.collected } }
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
    var streams: HealthSignal.Streams?
    var collected: [[AsyncStream<HelperConnectionHealth>]] = []
    var registrarsLeft = HealthSignalThreadRaceTests.registrars
    var threadsLeft = 0
    var publications = 0
    var finished: CheckedContinuation<Void, Never>?
}
