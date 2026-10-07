import Foundation
import os

@testable import fanctl

/// Every line a command wrote, in order, with the stream it went to.
final class RecordingTerminal: Sendable {

    struct Line: Sendable, Hashable {
        let stream: Terminal.Stream
        let text: String
    }

    private let recorded = OSAllocatedUnfairLock<[Line]>(initialState: [])

    var terminal: Terminal {
        Terminal { [recorded] stream, text in
            recorded.withLock { $0.append(Line(stream: stream, text: text)) }
        }
    }

    var lines: [Line] { recorded.withLock { $0 } }

    var standardOutput: String {
        lines.filter { $0.stream == .standardOutput }.map(\.text).joined(separator: "\n")
    }

    var standardError: String {
        lines.filter { $0.stream == .standardError }.map(\.text).joined(separator: "\n")
    }

    /// Standard output as NDJSON: one decoded object per line.
    func events() throws -> [[String: Any]] {
        try lines.filter { $0.stream == .standardOutput }.map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.text.utf8))
            guard let dictionary = object as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            return dictionary
        }
    }
}

/// How one `run()` left: `nil` for a normal return, otherwise the exit code it would exit
/// with — read through swift-argument-parser's own mapping, not a copy of it.
func exitCode(of run: () async throws -> Void) async -> Int32? {
    do {
        try await run()
        return nil
    } catch {
        return Fanctl.exitCode(for: error).rawValue
    }
}
