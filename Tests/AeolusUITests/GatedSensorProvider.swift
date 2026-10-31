import SMCCore

/// A `SensorProvider` whose subset reads can be **held** until the test lets them go, wrapping a
/// `FakeSensorProvider` for the answers.
///
/// It exists for one interleaving: a tick that is reading the SMC directly, suspended inside
/// that read, while the authority watch takes a step. A provider that answers at once leaves
/// no such moment to observe.
actor GatedSensorProvider: SensorProvider {
    nonisolated let identifier = "gated"

    private let inner: FakeSensorProvider
    private var holding = true
    private var held: [CheckedContinuation<Void, Never>] = []

    /// Subset reads that have reached the gate, held or not.
    private(set) var readsStarted = 0

    init(inner: FakeSensorProvider) {
        self.inner = inner
    }

    var isAvailable: Bool {
        get async { await inner.isAvailable }
    }

    func readAll() async throws -> [SensorReading] {
        try await inner.readAll()
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        readsStarted += 1
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        return try await inner.read(keys: keys)
    }

    /// Lets every held read go, and holds nothing from now on.
    func open() {
        holding = false
        let all = held
        held = []
        for continuation in all { continuation.resume() }
    }
}
