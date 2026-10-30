import Foundation

/// Rendering rules for the free text a fault carries across the boundary.
///
/// Its own file rather than a section of `AeolusXPCFault`, because the two answer
/// different questions: that type decides *what* the helper said, this one decides what is
/// safe to show a human afterwards. They were one file until adding a fault case pushed it
/// past this repository's 400-line limit, and this is the seam that was already there.
public enum FaultText {

    /// Whether the display rules remove `scalar`: Unicode general category Cc, Cf, Zl or Zp.
    ///
    /// **The one predicate for text from the far side of the boundary**, `public` so the app's
    /// `HelperAuthoredText`, `fanctl`'s `DisplayText` and the helper's `LogText` use this
    /// definition rather than a copy of it. Two copies had already disagreed: `displayable`
    /// removed Cc and Cf and kept U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR, which
    /// the app's copy removed (#553). Core Text breaks a line on both, so a surviving one is a
    /// forged second line.
    ///
    /// - Cc and Cf: what turns one log line into two (`\n`) or reverses the reading order of
    ///   the rest of it (U+202E RIGHT-TO-LEFT OVERRIDE, U+2066 LEFT-TO-RIGHT ISOLATE), and what
    ///   shows nothing at all (U+200B ZERO WIDTH SPACE, U+00AD SOFT HYPHEN).
    /// - Zl and Zp: the two line breaks the first pair do not contain, and the reason a
    ///   predicate spelled `CharacterSet.controlCharacters` cannot do this job. It lets both
    ///   through, and it reads Foundation's tables, which differ by macOS: on macOS 26 they also
    ///   hold thousands of plane-14 scalars that are not Cc or Cf (#563). All four categories
    ///   are named here by `Unicode.Scalar.Properties.generalCategory`, the standard library's
    ///   table.
    ///
    /// It is also the set the helper **refuses** in a client-chosen description
    /// (`AeolusXPCValidation.validateDescription`, #483): one rule, applied by refusing it on
    /// the way in, removing it on the way out, and escaping it in a helper log line. The helper
    /// refuses the same set in a curve's sensor key, as half of a narrower alphabet
    /// (`AeolusXPCValidation.isSensorKeyScalar`, #566).
    public static func isRemovedFromDisplay(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

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
    /// Control, format and line-separator characters go (`isRemovedFromDisplay(_:)`), because
    /// those are what turn one log line into two (`\n`, U+2028) or reverse the reading order of
    /// the rest of it (U+202E). An empty or entirely-unprintable string renders as a marker
    /// rather than as nothing at all, so a reader can tell "the helper said something
    /// unprintable" from "the helper said nothing".
    ///
    /// Both caps apply, and the ellipsis is counted *inside* them rather than added past
    /// them, so a rendered string is never longer than the constant that named its ceiling.
    /// Text so dense that not one character fits inside the byte cap renders as the marker.
    static func displayable(
        _ text: String,
        limit: Int = maxRenderedLength,
        byteLimit: Int = maxRenderedUTF8Bytes
    ) -> String {
        // Cc, Cf, Zl and Zp — `isRemovedFromDisplay(_:)`, which says what each removes and why.
        // What fails if any of them stops being removed is `renderingStripsControlCharacters`,
        // which covers U+202E, U+200F, U+2028 and U+2029 among its arguments, and
        // `displayableRemovesEveryScalarOfTheFourCategories`, which walks the whole code space.
        let stripped = String(text.unicodeScalars.filter { !isRemovedFromDisplay($0) })
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return unprintableMarker }
        guard trimmed.count > limit || trimmed.utf8.count > byteLimit else { return trimmed }
        // The cut itself is `FaultDetailBounds.truncated` — the same one the construction
        // -time bound uses. Two implementations of "stop on a grapheme boundary inside a
        // byte budget" would be two chances to split a scalar.
        //
        // The marker's own room comes out of the budget rather than being added past it.
        // That is `FaultDetailBounds.bounded`'s rule and was not this function's until #93's
        // review: cutting to the full `limit` and then appending returned 201 characters and
        // 803 bytes against constants named `maxRenderedLength` and `maxRenderedUTF8Bytes`,
        // and `oneBoundNotTwo` could not see it because it compares the two constants and
        // not the two cuts. `renderingAndConstructionCutIdentically` is what fails if the
        // two rules diverge again.
        let cut = FaultDetailBounds.truncated(
            trimmed,
            characters: limit - FaultDetailBounds.truncationMarker.count,
            bytes: byteLimit - FaultDetailBounds.truncationMarker.utf8.count
        )
        guard !cut.isEmpty else { return unprintableMarker }
        return cut + FaultDetailBounds.truncationMarker
    }
}
