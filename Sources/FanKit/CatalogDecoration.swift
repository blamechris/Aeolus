import Foundation

/// A resolved catalog match for one raw SMC key on this machine: everything a caller needs
/// to label a reading, without ever letting the label stand in for the key it came from.
/// Produced only by `CatalogMatcher`.
///
/// - Important: **No API resolves a `CatalogDecoration`, or anything else, from a label
///   alone — and none ever should.** A caller that needs to act on a sensor already has
///   its `key`; `label` exists purely to be displayed alongside that key, never to
///   replace it as an identifier. Curve inputs, and everything else that picks a sensor to
///   drive something, must always be chosen by `key`. See `CLAUDE.md`: "a wrong label
///   must never be able to quietly mislead someone into driving a fan from the wrong
///   sensor."
public struct CatalogDecoration: Sendable, Hashable {
    /// The raw four-character SMC key this decoration describes. Always carried alongside
    /// `label` — never returned, displayed, or logged in place of it.
    public let key: String
    public let label: String
    public let category: SensorCategory
    public let confidence: CatalogConfidence
    /// Where the mapping came from, carried through from `CatalogEntry.source` for
    /// provenance. Never displayed as a substitute for `confidence` — a `guess` is shown
    /// as a guess regardless of whether a source is cited.
    public let source: String?

    public init(
        key: String,
        label: String,
        category: SensorCategory,
        confidence: CatalogConfidence,
        source: String? = nil
    ) {
        self.key = key
        self.label = label
        self.category = category
        self.confidence = confidence
        self.source = source
    }
}
