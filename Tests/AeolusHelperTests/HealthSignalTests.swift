import Foundation
import Testing

@testable import AeolusXPCClient

/// What a new observer of `HealthSignal` is handed first, and how a registration that races a
/// publication orders against it (#541).
///
/// Since #541 an observer of `HelperClient.healthUpdates()` registers in the step that makes its
/// stream, on whatever thread that is, and not on the client's actor. So its first element is the
/// value the signal holds. A registration that runs while the client publishes must still hand
/// its stream the value then and every later one, in order and once each; the thread race test is
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
    /// `HealthSignalThreadRaceTests`, which races threads of their own. What this test holds is
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

    /// The first element of `stream`. It always has one: registering yields the value now.
    static func first(
        of stream: AsyncStream<HelperConnectionHealth>
    ) async -> HelperConnectionHealth? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
