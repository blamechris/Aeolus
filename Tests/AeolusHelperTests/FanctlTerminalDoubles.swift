import Foundation
import os

@testable import fanctl

/// Every line a command wrote, in order, with the stream it went to.
///
/// It can also be a terminal whose standard output **stops taking lines**: the consumer that went
/// away. Such a line is still recorded, flagged as not delivered, so a test can assert both what
/// a consumer would have read (`standardOutput`) and what the command tried to say
/// (`attemptedStandardOutput`).
final class RecordingTerminal: Sendable {

    struct Line: Sendable, Hashable {
        let stream: Terminal.Stream
        let text: String
        let delivered: Bool

        init(stream: Terminal.Stream, text: String, delivered: Bool = true) {
            self.stream = stream
            self.text = text
            self.delivered = delivered
        }
    }

    private let recorded = OSAllocatedUnfairLock<[Line]>(initialState: [])
    private let acceptedStandardOutputLines: Int?
    private let onStandardOutput: (@Sendable (Int, String) -> Void)?

    /// - Parameters:
    ///   - acceptingStandardOutputLines: Standard output takes this many lines and then fails
    ///     every write. `nil` takes all of them.
    ///   - onStandardOutput: Called after each standard-output line is recorded, with its
    ///     one-based number. It is how a test makes time pass during a write.
    init(
        acceptingStandardOutputLines: Int? = nil,
        onStandardOutput: (@Sendable (Int, String) -> Void)? = nil
    ) {
        self.acceptedStandardOutputLines = acceptingStandardOutputLines
        self.onStandardOutput = onStandardOutput
    }

    var terminal: Terminal {
        let recorded = recorded
        let limit = acceptedStandardOutputLines
        let onStandardOutput = onStandardOutput
        return Terminal(delivering: { stream, text in
            let (delivered, number) = recorded.withLock { lines -> (Bool, Int) in
                let attempted = lines.filter { $0.stream == .standardOutput }.count
                var delivered = true
                if stream == .standardOutput, let limit {
                    delivered = attempted < limit
                }
                lines.append(Line(stream: stream, text: text, delivered: delivered))
                return (delivered, attempted + 1)
            }
            if stream == .standardOutput { onStandardOutput?(number, text) }
            return delivered
        })
    }

    var lines: [Line] { recorded.withLock { $0 } }

    /// What a consumer of standard output would have read.
    var standardOutput: String {
        lines.filter { $0.stream == .standardOutput && $0.delivered }.map(\.text)
            .joined(separator: "\n")
    }

    /// Everything the command tried to write to standard output, delivered or not.
    var attemptedStandardOutput: [String] {
        lines.filter { $0.stream == .standardOutput }.map(\.text)
    }

    var standardError: String {
        lines.filter { $0.stream == .standardError }.map(\.text).joined(separator: "\n")
    }

    /// Standard output as NDJSON: one decoded object per delivered line.
    func events() throws -> [[String: Any]] {
        try Self.decode(lines.filter { $0.stream == .standardOutput && $0.delivered })
    }

    /// The same, for every line the command tried to write.
    func attemptedEvents() throws -> [[String: Any]] {
        try Self.decode(lines.filter { $0.stream == .standardOutput })
    }

    private static func decode(_ lines: [Line]) throws -> [[String: Any]] {
        try lines.map { line in
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
