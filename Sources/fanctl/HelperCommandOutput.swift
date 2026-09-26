import ArgumentParser
import Foundation

/// How a helper-talking command formats what it writes, and how it leaves.
enum HelperCommandOutput {

    /// The version of every `--json` shape `status`, `set` and `auto` emit.
    ///
    /// Carried as a top-level `"schema"` key in every document and every NDJSON event, so a
    /// remote caller can refuse a shape it was not written against instead of misreading it.
    /// Adding a field does not bump it; renaming, removing or re-typing one does.
    static let schemaVersion = 1

    /// What `--json` means for a command.
    enum Format: Sendable {
        /// Human text.
        case text
        /// One pretty-printed document — `status`, `auto`.
        case document
        /// One compact object per line — `set`, which streams.
        case lines
    }

    /// Writes one JSON value in the command's format.
    static func emit(_ value: some Encodable, as format: Format, on terminal: Terminal) throws {
        switch format {
        case .text:
            return
        case .document:
            terminal.say(try FanctlJSON.encode(value))
        case .lines:
            terminal.say(try FanctlJSON.encodeLine(value))
        }
    }

    /// Reports a classified failure and leaves with its exit code.
    ///
    /// The human text always goes to standard error. Under `--json` a machine-readable
    /// failure also goes to standard output, so a caller parsing stdout always gets a JSON
    /// value it can read rather than an empty stream and an exit code to guess from.
    static func fail(
        _ failure: HelperCommandFailure, as format: Format, on terminal: Terminal
    ) throws -> Never {
        terminal.warn(failure.message)
        let document = FailureJSON(
            exitCode: failure.code.rawValue, kind: failure.code.kind, message: failure.message)
        switch format {
        case .text:
            break
        case .document:
            try? emit(FailureDocumentJSON(failure: document), as: format, on: terminal)
        case .lines:
            try? emit(FailureEventJSON(failure: document, at: Date()), as: format, on: terminal)
        }
        throw failure.code.exitCode
    }

    /// Leaves with `code`, which may be success.
    static func exit(_ code: FanctlExitCode) throws {
        guard code == .success else { throw code.exitCode }
    }

    struct FailureJSON: Encodable, Equatable {
        let exitCode: Int32
        let kind: String
        let message: String
    }

    /// `{"schema": 1, "failure": {...}}` — what `status --json` and `auto --json` print
    /// instead of their document when they could not produce one.
    struct FailureDocumentJSON: Encodable {
        let schema = HelperCommandOutput.schemaVersion
        let failure: FailureJSON
    }

    /// `set --json`'s terminal event when the command cannot go on.
    struct FailureEventJSON: Encodable {
        let schema = HelperCommandOutput.schemaVersion
        let event = "failed"
        let failure: FailureJSON
        let at: Date
    }
}
