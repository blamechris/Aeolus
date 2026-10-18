import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The scheduler's count of lane requests outstanding returns to zero however a request ends, and
/// its report re-arms only on a new maximum (ADR 0012's 2026-10-18 amendment).
///
/// The count is what the run-time overlap report reads, so a count that leaks reports overlaps
/// that never happened and one that runs negative hides overlaps that did. Each test here runs
/// one way a request can end on a **fresh** scheduler — a read the provider really throws from, a
/// read longer than one turn, a request cancelled while it queues — and then puts the scheduler
/// through the same check (`expectTheCountAtRest(on:)`): requests one after another report
/// nothing, and a genuine overlapping pair reports once. Fresh, because a report re-arms only on a
/// new maximum: on a scheduler that had already reported a pair, a leak of one would make the next
/// sequential request a pair that reports nothing.
@Suite(
    "The lane's outstanding count returns to zero, and re-arms on a new maximum",
    .timeLimit(.minutes(1)))
struct ThermalCycleLaneCounterTests {

    /// A fresh scheduler, the provider it reads through, and what it reported.
    private struct Rig {
        let observer = RecordingSchedulerObserver()
        let provider = LaneCounterProvider()
        let scheduler: SMCReadScheduler

        init() {
            scheduler = SMCReadScheduler(provider: provider, observer: observer)
        }

        var overlaps: [Int] { ThermalCycleLaneOverlapTests.overlaps(in: observer.events) }

        /// Every report, as its `outstanding` and `overlappingArrivals`.
        var reports: [[Int]] {
            observer.events.compactMap { event in
                if case .thermalCycleLaneOverlapped(let outstanding, let arrivals) = event {
                    return [outstanding, arrivals]
                }
                return nil
            }
        }

        /// `count` lane requests outstanding at once: the first holding the connection inside the
        /// provider, the rest queued in the lane behind it, then all of them answered.
        func overlap(_ count: Int) async throws {
            await provider.hold()
            let first = observing { try await scheduler.read(keys: ["A"], at: .thermalCycle) }
            await yieldUntil("a lane read to hold the connection") {
                await provider.heldReads == 1
            }
            var queued: [ObservableWork<[SensorReadOutcome]>] = []
            for index in 1..<count {
                queued.append(
                    observing { try await scheduler.read(keys: ["Q\(index)"], at: .thermalCycle) })
                await yieldUntil("lane request \(index) to queue") {
                    await scheduler.queuedTurns(at: .thermalCycle) == index
                }
            }
            await provider.release()
            _ = try await finished("the lane read holding the connection", first)
            for (index, read) in queued.enumerated() {
                _ = try await finished("queued lane read \(index)", read)
            }
        }
    }

