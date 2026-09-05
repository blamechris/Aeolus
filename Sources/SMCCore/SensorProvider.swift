import Foundation

/// A source of thermal and power readings.
///
/// The SMC is one such source. On Apple Silicon some sensors that `powermetrics` reports
/// are exposed through `IOHIDEventSystemClient` instead, and it is not yet established
/// whether we need both providers or the SMC alone is sufficient. That is an open
/// research question for E1 — this protocol exists so the answer, whichever way it goes,
/// does not force a rewrite of everything above it.
public protocol SensorProvider: Sendable {
    /// A stable identifier for the provider, shown in diagnostics and bug reports.
    var identifier: String { get }

    /// Whether this provider can operate on the current machine.
    var isAvailable: Bool { get async }

    /// Enumerates every reading the provider can currently see.
    ///
    /// Discovery is dynamic. An unrecognised Mac must still show every sensor it has,
    /// unlabelled, and remain fully functional — the catalog only decorates.
    func readAll() async throws -> [SensorReading]

    /// Reads a subset of keys directly, without a prior full `readAll()`. The reason
    /// this lives on the protocol rather than only on `SMCSensorProvider`: E7's
    /// monitoring UI and E10a's `fanctl` read commands both need to refresh a handful of
    /// keys cheaply and repeatedly, and programming against the protocol means a future
    /// second provider (`IOHIDEventSystemClient`, if one is ever added) has to answer
    /// the same question rather than letting callers special-case `SMCSensorProvider`.
    ///
    /// One outcome per requested key, in the order requested — never a filtered array.
    /// A caller asking for 40 keys and getting 3 failures must be able to tell which 3
    /// failed, not silently receive 37 successes and infer the rest.
    func read(keys: [String]) async throws -> [SensorReadOutcome]
}

/// One key's outcome from `SensorProvider.read(keys:)`.
public struct SensorReadOutcome: Sendable, Hashable {
    /// The raw key exactly as requested — always retained, even on failure, so a caller
    /// can match outcomes back to what it asked for without assuming array order.
    public let key: String
    public let result: Result<SensorReading, SensorReadFailure>

    public init(key: String, result: Result<SensorReading, SensorReadFailure>) {
        self.key = key
        self.result = result
    }
}

/// Why a single key in a `SensorProvider.read(keys:)` subset read did not produce a
/// reading.
///
/// Deliberately provider-agnostic rather than `SMCError`: `SensorProvider` is the shared
/// abstraction over potentially more than one sensor source (see this file's own
/// documentation on why the SMC is not assumed to be the only one), and a future
/// non-SMC provider would have its own failure vocabulary. This is what any conforming
/// provider can promise a caller, regardless of backend.
public enum SensorReadFailure: Error, Sendable, Hashable {
    /// The provider does not recognise this key as one it can read at all — including a
    /// string that is not even well-formed for this provider's key space. Never a
    /// fabricated zero-valued reading; see `SMCSensorProvider.read(keys:)`.
    case unknownKey(String)
    /// The key is recognised but reading it failed. `reason` is the provider's own
    /// human-readable description (e.g. an `SMCError`'s), carried for diagnostics only —
    /// never parsed or matched on by a caller.
    case readFailed(reason: String)
    /// The provider produced a value but it does not decode to a usable reading — for
    /// example a non-numeric SMC type, or a scalar decode that itself failed.
    case notDecodable(reason: String)
}

extension SensorReadFailure {
    /// A human-readable rendering of this failure. Diagnostic only, never parsed or
    /// matched on by a caller.
    ///
    /// The one implementation, published here after three read clients — `fanctl`'s
    /// `ListCommand`, `AeolusUI`'s `PollingError`, and `SMCFanEnumeration` itself —
    /// each carried an independent copy of the identical switch. `SMCFanEnumeration`
    /// previously kept its copy `private` specifically because a `public` one here
    /// would have made `fanctl` and `AeolusUI`'s own extensions ambiguous; publishing
    /// it required deleting those two local copies in the same change, not just adding
    /// a third.
    public var readableDescription: String {
        switch self {
        case .unknownKey(let key):
            return "\(key) is not present on this machine"
        case .readFailed(let reason):
            return reason
        case .notDecodable(let reason):
            return reason
        }
    }
}

/// One sensor reading at one instant.
public struct SensorReading: Sendable, Hashable {
    /// The raw key, always retained. It is shown alongside any friendly label so a wrong
    /// label can never silently mislead someone into building a bad fan curve.
    public let key: String
    /// The decoded value, in the unit implied by `kind`.
    public let value: Double
    public let kind: Kind
    /// Which provider produced this reading.
    public let providerIdentifier: String

    public enum Kind: String, Sendable, Hashable, Codable {
        case temperatureCelsius
        case rpm
        case watts
        case volts
        case amps
        case percent
        case unknown
    }

