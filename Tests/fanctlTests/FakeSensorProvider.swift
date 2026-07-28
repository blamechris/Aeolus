import SMCCore

/// A canned error for tests that need `readAll()`/`read(keys:)` to throw, with a
/// deterministic, inspectable description — never a real `SMCError`, so a test asserting
/// on `FanctlError`'s wrapped message is exercising this project's own wrapping, not the
/// specific wording of a hardware error it never actually saw.
struct FakeProviderError: Error, CustomStringConvertible, Equatable {
    let description: String
}

/// A `SensorProvider` double that answers from canned data rather than real hardware, so
/// `ListCommand` and `SensorsCommand`'s logic is fully testable on CI, which has no SMC
/// at all (see `Tests/SMCCoreTests/DevelopmentMachine.swift`'s documentation on why that
/// distinction matters).
actor FakeSensorProvider: SensorProvider {
    nonisolated let identifier: String

    private let availableValue: Bool
    private let allReadings: [SensorReading]
    private let allError: Error?
    private let keyedResults: [String: Result<SensorReading, SensorReadFailure>]
    private let keysError: Error?

    init(
        identifier: String = "fake",
        isAvailable: Bool = true,
        allReadings: [SensorReading] = [],
        allError: Error? = nil,
        keyedResults: [String: Result<SensorReading, SensorReadFailure>] = [:],
        keysError: Error? = nil
    ) {
        self.identifier = identifier
        self.availableValue = isAvailable
        self.allReadings = allReadings
        self.allError = allError
        self.keyedResults = keyedResults
        self.keysError = keysError
    }

    var isAvailable: Bool {
        get async { availableValue }
    }

    func readAll() async throws -> [SensorReading] {
        if let allError {
            throw allError
        }
        return allReadings
    }

    /// Every requested key gets exactly one outcome, in the order requested — matching
    /// the real contract in `SensorProvider.read(keys:)` — falling back to
    /// `.unknownKey` for anything this fake was not seeded with, so an un-stubbed key
    /// fails loudly in a test rather than silently returning nothing.
    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        if let keysError {
            throw keysError
        }
        return keys.map { key in
            let result = keyedResults[key] ?? .failure(.unknownKey(key))
            return SensorReadOutcome(key: key, result: result)
        }
    }
}

extension SensorReading {
    /// A convenience constructor for building fixture readings without repeating
    /// `providerIdentifier` at every call site in a test.
    static func fake(key: String, value: Double, kind: Kind = .unknown) -> SensorReading {
        SensorReading(key: key, value: value, kind: kind, providerIdentifier: "fake")
    }
}
