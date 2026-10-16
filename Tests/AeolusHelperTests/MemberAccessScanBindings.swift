import Foundation

/// `MemberAccessScan`'s check for declarations its member parse cannot key: one `let` or `var`
/// that binds more than one name.
///
/// Its own file so `MemberAccessScan.swift` stays under SwiftLint's 400-line warning, and
/// because it answers a different question from the parse: not *what* a member is, but whether a
/// line declares members the parse cannot see. The modifier walk is `member(in:keyword:)`'s, and
/// `ignorableModifiers` is shared rather than copied.
extension MemberAccessScan {

    /// Every property declaration at member indent that binds more than one name, trimmed: a
    /// tuple pattern, `var (a, b) = (0, 0)`, or a comma-separated list, `var a = 0, b = 1`.
    ///
    /// `member(in:keyword:)` reads the first name after `let` or `var` and no other, so both
    /// spellings declare a member that an exhaustive acknowledged list never sees: `private var
    /// (hiddenA, hiddenB) = (0, 0)` keys as nothing, and `private var finalising: [Int: UUID] =
    /// [:], hiddenStore: [Int: UUID] = [:]` keys as `finalising` alone. Both left
    /// `ReclamationWatchdogAccessTests`' exact lists green in #128's review. A guard built on
    /// that parse asserts this list is empty, rather than the parse learning to split them, so
    /// the spelling fails loudly instead of being read approximately.
    ///
    /// The comma is looked for at bracket depth zero across the whole declaration, newlines
    /// included, so `var a = [` on one line and `], b = 2` on a later one is seen. String
    /// literals are stepped over, a trailing `//` comment ends the line, a `->` closes nothing,
    /// and `<` opens a generic clause only straight after a name. The declaration ends at the
    /// first newline at depth zero.
    static func multipleBindings(inSource code: String) -> [String] {
        var found: [String] = []
        var lineStart = code.startIndex

        while true {
            let lineEnd = code[lineStart...].firstIndex(of: "\n") ?? code.endIndex
            let line = code[lineStart..<lineEnd]
            if let pattern = bindingStart(in: line), bindsMoreThanOneName(in: code, from: pattern) {
                found.append(line.trimmingCharacters(in: .whitespaces))
            }
            guard lineEnd < code.endIndex else { break }
            lineStart = code.index(after: lineEnd)
        }
        return found
    }

    // MARK: - Parsing

    /// Where the pattern after `let` or `var` begins on a member-indent line, past the same
    /// modifier run `member(in:keyword:)` walks — or `nil` when the line declares no property.
    private static func bindingStart(in line: Substring) -> String.Index? {
        guard line.hasPrefix("    "), !line.hasPrefix("     ") else { return nil }
        var index = line.index(line.startIndex, offsetBy: 4)
        var attributeDepth = 0

        while index < line.endIndex {
            let end = line[index...].firstIndex(of: " ") ?? line.endIndex
            let token = line[index..<end]
            let next = end < line.endIndex ? line.index(after: end) : end
            let head = String(token.prefix { $0 != "(" })

            if attributeDepth > 0 || token.hasPrefix("@") {
                attributeDepth += token.filter { $0 == "(" }.count
                attributeDepth -= token.filter { $0 == ")" }.count
            } else if head != "private", head != "fileprivate", !ignorableModifiers.contains(head) {
                return token == "let" || token == "var" ? next : nil
            }
            index = next
        }
        return nil
    }

    /// Whether the declaration whose pattern starts at `start` binds more than one name.
    private static func bindsMoreThanOneName(in code: String, from start: String.Index) -> Bool {
        var index = code[start...].firstIndex { $0 != " " } ?? code.endIndex
        if index < code.endIndex, code[index] == "(" { return true }

        var depth = 0
        var angles = 0
        var previous: Character = " "
        var skipped = ""
        while index < code.endIndex {
            let character = code[index]
            if character == "\"" {
                let delimiter = code[index...].hasPrefix("\"\"\"") ? "\"\"\"" : "\""
                index = SeamScanner.copyDelimited(
                    code, from: index, delimiter: delimiter, into: &skipped)
                previous = "\""
                continue
            }
            if code[index...].hasPrefix("//") {
                index = code[index...].firstIndex(of: "\n") ?? code.endIndex
                continue
            }
            switch character {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            case "<" where previous.isLetter || previous.isNumber || previous == "_": angles += 1
            case ">" where previous != "-" && angles > 0: angles -= 1
            case "," where depth == 0 && angles == 0: return true
            case "\n" where depth == 0: return false
            default: break
            }
            previous = character
            index = code.index(after: index)
        }
        return false
    }
}
