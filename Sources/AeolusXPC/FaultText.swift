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
    static let maxRenderedLength = 200

    /// The same bound, in UTF-8 bytes.
    ///
    /// A character cap alone does not bound a log line: one grapheme cluster can carry an
    /// unbounded run of combining marks, so 200 *characters* can be hundreds of kilobytes.
    /// Exactly the defect `AeolusXPCValidation.maxHolderDescriptionUTF8Bytes` exists for,
    /// at the same 4:1 ratio, applied to the rendering side. Not reachable from client
    /// input today — this text comes from the helper — so it is depth, not a live hole.
    static let maxRenderedUTF8Bytes = maxRenderedLength * 4

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
        let stripped = String(
            text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        )
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return unprintableMarker }
        guard trimmed.count > limit || trimmed.utf8.count > byteLimit else { return trimmed }
        let cut = truncated(trimmed, characters: limit, bytes: byteLimit)
        guard !cut.isEmpty else { return unprintableMarker }
        return cut + "…"
    }

    /// Applies both caps at once, cutting on a `Character` boundary so the result is never
    /// a half-formed grapheme cluster and never a split scalar.
    private static func truncated(_ text: String, characters: Int, bytes: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in text.prefix(characters) {
            let width = String(character).utf8.count
            guard byteCount + width <= bytes else { break }
            result.append(character)
            byteCount += width
        }
        return result
    }
}
