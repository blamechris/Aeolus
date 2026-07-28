import Darwin
import Dispatch
import Foundation
import SMCCore

/// `fanctl watch` — a live-updating view of fan speeds, meant to be left running in a
/// terminal.
///
/// Deliberately built on `ListCommand.fetch`/`renderTable`/`jsonOutput` rather than a
/// parallel implementation: the fan set is already fully known from a single `FNum` read
/// (see `ListCommand`'s own documentation on why Apple Silicon has no `{fds` descriptor to
/// discover), so every refresh is exactly the same targeted `SensorProvider.read(keys:)`
/// subset `list` already performs — never `readAll()`. This is the "opposite case"
/// `SensorsCommand.fetch`'s documentation points at: `sensors` exists to discover keys
/// nobody has told this project about yet and must enumerate everything; `watch` already
/// knows exactly which keys it wants on every tick and must not pay full enumeration's
/// cost (~0.6 s warm, ~4.5 s cold, measured on `Mac16,5`) for one.
///
/// Reusing `ListCommand`'s types is also what makes "`watch` can never show a different
/// number than `list` for the same key" true by construction rather than by discipline:
/// both read through the same `fetch`, render through the same `renderTable`, and encode
/// through the same `jsonOutput` — there is only one code path that turns a `Result` into
/// text, and `watch` just calls it repeatedly.
enum WatchCommand {

    /// Every per-tick setting the refresh loop needs, grouped so `run(provider:options:
    /// clock:output:)` takes one options value instead of four separate flags — the same
    /// shape `DumpFormatter`'s render functions group their own context into rather than
    /// growing a long positional parameter list.
    struct Options: Sendable {
        /// Seconds to wait between ticks. Only consulted by a real `WatchClock` — see
        /// `SystemWatchClock.sleep(seconds:)` — a fake clock in tests may ignore it
        /// entirely.
        let interval: Double
        /// Stop after this many ticks, or run until cancelled if `nil`.
        let count: Int?
        /// Emit NDJSON instead of the redrawing/plain-block table.
        let json: Bool
        /// Whether stdout is a real terminal — see `render(_:options:)`'s documentation
        /// for what this changes.
        let isTerminal: Bool
    }

    /// Runs the refresh loop until `options.count` ticks have completed (if given) or the
    /// enclosing `Task` is cancelled.
    ///
    /// A single fetch failure — no SMC, an implausible `FNum`, a dead connection — ends
    /// the command with that error, exactly as a single `fanctl list` invocation would;
    /// this never silently retries forever and hides a real problem behind a still-
    /// refreshing display. Only cancellation between ticks (SIGINT, wired up in
    /// `Fanctl.Watch.run()` below) is a *clean* stop, not an error.
    ///
    /// Cancellation is cooperative: if the surrounding `Task` is cancelled while a fetch
    /// is already in flight, that fetch still completes and its tick still renders — a
    /// `SensorProvider` read is not itself a cancellation point — and only the *next*
    /// wait, in `clock.sleep(seconds:)`, observes it and stops. That is an acceptable
    /// "maybe one extra frame," never a hang, a partial write, or a stack trace.
    static func run(
        provider: some SensorProvider,
        options: Options,
        clock: some WatchClock = SystemWatchClock(),
        output: (String) -> Void
    ) async throws {
        var tick = 0
        while true {
            let result = try await ListCommand.fetch(provider: provider, now: clock.now())
            output(try render(result, options: options))
            tick += 1

            if let count = options.count, tick >= count {
                return
            }
            do {
                try await clock.sleep(seconds: options.interval)
            } catch is CancellationError {
                return
            }
        }
    }