    public init(key: String, value: Double, kind: Kind, providerIdentifier: String) {
        self.key = key
        self.value = value
        self.kind = kind
        self.providerIdentifier = providerIdentifier
    }
}

/// The SMC as a `SensorProvider`: every numeric key the machine exposes, discovered by
/// full enumeration rather than a hard-coded list.
///
/// ## Kind is deliberately conservative
///
/// `SensorReading.kind` is classified only where the SMC's own key-naming convention
/// already guarantees it — `F<n>Ac`/`Tg`/`Mn`/`Mx` are that fan's RPM, because `SMCKey`
/// itself defines that mapping as part of this project's control path, not as a guess.
/// Everything else reports `.unknown`. Inferring "starts with `T`, therefore Celsius"
/// would be exactly the kind of unverified label `docs/DESIGN.md`'s catalog exists to
/// carry with a confidence level and a citation instead — that decoration belongs to the
/// catalog (E6), not here. `SensorReading.key` always carries the raw four-character key
/// regardless, so a reading is never shown without the means to check it.
///
/// ## One provider is answered as sufficient here
///
/// A companion investigation compared this provider's output against
/// `IOHIDEventSystemClient` on `Mac16,5`: 19 of 21 distinct IOHID temperature sensors
/// matched an SMC reading within 0.15 °C, and the SMC additionally exposed 365 numeric
/// `T*` keys IOHID does not surface at all. See `docs/SMC-RESEARCH.md`. That is one
/// machine, one snapshot — `SensorProvider` stays a protocol precisely so a second
/// provider can be added without churn if another machine disagrees.
public struct SMCSensorProvider: SensorProvider {
    public let identifier = "smc"

    private let connection: SMCConnection

    public init(connection: SMCConnection = SMCConnection()) {
        self.connection = connection
    }

    public var isAvailable: Bool {
        get async { SMCConnection.isHardwareAvailable() }
    }

    /// Enumerates every key via `#KEY` and the index table, reads each one, and keeps
    /// only the readings that decode to a scalar. A failure at any stage of any single
    /// key — index lookup, `READ_KEYINFO`, `READ_BYTES`, or decoding — is skipped rather
    /// than aborting the whole enumeration; see `SMCConnection.read(_:)` for the failure
    /// modes this survives.
    ///
    /// `count` below drives both `reserveCapacity` and the enumeration bound, so it must
    /// never be a raw, unchecked decode of `#KEY`: `connection.keyCount()` already
    /// sanity-bounds it via `SMCConnection.validatePlausibleKeyCount(_:)` and throws
    /// `SMCError.implausibleKeyCount` rather than returning a value this method would then
    /// allocate and loop on. This is what stands between a byte-order regression and a
    /// ~957-million-element allocation — see `SMCConnection.maxPlausibleKeyCount`.
    ///
    /// Also runs the `#KEY` cross-check (ADR 0003's tripwire on the byte-order resolver)
    /// using the walk this enumeration is already doing, rather than repeating it — see
    /// `SMCConnection.verifyKeyCountCrossCheck()` for a standalone version of the same
    /// comparison, including why it also probes one index past `count`: a declared count
    /// that is too small walks and succeeds on every index inside its own bound, so that
    /// alone cannot detect undercounting — only the probe can.
    public func readAll() async throws -> [SensorReading] {
        try await connection.open()
        let count = try await connection.keyCount()

        var readings: [SensorReading] = []
        readings.reserveCapacity(count)
        var walkedKeys = 0
        var discoveredKeys: Set<SMCKey> = []
        discoveredKeys.reserveCapacity(count)

        for index in 0..<count {
            guard let key = try? await connection.key(at: index) else { continue }
            walkedKeys += 1
            discoveredKeys.insert(key)
            guard let value = try? await connection.read(key) else { continue }
            guard let scalar = try? value.scalar() else { continue }

            readings.append(
                SensorReading(
                    key: key.rawValue,
                    value: scalar,
                    kind: Self.kind(for: key),
                    providerIdentifier: identifier
                )
            )
        }

        let keyExistsPastDeclaredCount = (try? await connection.key(at: count)) != nil
        let crossCheck = KeyCountCrossCheck(
            declaredCount: count, walkedCount: walkedKeys,
            keyExistsPastDeclaredCount: keyExistsPastDeclaredCount)
        SMCConnection.logCrossCheck(crossCheck)

        // Discovery — the point of this issue: every key this walk actually resolved
        // (regardless of whether its value went on to read successfully) is recorded as
        // the machine's known key set, so a later read(keys:) can answer "does this
        // machine expose this key" without spending a round trip on it. See
        // SMCConnection.markDiscoveryComplete(_:).
        //
        // Only when the cross-check actually matches, though: if it does not,
        // discoveredKeys is not the complete key set — some index inside 0..<count
        // failed to resolve, or a key exists past the declared bound the walk never
        // looked at — and marking it complete anyway would let read(keys:) report a
        // false .keyNotFound for a key that is genuinely there but simply wasn't reached
        // this time. An incomplete walk leaves knownKeys exactly as it was: unset if this
        // is the first attempt, or whatever a previous complete walk established.
        if crossCheck.matches {
            await connection.markDiscoveryComplete(discoveredKeys)
        }

        return readings
    }

