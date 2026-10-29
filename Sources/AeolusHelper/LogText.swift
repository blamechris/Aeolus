import AeolusXPC
import Foundation

/// What a helper log line does with text it did not write.
///
/// A log line is **evidence**, so it keeps the firmware's text rather than cleaning it, the
/// opposite choice to a UI label (`FaultText.displayable`, `HelperAuthoredText.sanitised`),
/// which exists to be read and can afford to drop what it cannot show. A type code the
/// firmware declared as `"\u{2028}a"` is the thing an operator needs to see in `log show`.
/// What a log line cannot carry is a raw character that breaks or hides the line around it:
/// a `\n` or U+2028 starts what reads as a second entry, U+202E reorders everything after it
/// without drawing anything, and U+200B shows nothing at all. So those are written out as
/// `\u{XXXX}`, visibly, and every other character is left exactly as it arrived.
///
/// "Those" is `FaultText.isRemovedFromDisplay(_:)`, the same set the two renderers remove:
/// Unicode Cc, Cf, Zl and Zp. One definition, so a log line and a label disagree about
/// what is dangerous only in what they *do* about it.
///
/// ## What reaches a log line
///
/// Firmware reaches one through an error's description: `SMCKeyType.readableName` decodes the
/// four declared bytes of a type code as UTF-8, so `SMCFanEnumerationError.readFailed`,
/// `SMCSensorProvider.undecodedReason` and `SMCError.readableDescription` can each carry a
/// line break or a bidirectional control into a `detail` or a `reason` (#553, #548). A client
/// reaches one through `holderDescription` and the handshake's `clientDescription`, whose
/// validation refuses Cc and Cf but not yet Zl and Zp (#483).
///
/// **Applied where a line is emitted, not where a field is interpolated.** `SafetyLog` and
/// `HelperLog` each hand every line to one `emit`, and that `emit` escapes the finished
/// message. A per-field call would have to be remembered at every `\(detail)` and `\(reason)`,
/// and the next line added would be the one that forgot. The compiled-in text of those lines
/// held none of the four categories when this was written, so escaping the whole message
/// changes only what came from outside; a line that one day needs a real line break of its
/// own will show it as an escape, visibly, rather than lose it.
enum LogText {

    /// `text` with every scalar in Unicode Cc, Cf, Zl or Zp written as `\u{XXXX}`: upper-case
    /// hexadecimal, at least four digits, so `"a\u{2028}b"` reads `a\u{2028}b` on the page and
    /// a line feed reads `\u{000A}`. Everything else is returned untouched, in order.
    ///
    /// A backslash is not escaped, so a literal `\u{2028}` already in the text is
    /// indistinguishable from a scalar written out. That is accepted: the text is a
    /// diagnostic and the two spellings mean the same to a reader, whereas escaping the
    /// backslash would make every Windows-style path and regular expression in an error
    /// description unreadable, and would make `escaped` unsafe to apply twice. As it is,
    /// `escaped(escaped(x)) == escaped(x)`, which is what lets `emit` apply it to a message
    /// that a caller has already escaped.
    static func escaped(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: FaultText.isRemovedFromDisplay) else {
            return text
        }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if FaultText.isRemovedFromDisplay(scalar) {
                result.append(contentsOf: escape(scalar).unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    private static func escape(_ scalar: Unicode.Scalar) -> String {
        let digits = String(scalar.value, radix: 16, uppercase: true)
        return "\\u{" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits + "}"
    }
}
