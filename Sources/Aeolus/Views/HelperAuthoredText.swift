import AeolusXPC
import Foundation

/// Text that crossed the boundary from the helper, cleaned before SwiftUI draws it. **The one
/// sanitiser in this app**; every renderer of helper-authored text goes through it.
///
/// What counts, and where each goes through it:
/// - another client's `Lease.holderDescription` (`ControlSourceDisplay`);
/// - a `FanReading`'s unavailable reason (`SnapshotReadings`);
/// - a `ManualControlAvailability.Reason.unknown` wire value (`FanRowModel`);
/// - the description of a failed snapshot request, which can carry an `AeolusXPCFault`'s
///   detail, and a sensor key named in a contradiction (`HelperSnapshotSource`);
/// - a snapshot's sensor key. A key is not cleaned, because it is also an identity — a
///   selection is persisted by it — and a cleaned key would be a different one. It is
///   **refused** instead unless `isDisplayableVerbatim(_:)` holds (`SnapshotReadings`).
///
/// One text that is not the helper's goes through it too: a direct read's failure, in the
/// "Refresh failed:" and "Last refresh failed:" lines (`PollingStatusDisplay.failureReason`).
/// It can carry a type code the firmware declared, verbatim, and the same rules apply to it
/// for the same reason (#544).
///
/// ## Why the app cleans what the helper already refused
///
/// `AeolusXPCValidation` refuses Unicode Cc and Cf in a holder description at grant time, so a
/// well-behaved helper never stores one. That is the first layer, and this is the second: the
/// client does not get to assume the process answering is well-behaved, and SwiftUI's `Text`
/// renders what it is given — a U+202E right-to-left override reorders the rest of the line
/// without adding a visible character, and a newline turns one line into a forged second one.
///
/// ## The rules are `fanctl`'s, plus the two line breaks it misses
///
/// `DisplayText.sanitised(_:)` in `Sources/fanctl/FanctlExitCode.swift` cleans the same text on
/// its way to a terminal. It is internal to an executable target the app cannot import, so the
/// rules are mirrored here: drop every scalar in Unicode Cc and Cf (`CharacterSet
/// .controlCharacters`, the set `AeolusXPCValidation` refuses), trim surrounding whitespace,
/// say `(unprintable)` rather than show nothing, and cap the length.
///
/// Two departures, both deliberate:
/// - **Zl and Zp go too** — U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR. Neither is
///   Cc or Cf, and Core Text breaks a line on both, which is exactly the forged second line
///   this type exists to prevent. `fanctl` and the helper's validation are #483's.
/// - **The cap bounds bytes as well as characters**, as `FaultText.displayable` does in
///   `AeolusXPC`: one grapheme can carry any number of combining marks, so 200 characters
///   alone can be hundreds of kilobytes. The cut is `FaultDetailBounds.bounded(_:)` itself,
///   so the two caps, their 4:1 ratio and the ellipsis counted inside them are that type's.
enum HelperAuthoredText {
    /// The longest cleaned text, in characters, ellipsis included. `FaultDetailBounds.maxLength`.
    static let maxLength = FaultDetailBounds.maxLength

    /// The same bound in UTF-8 bytes. `FaultDetailBounds.maxUTF8Bytes`.
    static let maxUTF8Bytes = FaultDetailBounds.maxUTF8Bytes

    /// Shown in place of text with nothing printable left in it.
    static let unprintable = "(unprintable)"

    /// Whether `scalar` is one this type removes: Unicode Cc, Cf, Zl or Zp.
    static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    static func sanitised(_ text: String) -> String {
        let stripped = String(text.unicodeScalars.filter { !isRemoved($0) })
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return unprintable }
        let bounded = FaultDetailBounds.bounded(trimmed)
        // So dense that not one character fits inside the byte cap: `bounded` returns the
        // ellipsis alone, which would read as "something long was cut" with nothing to show.
        if bounded == FaultDetailBounds.truncationMarker, trimmed != bounded {
            return unprintable
        }
        return bounded
    }

    /// Whether `text` can be shown exactly as it is: not empty, no scalar this type removes,
    /// and within both caps. For a key, which must be shown and kept verbatim or not at all.
    static func isDisplayableVerbatim(_ text: String) -> Bool {
        !text.isEmpty
            && text.utf8.count <= maxUTF8Bytes
            && text.count <= maxLength
            && !text.unicodeScalars.contains(where: isRemoved)
    }
}
