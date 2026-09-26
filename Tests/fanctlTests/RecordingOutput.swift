import Foundation
import os

@testable import fanctl

/// Every line a command wrote, in order, with the stream it went to.
///
/// `AeolusHelperTests` has its own copy, `RecordingTerminal`: test targets cannot share
/// sources, and the end-to-end suites live there for the reason `FanctlResetTests` gives.
final class RecordingOutput: Sendable {

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
}
