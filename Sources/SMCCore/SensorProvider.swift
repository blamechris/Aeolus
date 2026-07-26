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
    public func readAll() async throws -> [SensorReading] {
        try await connection.open()
        let count = try await connection.keyCount()

        var readings: [SensorReading] = []
        readings.reserveCapacity(count)

        for index in 0..<count {
            guard let key = try? await connection.key(at: index) else { continue }
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

        return readings
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