    /// After whatever the test did: three lane requests one after another report nothing, and an
    /// overlapping pair reports once. Called on a scheduler that has reported nothing yet.
    private static func expectTheCountAtRest(
        on rig: Rig, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        #expect(rig.overlaps.isEmpty, "reported before the check", sourceLocation: sourceLocation)
        for index in 0..<3 {
            _ = try await rig.scheduler.read(keys: ["S\(index)"], at: .thermalCycle)
        }
        #expect(
            rig.overlaps.isEmpty,
            "requests one after another reported an overlap: the count leaked",
            sourceLocation: sourceLocation)
        try await rig.overlap(2)
        #expect(
            rig.overlaps == [2],
            "a genuine pair reported \(rig.overlaps): the count is not at zero",
            sourceLocation: sourceLocation)
    }

    /// A lane read the provider throws from is counted out by the `defer` that releases its turn.
    ///
    /// **Mutation:** count a lane request out on the read's success path rather than in
    /// `endTurn(at:)`. Run: red — the thrown read leaks one, and the sequential requests report.
    @Test("A lane read that throws is counted out")
    func aLaneReadThatThrowsIsCountedOut() async throws {
        let rig = Rig()
        await rig.provider.throwOnNextRead()
        await #expect(throws: LaneCounterProvider.Thrown.self) {
            try await rig.scheduler.read(keys: ["T0"], at: .thermalCycle)
        }
        try await Self.expectTheCountAtRest(on: rig)
    }

    /// A lane read of 65 keys is two turns and one request: counted in once and out once, and
    /// never reported as an overlap with itself.
    ///
    /// **Mutation:** in `yieldTurn(at:)`, count a lane request out as well. Run: red — the count
    /// runs negative and the genuine pair reports nothing.
    /// **Mutation:** in `yieldTurn(at:)`, count each slice in as a new request. Run: red — the lone
    /// read reports an overlap.
    @Test("A lane read longer than one turn is one request")
    func aLaneReadLongerThanOneTurnIsOneRequest() async throws {
        let rig = Rig()
        let keys = (0...SMCReadScheduler.maxKeysPerTurn).map { "K\($0)" }
        let outcomes = try await rig.scheduler.read(keys: keys, at: .thermalCycle)
        #expect(outcomes.count == keys.count)
        #expect(await rig.provider.reads == 2, "the read was not two turns")
        try await Self.expectTheCountAtRest(on: rig)
    }

    /// A lane request cancelled while it queues behind a supervisor turn is still admitted — the
    /// gate is not cancellable — and still counted out.
    ///
    /// **Mutation:** in `endTurn(at:)`, do not count a lane request out. Run: red.
    @Test("A lane request cancelled while it queues is counted out")
    func aCancelledLaneRequestIsCountedOut() async throws {
        let rig = Rig()
        await rig.provider.hold()
        let supervisor = observing { try await rig.scheduler.read(keys: ["U"], at: .supervisor) }
        await yieldUntil("a supervisor read to hold the connection") {
            await rig.provider.heldReads == 1
        }
        let lane = Task { try await rig.scheduler.read(keys: ["C"], at: .thermalCycle) }
        await yieldUntil("the lane request to queue") {
            await rig.scheduler.queuedTurns(at: .thermalCycle) == 1
        }
        lane.cancel()
        await rig.provider.release()
        _ = try await finished("the supervisor read", supervisor)
        _ = await lane.result
        try await Self.expectTheCountAtRest(on: rig)
    }

    /// The report re-arms on a new maximum and on nothing else. A pair reports; the same pair
    /// again does not; three at once report again, carrying every overlapping arrival so far.
    ///
    /// **Mutation:** report every overlapping arrival (drop the new-maximum guard). Run: red — the
    /// second pair reports.
    /// **Mutation:** latch the report after the first. Run: red — the triple does not report.
    @Test("The overlap report re-arms on a new maximum, with the arrivals so far")
    func theReportReArmsOnANewMaximum() async throws {
        let rig = Rig()
        try await rig.overlap(2)
        #expect(rig.reports == [[2, 1]], "\(rig.reports)")
        try await rig.overlap(2)
        #expect(rig.reports == [[2, 1]], "the same overlap again reported: \(rig.reports)")
        try await rig.overlap(3)
        #expect(rig.reports == [[2, 1], [3, 4]], "\(rig.reports)")
    }
}

/// A provider that throws from its next read when asked, and holds every read when asked until it
/// is released. An actor that suspends, so a held read really holds the connection while other
/// requests reach the scheduler.
actor LaneCounterProvider: SensorProvider {

    struct Thrown: Error {}

    nonisolated let identifier = "lane-counter"

    private var throwsNext = false
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    /// Reads that reached this provider, held or not.
    private(set) var reads = 0

    /// Reads waiting inside this provider for `release()`.
    var heldReads: Int { held.count }

    var isAvailable: Bool {
        get async { true }
    }

    func throwOnNextRead() { throwsNext = true }

    func hold() { holding = true }

    func release() {
        holding = false
        let waiting = held
        held = []
        for waiter in waiting { waiter.resume() }
    }

    func readAll() async throws -> [SensorReading] { [] }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        reads += 1
        if throwsNext {
            throwsNext = false
            throw Thrown()
        }
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        return keys.map { SensorReadOutcome(key: $0, result: .reading($0, 44, kind: .unknown)) }
    }
}
