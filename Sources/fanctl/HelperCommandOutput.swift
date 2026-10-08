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
    ///
    /// `closing` is what `set`'s closing event adds to the existing `failed` shape: the lease, why
    /// the hold ended and what the helper reported. It is `null` throughout for a command that
    /// has nothing to add.
    static func fail(
        _ failure: HelperCommandFailure, as format: Format, on terminal: Terminal,
        closing: SetClosingFacts = .none
    ) throws -> Never {
        terminal.warn(failure.message)
        let document = FailureJSON(failure)
        switch format {
        case .text:
            break
        case .document:
            try? emit(FailureDocumentJSON(failure: document), as: format, on: terminal)
        case .lines:
            try? emit(
                FailureEventJSON(failure: document, at: Date(), closing: closing), as: format,
                on: terminal)
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

        init(exitCode: Int32, kind: String, message: String) {
            self.exitCode = exitCode
            self.kind = kind
            self.message = message
        }

        init(_ failure: HelperCommandFailure) {
            self.init(
                exitCode: failure.code.rawValue, kind: failure.code.kind, message: failure.message)
        }
    }

    /// `{"schema": 1, "failure": {...}}` — what `status --json` and `auto --json` print
    /// instead of their document when they could not produce one.
    struct FailureDocumentJSON: Encodable {
        let schema = HelperCommandOutput.schemaVersion
        let failure: FailureJSON
    }

    /// `set --json`'s closing event when the hold did not end in the safe state, or never
    /// began: `{"schema": 1, "event": "failed", "at": ..., "failure": {...}}`, extended
    /// additively with `SetClosingFacts` (`leaseID`, `endedBecause`, `fans`, ...). A caller that
    /// reads only the original four keys reads it unchanged.
    struct FailureEventJSON: Encodable {
        let failure: FailureJSON
        let at: Date
        let closing: SetClosingFacts

        init(failure: FailureJSON, at: Date, closing: SetClosingFacts = .none) {
            self.failure = failure
            self.at = at
            self.closing = closing
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: SetEventKey.self)
            try container.encode(HelperCommandOutput.schemaVersion, forKey: .schema)
            try container.encode("failed", forKey: .event)
            try container.encode(at, forKey: .at)
            try closing.encode(into: &container)
            try container.encode(failure, forKey: .failure)
        }
    }
}