    /// Reads a subset of keys directly — see `SensorProvider.read(keys:)`. Never requires
    /// a prior `readAll()`: `open()` is idempotent, so calling it here costs nothing once
    /// a connection already exists and makes a bare `read(keys:)` call work standalone.
    /// Malformed key strings (not exactly four ASCII characters) are reported as
    /// `.unknownKey` rather than thrown, consistent with every other outcome here being
    /// per-key rather than aborting the whole request.
    public func read(keys: [String]) async throws -> [SensorReadOutcome] {
        var smcKeys: [String: SMCKey] = [:]
        smcKeys.reserveCapacity(keys.count)
        var malformed: Set<String> = []

        for raw in keys where smcKeys[raw] == nil && !malformed.contains(raw) {
            if let key = SMCKey(raw) {
                smcKeys[raw] = key
            } else {
                malformed.insert(raw)
            }
        }

        // A request made entirely of malformed strings has nothing to actually read, so
        // it needs no connection at all — opening one would fail with a hardware error
        // (no AppleSMC service) that has nothing to do with why this request failed, and
        // would make "every key I asked for was spelled wrong" indistinguishable from
        // "there is no SMC on this machine."
        let outcomesByKey: [SMCKey: SMCKeyReadOutcome]
        if smcKeys.isEmpty {
            outcomesByKey = [:]
        } else {
            try await connection.open()
            outcomesByKey = await connection.read(keys: Array(smcKeys.values))
                .reduce(into: [SMCKey: SMCKeyReadOutcome]()) { $0[$1.key] = $1 }
        }

        return keys.map { raw in
            if malformed.contains(raw) {
                return SensorReadOutcome(key: raw, result: .failure(.unknownKey(raw)))
            }
            guard let smcKey = smcKeys[raw], let outcome = outcomesByKey[smcKey] else {
                // Unreachable in practice: every non-malformed raw string produced an
                // SMCKey above and was included in the request to connection.read(keys:),
                // which returns exactly one outcome per requested key. Reported rather
                // than force-unwrapped so a violated assumption surfaces as a normal
                // per-key failure instead of a crash.
                return SensorReadOutcome(
                    key: raw, result: .failure(.readFailed(reason: "no outcome returned")))
            }
            return SensorReadOutcome(
                key: raw, result: sensorResult(for: smcKey, outcome))
        }
    }

    /// Converts one `SMCKeyReadOutcome` into the provider-agnostic `SensorReadOutcome`
    /// vocabulary — see `SensorReadFailure` for why this does not simply pass `SMCError`
    /// through.
    private func sensorResult(
        for key: SMCKey, _ outcome: SMCKeyReadOutcome
    ) -> Result<SensorReading, SensorReadFailure> {
        switch outcome.result {
        case .failure(.keyNotFound(let missingKey)):
            return .failure(.unknownKey(missingKey.rawValue))
        case .failure(let error):
            return .failure(.readFailed(reason: String(describing: error)))
        case .success(let value):
            do {
                guard let scalar = try value.scalar() else {
                    return .failure(
                        .notDecodable(reason: "\(value.type.fourCharString) is not numeric"))
                }
                return .success(
                    SensorReading(
                        key: key.rawValue, value: scalar, kind: Self.kind(for: key),
                        providerIdentifier: identifier))
            } catch {
                return .failure(.notDecodable(reason: String(describing: error)))
            }
        }
    }

    /// Classifies a key's physical kind using only the fan-key naming convention
    /// `SMCKey` already documents (`F<digit>` + `Ac`/`Tg`/`Mn`/`Mx`). Everything else is
    /// `.unknown` — see the type's documentation for why this stops here.
    ///
    /// Internal rather than `private` so it is directly unit-testable via
    /// `@testable import` without requiring hardware.
    static func kind(for key: SMCKey) -> SensorReading.Kind {
        let raw = key.rawValue
        guard raw.count == 4, raw.hasPrefix("F") else { return .unknown }

        let characters = Array(raw)
        guard characters[1].isASCII, characters[1].isNumber else { return .unknown }

        switch String(characters[2...]) {
        case "Ac", "Tg", "Mn", "Mx": return .rpm
        default: return .unknown
        }
    }
}
