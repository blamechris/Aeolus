import Foundation

/// The sensor catalog: a set of raw-key-to-label mappings, scoped by chip family and
/// model. See `docs/ARCHITECTURE.md` § The catalog only decorates.
///
/// - Important: **The catalog only decorates.** Sensor discovery is dynamic. A machine
///   with zero matching entries in this catalog must show every sensor it has, raw key
///   and all, fully functional. Nothing that reads a `SensorCatalog` may make a reading
///   depend on an entry existing for it.
public struct SensorCatalog: Sendable, Hashable, Codable {
    /// The schema version this catalog was written against. See
    /// `CatalogLoader.supportedSchemaVersion` for how a mismatch is handled.
    public let schemaVersion: Int
    public let entries: [CatalogEntry]

    /// The newest `schemaVersion` this build of Aeolus understands. Keep in sync with
    /// `Resources/catalog/catalog.schema.json`'s `schemaVersion.const`.
    public static let currentSchemaVersion = 1

    /// A catalog with no entries at all — the correct state for "nothing loaded", not an
    /// error state. Every sensor still shows; it just shows unlabelled.
    public static let empty = SensorCatalog(schemaVersion: currentSchemaVersion, entries: [])

    public init(schemaVersion: Int, entries: [CatalogEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

/// One mapping from a raw SMC key to a human-readable label.
///
/// - Important: A `CatalogEntry` is never sufficient reason to hide the raw key it
///   labels. Every place a `label` is shown, the raw `key` is shown alongside it — a
///   wrong label must never be able to quietly mislead someone into driving a fan from
///   the wrong sensor.
public struct CatalogEntry: Sendable, Hashable, Codable {
    /// The raw four-character SMC key this entry labels, e.g. `"Tp09"`.
    public let key: String
    /// Restricts this entry to specific hardware. `nil` means "applies everywhere",
    /// which the schema notes should be rare — most keys mean different things on
    /// different chips.
    public let match: CatalogMatch?
    public let label: String
    public let category: SensorCategory
    public let confidence: CatalogConfidence
    /// Where the mapping came from — an issue number, a pull request, or a citation.
    public let source: String?

    public init(
        key: String,
        match: CatalogMatch? = nil,
        label: String,
        category: SensorCategory,
        confidence: CatalogConfidence,
        source: String? = nil
    ) {
        self.key = key
        self.match = match
        self.label = label
        self.category = category
        self.confidence = confidence
        self.source = source
    }
}

/// Restricts a `CatalogEntry` to specific hardware.
public struct CatalogMatch: Sendable, Hashable, Codable {
    public let chipFamily: [String]?
    public let modelIdentifier: [String]?

    public init(chipFamily: [String]? = nil, modelIdentifier: [String]? = nil) {
        self.chipFamily = chipFamily
        self.modelIdentifier = modelIdentifier
    }
}

extension CatalogMatch {
    /// The case-insensitive, order-independent `chipFamily` restriction this match
    /// declares, with `nil` normalizing to the empty set exactly like `[]` does.
    ///
    /// This is the one normalization both `CatalogLoader.merge`'s override identity and
    /// `CatalogMatcher`'s specificity resolution use — see either call site for why array
    /// order, `nil` vs. `[]`, and case must all compare equal here: a hand-edited
    /// `chipFamily: ["M4 Max"]` and a bundled `chipFamily: ["m4 max"]` mean the same
    /// scope, not two different ones.
    var normalizedChipFamily: Set<String> { Self.normalized(chipFamily) }

    /// Same normalization as `normalizedChipFamily`, for `modelIdentifier`.
    var normalizedModelIdentifier: Set<String> { Self.normalized(modelIdentifier) }

    private static func normalized(_ values: [String]?) -> Set<String> {
        Set((values ?? []).map { $0.lowercased() })
    }
}

/// What kind of thing a labelled sensor measures.
///
/// Carries an `unknown` case rather than failing to decode, for the same reason
/// `SMCKeyType.unknown` exists in `SMCCore`: a catalog written against a future schema
/// version may use a category this build has never heard of, and losing the whole entry
/// — or the whole catalog — over one unrecognised string would be a much worse failure
/// than showing a slightly less specific label.
public enum SensorCategory: Sendable, Hashable, Codable {
    case cpu
    case gpu
    case memory
    case storage
    case battery
    case power
    case ambient
    case display
    case fan
    case other
    /// A category string this build does not recognise, carried verbatim.
    case unknown(String)

    /// Builds a category from the string the catalog JSON spells it with.
    public init(schemaValue value: String) {
        switch value {
        case "cpu": self = .cpu
        case "gpu": self = .gpu
        case "memory": self = .memory
        case "storage": self = .storage
        case "battery": self = .battery
        case "power": self = .power
        case "ambient": self = .ambient
        case "display": self = .display
        case "fan": self = .fan
        case "other": self = .other
        default: self = .unknown(value)
        }
    }

    /// The string this category is spelled as in catalog JSON.
    public var schemaValue: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "gpu"
        case .memory: "memory"
        case .storage: "storage"
        case .battery: "battery"
        case .power: "power"
        case .ambient: "ambient"
        case .display: "display"
        case .fan: "fan"
        case .other: "other"
        case .unknown(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(schemaValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(schemaValue)
    }
}

/// How much a `CatalogEntry`'s label should be trusted. Always shown in the UI — a
/// `guess` is displayed as a guess, never smoothed over.
///
/// Carries an `unknown` case for the same reason `SensorCategory` does: an unrecognised
/// confidence level from a future schema version must not fail the whole load.
public enum CatalogConfidence: Sendable, Hashable, Codable {
    /// Someone confirmed the mapping against observed behaviour on that hardware.
    case verified
    /// Reported by the community but not independently confirmed by a maintainer.
    case community
    /// A plausible mapping nobody has confirmed. Shown as a guess so it cannot quietly
    /// pass as fact.
    case guess
    /// A confidence string this build does not recognise, carried verbatim.
    case unknown(String)

    /// Builds a confidence level from the string the catalog JSON spells it with.
    public init(schemaValue value: String) {
        switch value {
        case "verified": self = .verified
        case "community": self = .community
        case "guess": self = .guess
        default: self = .unknown(value)
        }
    }

    /// The string this confidence level is spelled as in catalog JSON.
    public var schemaValue: String {
        switch self {
        case .verified: "verified"
        case .community: "community"
        case .guess: "guess"
        case .unknown(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(schemaValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(schemaValue)
    }
}
