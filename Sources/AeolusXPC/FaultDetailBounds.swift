import Foundation

/// The one ceiling on the free text a fault carries, and the one place the numbers live.
///
/// `FaultText.displayable` bounds this text at **render** time, which is the right place
/// for a log line and a UI label and is not a bound on what crosses the boundary:
/// `AeolusXPCFault.asNSError()` embeds the fault's own JSON in `userInfo` and
/// `NSXPCConnection` re-encodes that on the way across, so an unbounded detail is an
/// unbounded thing crossing a privilege boundary no matter how carefully it is later
/// rendered ([#93](https://github.com/blamechris/Aeolus/issues/93)).
///
/// So the bound is applied where the detail is **constructed** as well —
/// `AeolusXPCFault.crossing(_:)`, whose whole purpose is to catch errors nobody
/// anticipated — and again where one arrives, in `AeolusXPCFault.init(from:)`, for *every*
/// arm that carries free text rather than for `helperFailed` alone. The decode-side bound
/// is justified by a peer that need not be this project's helper, and such a peer chooses
/// which arm it sends: bounding one of five would name an adversary and then leave it four
/// doors.
///
/// ## Truncated, not refused
///
/// The opposite of `AeolusXPCValidation`'s rule, deliberately. That module refuses
/// client-supplied input because a repaired request is one the client never sent. This
/// text is helper-authored — an SMC error's own description — and is the only thing the
/// user will have to go on when a fan does not respond. Refusing it would discard the
/// diagnosis; truncating it keeps `helperFailed`'s stated permission to quote what it saw,
/// with a ceiling on how much.
///
/// The marker is inside the bound rather than added to it: a caller that bounds a string
/// and then finds the result one character over has not been given a bound.
///
/// ## The numbers live here, not in `FaultText`
///
/// They were `FaultText`'s until #93 needed the same pair at construction time, and two
/// numbers that must agree with nothing enforcing it is a disagreement waiting to happen.
/// `FaultText` now names these; its rendering behaviour is unchanged, which is the point —
/// stripping control characters and bidirectional overrides is a different job from
/// bounding a length, and this does not replace it.
public enum FaultDetailBounds {

    /// Longest fault detail this project carries, in characters.
    ///
    /// It bounds one log line and one UI label, which is all `errorDescription` is for.
    public static let maxLength = 200

    /// The same bound, in UTF-8 bytes.
    ///
    /// A character cap alone does not bound a log line: one grapheme cluster can carry an
    /// unbounded run of combining marks, so 200 *characters* can be hundreds of kilobytes.
    /// Exactly the defect `AeolusXPCValidation.maxHolderDescriptionUTF8Bytes` exists for,
    /// at the same 4:1 ratio.
    public static let maxUTF8Bytes = maxLength * 4

    /// Says a bound was reached, so a reader can tell a short diagnosis from a clipped
    /// one. One character, three UTF-8 bytes, and counted inside both caps.
    public static let truncationMarker = "…"

    /// Applies both caps to a helper-authored detail, marking the cut.
    ///
    /// Text already inside both caps is returned **unchanged** — not stripped, not
    /// trimmed, not re-encoded. This is a ceiling, not a sanitiser.
    ///
    /// - Parameter text: The detail as its producer wrote it.
    /// - Returns: `text`, or its first characters plus `truncationMarker`, within both
    ///   caps.
    public static func bounded(_ text: String) -> String {
        // The byte count is tested first, and the order is load-bearing rather than
        // stylistic. `String.count` walks the whole string breaking grapheme clusters,
        // which on the multi-megabyte input this function exists to catch is the very
        // cost being bounded; `utf8.count` is O(1) for a native Swift string. Anything
        // that passes the byte test is at most 800 bytes, so counting its characters
        // afterwards is cheap.
        guard text.utf8.count > maxUTF8Bytes || text.count > maxLength else { return text }
        let cut = truncated(
            text,
            characters: maxLength - truncationMarker.count,
            bytes: maxUTF8Bytes - truncationMarker.utf8.count
        )
        return cut + truncationMarker
    }

    /// Applies both caps at once, cutting on a `Character` boundary so the result is never
    /// a half-formed grapheme cluster and never a split scalar.
    ///
    /// Shared with `FaultText.displayable`, which needs the identical cut after it has
    /// stripped control characters. One implementation, because two would be two chances
    /// to split a scalar.
    static func truncated(_ text: String, characters: Int, bytes: Int) -> String {
        var result = ""
        var byteCount = 0
        // Both budgets are floored at zero rather than trusted. Each caller subtracts the
        // marker's width from a limit before calling, and `String.prefix` **traps** on a
        // negative count — so a limit smaller than the marker would abort the process
        // rather than return a short string, which is not a failure mode worth having in a
        // function on the error path.
        for character in text.prefix(max(0, characters)) {
            let width = String(character).utf8.count
            guard byteCount + width <= max(0, bytes) else { break }
            result.append(character)
            byteCount += width
        }
        return result
    }
}

/// Decoding a free-text field with the ceiling already applied.
///
/// An extension rather than a bare call at each site because `AeolusXPCFault.init(from:)`
/// has five arms carrying free text and the bound has to be on every one of them. Writing
/// `FaultDetailBounds.bounded(try container.decode(String.self, forKey: .detail))` five
/// times is five chances to leave one out — and the one left out is the one an adversary
/// picks, since choosing which arm arrives is a matter of changing one wire code.
extension KeyedDecodingContainer {

    /// Decodes a required free-text field, bounded.
    func decodeBoundedText(forKey key: Key) throws -> String {
        FaultDetailBounds.bounded(try decode(String.self, forKey: key))
    }

    /// Decodes an optional free-text field, bounded when it is there.
    func decodeBoundedTextIfPresent(forKey key: Key) throws -> String? {
        try decodeIfPresent(String.self, forKey: key).map(FaultDetailBounds.bounded)
    }
}