    /// One tick's rendering.
    ///
    /// `--json` always emits a single compact NDJSON line, on a terminal or not — see
    /// `FanctlJSON.encodeLine`'s documentation for why a streaming format never carries
    /// pretty-printing, and there is even less reason for it to carry ANSI. The table view
    /// clears and redraws only when stdout is a real terminal (`\u{1B}[2J\u{1B}[H`, the
    /// same clear-and-home pair the Unix `watch` utility uses for its own redraw); a pipe
    /// or redirect instead gets a plain, timestamped, append-only block per tick, so a
    /// script capturing this command's output sees a readable, greppable log rather than a
    /// scroll of cursor-control bytes it cannot parse as text.
    private static func render(_ result: ListCommand.Result, options: Options) throws -> String {
        if options.json {
            return try FanctlJSON.encodeLine(ListCommand.jsonOutput(result))
        }

        let timestamp = Self.formattedTimestamp(result.capturedAt)
        let table = ListCommand.renderTable(result)
        guard options.isTerminal else {
            return "-- \(timestamp) --\n\(table)\n"
        }
        return "\(Self.clearScreen)fanctl watch — \(timestamp) (Ctrl-C to exit)\n\n\(table)\n"
    }

    /// Clear-screen-and-home. Never emitted unless `isTerminal` is true: a pipe or file
    /// redirect must never receive raw escape bytes mixed into otherwise-readable text.
    private static let clearScreen = "\u{1B}[2J\u{1B}[H"

    /// Matches `FanctlJSON`'s own `.iso8601` date strategy, so a timestamp printed in the
    /// table header reads identically to the `capturedAt` field `--json` would have shown
    /// for the same tick. A fresh `ISO8601DateFormatter` per call rather than one cached in
    /// a `static let`: the type is not `Sendable`, and one instance per tick (at most a few
    /// times a second) costs nothing worth caching for.
    private static func formattedTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// Abstracts "how time passes" for `WatchCommand.run`'s refresh loop, so it is
/// deterministically testable: a real run waits on the wall clock, a test can make every
/// tick resolve instantly and simulate a mid-loop cancellation without the suite actually
/// taking `interval * count` seconds or touching a real signal.
protocol WatchClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

/// The real clock: wall-clock time, and a genuinely cancellable wait —
/// `Task.sleep(nanoseconds:)` throws `CancellationError` the instant the surrounding `Task`
/// is cancelled, rather than waiting out the full interval, which is what makes SIGINT feel
/// immediate even when it lands mid-sleep.
struct SystemWatchClock: WatchClock {
    func now() -> Date { Date() }

    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: Self.clampedNanoseconds(forSeconds: seconds))
    }

    /// The nanosecond duration `sleep(seconds:)` waits for, clamped rather than trapping.
    ///
    /// `Fanctl.Watch.validate()` already rejects a non-finite or non-positive `--interval`,
    /// but not one merely too large to convert: `UInt64(_:)` on an out-of-range `Double`
    /// (anything at or above ~1.8446744e10 seconds, `UInt64.max` nanoseconds) is a runtime
    /// precondition failure, not a thrown error — a stack trace from a mistyped argument.
    /// `UInt64(exactly:)` never traps: it returns `nil` for exactly that case, handled here
    /// by clamping to `UInt64.max` (effectively "forever, until cancelled") rather than
    /// crashing, as a second line of defence independent of `validate()`'s own bound.
    ///
    /// A free function rather than inlined into `sleep(seconds:)`: this is pure arithmetic,
    /// directly unit-testable without ever calling `Task.sleep` (and therefore without any
    /// test needing to wait out or race a real cancellation) — see
    /// `SystemWatchClockNanosecondClampingTests`. Internal rather than `private` so those
    /// tests can call it via `@testable import`.
    static func clampedNanoseconds(forSeconds seconds: Double) -> UInt64 {
        let nanoseconds = max(0, seconds * 1_000_000_000).rounded()
        return UInt64(exactly: nanoseconds) ?? UInt64.max
    }
}

// MARK: - Command wiring

