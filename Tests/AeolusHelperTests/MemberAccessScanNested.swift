import Foundation

/// The read of a type that is nested one level down, in an `extension` of the actor that holds it.
///
/// `MemberAccessScan` recognises a member at exactly four spaces. A value type written inside
/// `extension ReclamationWatchdog { … }` has its members at eight, so the suites that hold one
/// (`ReclamationRegistryAccessTests`, `LeaseAuthorityRegistersAccessTests`,
/// `ReclamationHeldFanAccessTests`) read the file with one indent level removed, which puts those
/// members at four and leaves the extension's own at none. Parameterising the scan's indent was
/// the other way to get there; it would change the one line every population is read through,
/// where this changes none of them.
extension MemberAccessScan {

    /// `file`'s source, comments stripped, with one four-space indent level removed from every
    /// line that has one.
    ///
    /// **What it relies on**, and where each part is held:
    ///
    /// - The type sits one level deep, in an extension at column zero. A file with a second
    ///   nested type contributes that type's members to the caller's population, which fails
    ///   loudly as an unacknowledged member rather than quietly.
    /// - A line is moved only when it begins with four spaces, so a line that does not (a
    ///   closing brace at column zero, a blank line) is kept as written. None of the four files
    ///   read this way holds a multi-line string literal, whose continuation lines would be moved
    ///   with the rest.
    /// - A modifier alone on a line, with the declaration beneath it, is written by the
    ///   formatter at twelve spaces for a member of such a type, which is eight once the level is
    ///   removed, and so is in no population for the reason #605 gives.
    static func outdentedSource(of file: String) throws -> String {
        try strippedSource(of: file)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }
            .joined(separator: "\n")
    }
}
