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
