import SMCCore
import Testing

/// A `SensorProvider` that parks **each direct read** at its first step until the test lets the
/// oldest one go, wrapping a `FakeSensorProvider` for the answers.
///
/// `GatedSensorProvider` holds every subset read and lets them all go together. This one exists
/// for two direct reads in flight at once (#485 S1): `stop()` then `start()` while a tick is
/// suspended in its read, with the test choosing which of the two lands first.
///
/// The gate is `isAvailable`, because a direct read asks it once, before any key is read
/// (`SMCFanEnumeration.enumerate(provider:)`, which `FanPoller` runs first), so one parked
/// `isAvailable` is one parked tick. `readsStarted` counts them, so a test can see that.
actor ParkedReadProvider: SensorProvider {
    nonisolated let identifier = "parked"

    private let inner: FakeSensorProvider
    private var parked: [CheckedContinuation<Void, Never>] = []

    /// Direct reads that have reached the gate, parked or let go.
    private(set) var readsStarted = 0

    /// Direct reads parked at the gate now.
    var parkedCount: Int { parked.count }

    init(inner: FakeSensorProvider) {
        self.inner = inner
    }

    var isAvailable: Bool {
        get async {
            readsStarted += 1
            await withCheckedContinuation { parked.append($0) }
            return await inner.isAvailable
        }
    }

    func readAll() async throws -> [SensorReading] {
        try await inner.readAll()
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        try await inner.read(keys: keys)
    }

    /// Lets the read that reached the gate first go on.
    func releaseOldest() {
        guard !parked.isEmpty else {
            Issue.record("the test let a direct read go, and none is parked")
            return
        }
        parked.removeFirst().resume()
    }

    /// Lets every parked read go: the end of a test, so no tick is left parked here.
    func releaseAll() {
        let all = parked
        parked = []
        for continuation in all { continuation.resume() }
    }
}
