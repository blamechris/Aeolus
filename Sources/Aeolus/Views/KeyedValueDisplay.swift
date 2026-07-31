import Foundation

/// A pure, testable projection of one `KeyedReading` into what a row shows: the raw SMC
/// key (always present, per `CLAUDE.md`'s rule that a raw key is shown alongside any
/// rendered value — never in place of it), the rendered text, and whether that text
/// represents an actual reading or an honest "unavailable" explanation.
///
/// Extracted from the view layer so "does this reading render as a value or as
/// unavailable" is a fact a unit test can check directly, without instantiating a
/// `View` or a `PollingViewModel`.
struct KeyedValueDisplay: Equatable {
    let key: String
    let text: String
    /// `true` exactly when `text` renders a real reading. A view can use this to dim
    /// unavailable text without having to re-parse `text` to find out why it looks the
    /// way it does.
    let isAvailable: Bool

    init(reading: KeyedReading, unit: String? = nil) {
        key = reading.key
        text = ReadingFormatting.text(for: reading, unit: unit)
        isAvailable = reading.isAvailable
    }
}
