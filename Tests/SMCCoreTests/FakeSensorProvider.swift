import SMCCore
import Testing

/// A canned error for tests that need `read(keys:)` to throw, with a deterministic,
/// inspectable description — never a real `SMCError`, so a test asserting on this project's
/// own error wrapping is exercising the wrapping rather than the wording of a hardware
/// failure it never actually saw.
struct FakeProviderError: Error, CustomStringConvertible, Equatable {
    let description: String
}

/// A `SensorProvider` double answering from canned data rather than real hardware, so
/// `SMCFanEnumeration`'s logic is fully exercisable on CI — which has no SMC at all; see
/// `DevelopmentMachine.swift` for why that distinction matters.
///
/// An actor rather than a struct so it can record what it was asked for: "enumeration reads
/// `FNum` and the three keys per fan, and nothing else" is a claim about the requests made,
/// and there is no way to check it from the results alone.
actor FakeSensorProvider: SensorProvider {
    nonisolated let identifier: String

    private let availableValue: Bool
    private let keyedResults: [String: Result<SensorReading, SensorReadFailure>]
    private let keysError: FakeProviderError?
    private let omittedKeys: Set<String>

    /// Every `read(keys:)` request this provider received, in order, as it was received.
    private(set) var requests: [[String]] = []

    /// `keyedResults` holds canned outcomes by key; anything not listed answers
    /// `.unknownKey`, so an un-stubbed key fails visibly in a test rather than silently
    /// vanishing. `keysError` is thrown from `read(keys:)` instead of answering, for the
    /// whole-request failure path.
    ///
    /// `omittedKeys` are silently dropped from the response. That **deliberately violates**
    /// `SensorProvider.read(keys:)`'s one-outcome-per-requested-key contract: it is the only
    /// way to reach the defensive "no outcome returned" branches, which exist precisely
    /// because a provider that broke that contract would otherwise surface as a missing fan
    /// rather than as a named failure.
    init(
        identifier: String = "fake",
        isAvailable: Bool = true,
        keyedResults: [String: Result<SensorReading, SensorReadFailure>] = [:],
        keysError: FakeProviderError? = nil,
        omittedKeys: Set<String> = []
    ) {
        self.identifier = identifier
        self.availableValue = isAvailable
        self.keyedResults = keyedResults
        self.keysError = keysError
        self.omittedKeys = omittedKeys
    }

    var isAvailable: Bool {
        get async { availableValue }
    }

    /// Never exercised by fan enumeration — which is the point. Enumeration derives every
    /// key it needs from `FNum`, so it must never fall back to a full walk; a test that
    /// reached this would be evidence of exactly that regression.
    func readAll() async throws -> [SensorReading] {
        Issue.record("fan enumeration must never call readAll()")
        return []
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        requests.append(keys)
        if let keysError {
            throw keysError
        }
        return keys.compactMap { key in
            guard !omittedKeys.contains(key) else { return nil }
            return SensorReadOutcome(
                key: key, result: keyedResults[key] ?? .failure(.unknownKey(key)))
        }
    }
}

extension SensorReading {
    /// A fixture reading, so tests need not repeat `providerIdentifier` at every call site.
    /// Defaults to `.rpm` because every key this suite deals with is a fan key.
    static func fake(key: String, value: Double, kind: Kind = .rpm) -> SensorReading {
        SensorReading(key: key, value: value, kind: kind, providerIdentifier: "fake")
    }
}

extension Result where Success == SensorReading, Failure == SensorReadFailure {
    /// A successful canned reading for `key`.
    static func rpm(_ key: String, _ value: Double) -> Self {
        .success(.fake(key: key, value: value))
    }
}