extension Fanctl.Watch {
    /// The real CLI entry: wraps the refresh loop in a cancellable `Task` and installs the
    /// `SIGINT` handler that cancels it — see `installSIGINTHandler`'s documentation for
    /// why that has to be a `DispatchSourceSignal` rather than a raw `signal()` handler.
    /// Only `self.interval`/`count`/`json` cross into the `Task`, not `self` itself, so
    /// this carries no assumption about whether `Fanctl.Watch` (an `ArgumentParser`
    /// command struct built from property wrappers) is `Sendable`.
    func run() async throws {
        // `stdout` is fully-buffered, not line-buffered, whenever it is not a terminal —
        // the standard C stdio convention Darwin follows: a pipe or file redirect batches
        // writes into ~16 KB chunks before flushing, only handed to the reader at process
        // exit or once the buffer fills. That silently defeats NDJSON's entire reason for
        // existing: a script's `while read -r line` would see nothing for dozens of ticks,
        // then a burst, at odds with `FanctlJSON.encodeLine`'s and this file's own
        // documentation of "one line arrives per tick." Forcing line-buffered mode here
        // means each tick's `print($0)` flushes on its own trailing newline instead,
        // whether stdout is a terminal, a pipe, or a redirected file.
        setvbuf(stdout, nil, _IOLBF, 0)

        let provider = SMCSensorProvider()
        let options = WatchCommand.Options(
            interval: interval, count: count, json: json, isTerminal: Self.stdoutIsTerminal())

        let task = Task {
            try await WatchCommand.run(provider: provider, options: options, output: { print($0) })
        }
        let sigintSource = Self.installSIGINTHandler(cancelling: task)
        defer { sigintSource.cancel() }
        try await task.value
    }

    /// Provider-, clock-, and output-injectable so `fanctlTests` can exercise the refresh
    /// loop without hardware, without a real clock, and without touching the real process
    /// stdout — see `Tests/fanctlTests/WatchCommandTests.swift`. No `Task` is created here:
    /// this is what every test calls directly, the same shape as `ListCommand`'s and
    /// `SensorsCommand`'s equivalent overloads, and `output` stays a plain, non-`@Sendable`
    /// closure for exactly that reason. SIGINT cancellation is wired only at `run()`
    /// above's call site, the one path a real signal can ever reach.
    func run(
        provider: some SensorProvider,
        isTerminal: Bool = Self.stdoutIsTerminal(),
        clock: some WatchClock = SystemWatchClock(),
        output: (String) -> Void = { print($0) }
    ) async throws {
        let options = WatchCommand.Options(
            interval: interval, count: count, json: json, isTerminal: isTerminal)
        try await WatchCommand.run(
            provider: provider, options: options, clock: clock, output: output)
    }

    /// Whether stdout is a real terminal, via the same `isatty` check `/bin/ps` or any
    /// other Unix tool uses to decide whether to colourise or paginate. `false` for a pipe,
    /// a file redirect, or a captured subprocess — exactly the cases where raw ANSI escapes
    /// would corrupt the output rather than animate it.
    static func stdoutIsTerminal() -> Bool {
        isatty(fileno(stdout)) != 0
    }

    /// Installs a `SIGINT` handler that cancels `task` instead of letting the default
    /// disposition tear the process down.
    ///
    /// Not a raw `signal(SIGINT, someHandler)`: a C signal handler runs in async-signal
    /// context, where calling back into the Swift concurrency runtime (task cancellation)
    /// is not something POSIX guarantees is safe. `DispatchSourceSignal`'s event handler
    /// instead runs as ordinary code on `queue`, dispatched there once the signal has
    /// already been observed — `signal(SIGINT, SIG_IGN)` only suppresses the default
    /// disposition (process termination) so this source is what actually reacts to it.
    ///
    /// The handler restores the default disposition (`SIG_DFL`) the instant it fires, not
    /// only cancelling `task`: cancellation is cooperative (see `WatchCommand.run`'s own
    /// documentation), and a tick blocked inside a synchronous SMC call with no timeout
    /// never reaches a suspension point that would observe it. Without restoring `SIG_DFL`
    /// here, a second Ctrl-C in that situation would be silently ignored forever — worse
    /// than the plain `signal()` this replaces, which at least let the *first* one kill the
    /// process. Restoring it means the first Ctrl-C asks nicely and the second always
    /// works, the same two-stage convention most long-running Unix tools follow.
    private static func installSIGINTHandler(
        cancelling task: Task<Void, Error>
    ) -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            task.cancel()
            signal(SIGINT, SIG_DFL)
        }
        source.resume()
        return source
    }
}
