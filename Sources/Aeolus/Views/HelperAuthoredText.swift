import Foundation

/// Text that crossed the boundary from the helper, cleaned before SwiftUI draws it. **The one
/// sanitiser in this app**; every renderer of helper-authored text goes through it.
///
/// What counts: another client's `Lease.holderDescription`, a `FanReading`'s unavailable
/// reason, a `ManualControlAvailability.Reason.unknown` wire value, and the description of a
/// failed snapshot request, which can carry an `AeolusXPCFault`'s detail.
///
/// ## Why the app cleans what the helper already refused
///
/// `AeolusXPCValidation` refuses Unicode Cc and Cf in a holder description at grant time, so a
/// well-behaved helper never stores one. That is the first layer, and this is the second: the
/// client does not get to assume the process answering is well-behaved, and SwiftUI's `Text`
/// renders what it is given — a U+202E right-to-left override reorders the rest of the line
/// without adding a visible character, and a newline turns one line into a forged second one.
///
/// ## The rules are `fanctl`'s
///
/// `DisplayText.sanitised(_:)` in `Sources/fanctl/FanctlExitCode.swift` cleans the same text on
/// its way to a terminal. It is internal to an executable target the app cannot import, so the
/// rules are mirrored here, unchanged: drop every scalar in `CharacterSet.controlCharacters`
/// (Unicode Cc and Cf — the set `AeolusXPCValidation` refuses), trim surrounding whitespace,
/// say `(unprintable)` rather than show nothing, and cap the length at 200 characters. Two
/// clients cleaning the same text two ways would show the same holder two ways.
enum HelperAuthoredText {
    /// The longest cleaned text, in characters, ellipsis included. `DisplayText.maxLength`.
    static let maxLength = 200

    static func sanitised(_ text: String) -> String {
        let stripped = String(
            text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(unprintable)" }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "…"
    }
}
