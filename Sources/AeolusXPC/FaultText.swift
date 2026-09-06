import Foundation

/// Rendering rules for the free text a fault carries across the boundary.
///
/// Its own file rather than a section of `AeolusXPCFault`, because the two answer
/// different questions: that type decides *what* the helper said, this one decides what is
/// safe to show a human afterwards. They were one file until adding a fault case pushed it
/// past this repository's 400-line limit, and this is the seam that was already there.
enum FaultText {

    /// Longest run of helper-supplied free text this client will render, in characters.
    ///
    /// Not a validation limit — nothing is refused for exceeding it. It bounds one log
    /// line and one UI label, which is all `errorDescription` is for.
    ///
    /// The number itself moved to `FaultDetailBounds` in #93, which needed the same pair
    /// where a detail is *constructed*. Named here rather than restated: two numbers that
    /// must agree with nothing enforcing it is a disagreement waiting to happen.
    static let maxRenderedLength = FaultDetailBounds.maxLength

    /// The same bound, in UTF-8 bytes.
    ///
    /// A character cap alone does not bound a log line: one grapheme cluster can carry an
    /// unbounded run of combining marks, so 200 *characters* can be hundreds of kilobytes.
    /// Exactly the defect `AeolusXPCValidation.maxHolderDescriptionUTF8Bytes` exists for,
    /// at the same 4:1 ratio, applied to the rendering side.
    static let maxRenderedUTF8Bytes = FaultDetailBounds.maxUTF8Bytes

    /// Shown in place of text that survived stripping with nothing left.
    static let unprintableMarker = "unprintable"

    /// Makes free text from the far side of the boundary safe to put in a log line or a
    /// UI label, without discarding the fact that something arrived.
    ///
    /// Control and format characters go, because those are what turn one log line into
    /// two (`\n`) or reverse the reading order of the rest of it (U+202E). An empty or
    /// entirely-unprintable string renders as a marker rather than as nothing at all, so
    /// a reader can tell "the helper said something unprintable" from "the helper said
    /// nothing".
    ///
    /// Both caps apply. Text over either renders truncated with an ellipsis; text so dense
    /// that not one character fits inside the byte cap renders as the marker.
    static func displayable(
        _ text: String,
        limit: Int = maxRenderedLength,
        byteLimit: Int = maxRenderedUTF8Bytes
    ) -> String {
        // `CharacterSet.controlCharacters` is Unicode categories Cc **and Cf**, so this one
        // predicate removes the bidi and formatting scalars as well as the C0/C1 controls —
        // U+202E RIGHT-TO-LEFT OVERRIDE, U+2066 LEFT-TO-RIGHT ISOLATE, U+200B ZERO WIDTH
        // SPACE and U+00AD SOFT HYPHEN are all members, verified on this platform. Spelled
        // out because the name says "control" and reads as though it means Cc alone: a
        // reviewer has already read it that way and reported the bidi overrides as
        // unstripped. `renderingStripsControlCharacters` covers U+202E and U+200F among its
        // arguments and is what would fail if any of that stopped being true.
        let stripped = String(
            text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        )
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return unprintableMarker }
        guard trimmed.count > limit || trimmed.utf8.count > byteLimit else { return trimmed }
        // The cut itself is `FaultDetailBounds.truncated` — the same one the construction
        // -time bound uses. Two implementations of "stop on a grapheme boundary inside a
        // byte budget" would be two chances to split a scalar.
        let cut = FaultDetailBounds.truncated(trimmed, characters: limit, bytes: byteLimit)
        guard !cut.isEmpty else { return unprintableMarker }
        return cut + FaultDetailBounds.truncationMarker
    }
}
